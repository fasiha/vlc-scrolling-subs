import AppKit
import SubtitleKit
import SwiftUI

/// The subtitle column: one TextKit 1 NSTextView holding the whole transcript (one paragraph per
/// cue). Highlighting uses layout-manager temporary attributes only, so it never triggers layout.
/// Owns the follow/free scroll state machine (see PLAN.md).
@MainActor
final class TranscriptController: NSObject, ObservableObject {

    enum Mode { case follow, free }
    @Published private(set) var mode: Mode = .follow

    var onSeek: ((Double) -> Void)?

    let scrollView = TranscriptScrollView()
    private let textView: TranscriptTextView
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    private var cues: [SubtitleCue] = []
    /// Character range of each cue's paragraph (without the trailing newline).
    private var lineRanges: [NSRange] = []
    /// Character ranges of each cue's words (empty when the cue has no word timings).
    private var wordRanges: [[NSRange]] = []
    private var fontSize: Double = 18

    private var time: Double = 0
    /// Last cue that has started; nil before the first cue; `cues.count` once the last cue has
    /// ended (transcripts may cover only part of the video).
    private var line: Int?
    private var word: Int?   // last started word within `line`

    private static let lineGap: CGFloat = 10
    private static let sidePad: CGFloat = 6
    private static let rowPad: CGFloat = 4

    override init() {
        storage.addLayoutManager(layoutManager)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = false
        textView = TranscriptTextView(frame: .zero, textContainer: container)
        super.init()

        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .windowBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.onClick = { [weak self] p in self?.click(at: p) }
        textView.onHover = { [weak self] p in self?.hover(at: p) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.onUserScroll = { [weak self] in self?.userScrolled() }
        scrollView.onResize = { [weak self] in self?.resized() }
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                               object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        }
    }

    // MARK: Inputs

    func load(_ cues: [SubtitleCue], time: Double) {
        self.cues = cues
        self.time = time
        line = nil  // reset before relayout: the old position may not exist in the new cues
        word = nil
        rebuildText()
        computePosition()
        restyleAll()
        follow(animated: false)
    }

    func setFontSize(_ size: Double) {
        guard size != fontSize else { return }
        fontSize = size
        rebuildText()
        restyleAll()
        if mode == .follow { scrollToCurrent(animated: false) }
    }

    /// Pushed by PlayerModel at 30 Hz while playing and on every seek.
    func update(time t: Double) {
        time = t
        let (oldLine, oldWord) = (line, word)
        computePosition()
        guard line != oldLine || word != oldWord else { return }
        if line != oldLine {
            restyleLines(between: oldLine, and: line)
            updateHighlightRect()
            lineChanged(from: oldLine)
        } else if let l = line, l < cues.count {
            styleCurrent(l)
        }
    }

    func follow(animated: Bool) {
        mode = .follow
        scrollToCurrent(animated: animated)
    }

    // MARK: Position

    private func computePosition() {
        line = cues.lastStarted(at: time)
        if let l = line, l == cues.count - 1, time > cues[l].end { line = cues.count }
        word = line.flatMap { l in
            guard l < cues.count else { return nil }
            let words = cues[l].words
            var lo = 0, hi = words.count
            while lo < hi { let m = (lo + hi) / 2; if words[m].start <= time { lo = m + 1 } else { hi = m } }
            return lo == 0 ? nil : lo - 1
        }
    }

    // MARK: Text

    private var font: NSFont { .systemFont(ofSize: fontSize) }

    private func rebuildText() {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = Self.lineGap + 2 * Self.rowPad
        para.firstLineHeadIndent = Self.sidePad
        para.headIndent = Self.sidePad
        para.tailIndent = -Self.sidePad
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                    .foregroundColor: NSColor.labelColor]
        var text = ""
        var lines: [NSRange] = []
        var words: [[NSRange]] = []
        lines.reserveCapacity(cues.count)
        words.reserveCapacity(cues.count)
        var pos = 0  // UTF-16 offset
        for (i, cue) in cues.enumerated() {
            if i > 0 { text += "\n"; pos += 1 }
            let start = pos
            var wr: [NSRange] = []
            if cue.words.isEmpty {
                let s = cue.text.replacingOccurrences(of: "\n", with: " ")
                text += s
                pos += s.utf16.count
            } else {
                for (j, w) in cue.words.enumerated() {
                    if j > 0 { text += " "; pos += 1 }
                    let n = w.text.utf16.count
                    wr.append(NSRange(location: pos, length: n))
                    text += w.text
                    pos += n
                }
            }
            lines.append(NSRange(location: start, length: pos - start))
            words.append(wr)
        }
        lineRanges = lines
        wordRanges = words
        storage.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        layoutManager.ensureLayout(for: container)
        resized()
    }

    // MARK: Styling (temporary attributes only; never affects layout)

    /// Future lines share the faint "unspoken" shade with not-yet-spoken words of the current line.
    private enum Style { case past, current, unspoken }

    private func color(_ s: Style) -> NSColor {
        switch s {
        case .past: return NSColor.labelColor.withAlphaComponent(0.5)
        case .current: return .labelColor
        case .unspoken: return NSColor.labelColor.withAlphaComponent(0.06)
        }
    }

    private func paint(_ r: NSRange, _ s: Style) {
        guard r.length > 0 else { return }
        layoutManager.setTemporaryAttributes([.foregroundColor: color(s)], forCharacterRange: r)
    }

    /// Characters spanning lines a...b (inclusive), including the newlines between them.
    private func span(_ a: Int, _ b: Int) -> NSRange {
        guard a <= b else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lineRanges[a].location, length: NSMaxRange(lineRanges[b]) - lineRanges[a].location)
    }

    private func restyleAll() {
        guard !cues.isEmpty else { return }
        let cur = line ?? -1
        if cur >= 1 { paint(span(0, cur - 1), .past) }
        if cur + 1 < cues.count { paint(span(cur + 1, cues.count - 1), .unspoken) }
        if line != nil, cur < cues.count { styleCurrent(cur) }
        updateHighlightRect()
    }

    /// Repaint every line whose state may differ between `old` and `new` current lines.
    private func restyleLines(between old: Int?, and new: Int?) {
        let o = old ?? -1, n = new ?? -1
        let lo = max(0, min(o, n)), hi = min(cues.count - 1, max(o, n))
        guard lo <= hi else { return }
        if lo < n { paint(span(lo, n - 1), .past) }
        if n < hi { paint(span(max(lo, n + 1), hi), .unspoken) }
        if new != nil, n < cues.count { styleCurrent(n) }
    }

    private func styleCurrent(_ l: Int) {
        let r = lineRanges[l]
        let words = wordRanges[l]
        guard !words.isEmpty else { paint(r, .current); return }
        let spokenEnd = word.map { NSMaxRange(words[$0]) } ?? r.location
        paint(NSRange(location: r.location, length: spokenEnd - r.location), .current)
        paint(NSRange(location: spokenEnd, length: NSMaxRange(r) - spokenEnd), .unspoken)
    }

    // MARK: Geometry

    /// Rect of a cue's paragraph in text-view coordinates, padded like a row.
    private func rect(ofLine l: Int) -> NSRect {
        var g = layoutManager.glyphRange(forCharacterRange: lineRanges[l], actualCharacterRange: nil)
        if g.length == 0 { g.length = 1 }  // empty cue: use the newline's fragment
        g.location = min(g.location, max(0, layoutManager.numberOfGlyphs - 1))
        var r = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: g) { _, used, _, _, _ in r = r.union(used) }
        let o = textView.textContainerOrigin
        let width = container.size.width
        return NSRect(x: o.x, y: o.y + r.minY - Self.rowPad, width: width, height: r.height + 2 * Self.rowPad)
    }

    private func updateHighlightRect() {
        textView.highlightRect = line.flatMap { $0 < cues.count ? rect(ofLine: $0) : nil }
    }

    private func resized() {
        let clip = scrollView.contentView.bounds
        let h = clip.height
        if textView.frame.width != clip.width {
            textView.setFrameSize(NSSize(width: clip.width, height: textView.frame.height))
        }
        // Pad so the first line can sit at the bottom; future lines sit below the anchor.
        textView.textContainerInset = NSSize(width: 12, height: max(h, 0))
        textView.sizeToFit()
        updateHighlightRect()
        if mode == .follow { scrollToCurrent(animated: false) }
    }

    // MARK: Scrolling state machine

    private var visibleRect: NSRect { scrollView.contentView.bounds }

    private func lineChanged(from old: Int?) {
        guard let l = anchorLine else { return }
        switch mode {
        case .follow:
            scrollToCurrent(animated: true)
        case .free:
            // Resume following when the playing line runs off the visible area.
            let vis = visibleRect
            let wasVisible = old.map { vis.intersects(rect(ofLine: min($0, cues.count - 1))) } ?? false
            if wasVisible && !vis.contains(rect(ofLine: l)) { follow(animated: true) }
        }
    }

    /// Line kept at the bottom while following: the current line, the first line before the
    /// transcript starts (it shows faintly at the bottom), the last line after it ends.
    private var anchorLine: Int? {
        guard !cues.isEmpty else { return nil }
        return min(line ?? 0, cues.count - 1)
    }

    private func scrollToCurrent(animated: Bool) {
        guard let l = anchorLine else { return }
        let r = rect(ofLine: l)
        let clip = scrollView.contentView
        let h = clip.bounds.height
        var y = r.maxY - h + Self.lineGap  // current line anchored at the bottom
        y = min(max(0, y), max(0, textView.frame.height - h))
        let target = NSPoint(x: 0, y: y)
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        if animated && abs(clip.bounds.origin.y - y) < h * 2 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            stopAnimation()
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private func stopAnimation() {
        let clip = scrollView.contentView
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            clip.animator().setBoundsOrigin(clip.bounds.origin)
        }
    }

    private func userScrolled() {
        hover(at: nil)
        if mode != .free { stopAnimation(); mode = .free }
    }

    // MARK: Hit testing (click to seek, hover timestamp)

    /// Line and word under a point in text-view coordinates, plus that word's (or line's) start.
    private func hit(at p: NSPoint) -> (line: Int, time: Double)? {
        guard !cues.isEmpty else { return nil }
        let o = textView.textContainerOrigin
        let q = NSPoint(x: p.x - o.x, y: p.y - o.y)
        var frac: CGFloat = 0
        let gi = layoutManager.glyphIndex(for: q, in: container, fractionOfDistanceThroughGlyph: &frac)
        guard gi < layoutManager.numberOfGlyphs,
              layoutManager.lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: nil).insetBy(dx: 0, dy: -Self.rowPad).contains(q)
        else { return nil }
        let ci = layoutManager.characterIndexForGlyph(at: gi)
        // Cue containing ci: last line starting at or before it.
        var lo = 0, hi = lineRanges.count
        while lo < hi { let m = (lo + hi) / 2; if lineRanges[m].location <= ci { lo = m + 1 } else { hi = m } }
        let l = lo - 1
        guard l >= 0 else { return nil }
        // Nearest word starting at or before ci (a space picks the preceding word).
        let w = wordRanges[l].lastIndex { $0.location <= ci }
        return (l, w.map { cues[l].words[$0].start } ?? cues[l].start)
    }

    private func click(at p: NSPoint) {
        guard let h = hit(at: p) else { return }
        mode = .free  // before seeking, so the view does not move
        onSeek?(h.time + 0.001)
    }

    private func hover(at p: NSPoint?) {
        textView.hoverLabel = p.flatMap { hit(at: $0) }.map { (rect(ofLine: $0.line), Self.format($0.time)) }
    }

    static func format(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class TranscriptTextView: NSTextView {
    var onClick: ((NSPoint) -> Void)?
    var onHover: ((NSPoint?) -> Void)?
    var highlightRect: NSRect? {
        didSet {
            guard oldValue != highlightRect else { return }
            if let r = oldValue { setNeedsDisplay(r) }
            if let r = highlightRect { setNeedsDisplay(r) }
        }
    }
    /// Timestamp drawn in the empty gap just above the hovered row (no layout change).
    var hoverLabel: (row: NSRect, text: String)? {
        didSet {
            guard oldValue?.row != hoverLabel?.row || oldValue?.text != hoverLabel?.text else { return }
            if let r = oldValue?.row { setNeedsDisplay(Self.labelRect(r)) }
            if let r = hoverLabel?.row { setNeedsDisplay(Self.labelRect(r)) }
        }
    }
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    private static func labelRect(_ row: NSRect) -> NSRect {
        NSRect(x: row.minX, y: row.minY - 11, width: row.width, height: 13)
    }

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self && a.userInfo?["hover"] != nil { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let r = highlightRect, r.intersects(rect) {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        if let h = hoverLabel {
            let s = NSAttributedString(string: h.text, attributes: Self.labelAttrs)
            let lr = Self.labelRect(h.row)
            s.draw(at: NSPoint(x: lr.maxX - s.size().width - 4, y: lr.minY))
        }
    }
}

final class TranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var onResize: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
    override func tile() {
        let old = contentView.bounds.size
        super.tile()
        if contentView.bounds.size != old { onResize?() }
    }
}

struct TranscriptView: NSViewRepresentable {
    let controller: TranscriptController
    func makeNSView(context: Context) -> TranscriptScrollView { controller.scrollView }
    func updateNSView(_ nsView: TranscriptScrollView, context: Context) {}
}
