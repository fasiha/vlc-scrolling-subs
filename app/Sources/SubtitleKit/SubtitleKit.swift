import Foundation

/// A single timed word inside a cue (seconds).
public struct SubtitleWord: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// One subtitle line. `words` is empty when no word timing is known.
public struct SubtitleCue: Equatable, Codable, Sendable, Identifiable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [SubtitleWord]
    public init(id: Int, start: Double, end: Double, text: String, words: [SubtitleWord] = []) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.words = words
    }
}

public enum SubtitleError: Error, Equatable {
    case unrecognizedFormat
    case invalidJSON(String)
}

public enum SubtitleFormat: Sendable { case srt, webvtt, wordJSON }

public enum SubtitleParser {
    /// Parse by file extension, falling back to content sniffing.
    public static func parse(url: URL) throws -> [SubtitleCue] {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let fmt: SubtitleFormat? = ext == "srt" ? .srt : ext == "vtt" ? .webvtt : ext == "json" ? .wordJSON : nil
        return try parse(data: data, format: fmt)
    }

    public static func parse(data: Data, format: SubtitleFormat? = nil) throws -> [SubtitleCue] {
        guard var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SubtitleError.unrecognizedFormat
        }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let fmt = format ?? sniff(s)
        switch fmt {
        case .srt: return SRTParser.parse(s)
        case .webvtt: return WebVTTParser.parse(s)
        case .wordJSON: return try WordJSONParser.parse(data)
        case nil: throw SubtitleError.unrecognizedFormat
        }
    }

    static func sniff(_ s: String) -> SubtitleFormat? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("WEBVTT") { return .webvtt }
        if t.hasPrefix("{") { return .wordJSON }
        if t.contains("-->") { return .srt }
        return nil
    }
}

// MARK: - Shared helpers

enum Timecode {
    /// Parses `hh:mm:ss.mmm`, `mm:ss.mmm`, or SRT `hh:mm:ss,mmm`.
    static func parse<S: StringProtocol>(_ raw: S) -> Double? {
        let str = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = str.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

enum Markup {
    /// Remove `<...>` tags and decode a handful of HTML entities.
    static func strip(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

struct RawCue {
    var start: Double
    var end: Double
    var lines: [String]
}

/// Splits text into blocks separated by blank lines and extracts the timing line.
func rawCues(_ text: String) -> [RawCue] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var cues: [RawCue] = []
    var block: [String] = []
    func flush() {
        defer { block.removeAll() }
        guard let i = block.firstIndex(where: { $0.contains("-->") }) else { return }
        let timing = block[i].components(separatedBy: "-->")
        guard timing.count == 2,
              let start = Timecode.parse(timing[0]),
              let endTok = timing[1].split(separator: " ", omittingEmptySubsequences: true).first,
              let end = Timecode.parse(endTok) else { return }
        cues.append(RawCue(start: start, end: end, lines: Array(block[(i + 1)...])))
    }
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.isEmpty { flush() } else { block.append(String(line)) }
    }
    flush()
    return cues
}

func renumber(_ cues: [SubtitleCue]) -> [SubtitleCue] {
    cues.sorted { $0.start < $1.start }.enumerated().map { i, c in
        var c = c; c.id = i; return c
    }
}

// MARK: - SRT

public enum SRTParser {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let cues = rawCues(text).compactMap { raw -> SubtitleCue? in
            let t = Markup.strip(raw.lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : SubtitleCue(id: 0, start: raw.start, end: raw.end, text: t)
        }
        return renumber(cues)
    }
}

// MARK: - WebVTT

public enum WebVTTParser {
    public static func parse(_ text: String) -> [SubtitleCue] {
        let raws = rawCues(text)
        let isYouTubeAuto = raws.contains { cue in cue.lines.contains { $0.contains("<c>") || $0.range(of: #"<\d+:\d+"#, options: .regularExpression) != nil } }
        return isYouTubeAuto ? parseYouTube(raws) : parsePlain(raws)
    }

    static func parsePlain(_ raws: [RawCue]) -> [SubtitleCue] {
        renumber(raws.compactMap { raw in
            // Drop NOTE/STYLE/REGION blocks implicitly: they have no timing line.
            let t = Markup.strip(raw.lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : SubtitleCue(id: 0, start: raw.start, end: raw.end, text: t)
        })
    }

    /// YouTube auto-captions: each cue shows the previous line (plain) plus the new line with
    /// inline `<hh:mm:ss.mmm><c> word</c>` timestamps; 10 ms "snapshot" cues repeat text.
    /// We keep only the newly introduced line of each cue, with per-word timing.
    static func parseYouTube(_ raws: [RawCue]) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var lastText = ""
        for raw in raws {
            guard let newLine = raw.lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            let hasTiming = newLine.contains("<")
            let plain = Markup.collapse(Markup.strip(newLine))
            if plain.isEmpty { continue }
            if !hasTiming {
                // Either a snapshot repeat of an existing line, or an untimed line like "[music]".
                if plain == lastText {
                    if var prev = out.popLast() { prev.end = max(prev.end, raw.end); out.append(prev) }
                    continue
                }
                if raw.end - raw.start < 0.05 { continue }
            }
            let words = hasTiming ? timedWords(newLine, cueStart: raw.start, cueEnd: raw.end) : []
            out.append(SubtitleCue(id: 0, start: raw.start, end: raw.end, text: plain, words: words))
            lastText = plain
        }
        // Trim overlaps: a line ends no later than the next one starts... except YouTube shows two
        // lines at once; we keep the cue's own end, which already reflects that.
        return renumber(out)
    }

    static func timedWords(_ line: String, cueStart: Double, cueEnd: Double) -> [SubtitleWord] {
        // Tokenize into (timestamp?, text) segments.
        var segments: [(Double, String)] = []
        var currentStart = cueStart
        var buf = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "<", let close = line[i...].firstIndex(of: ">") {
                let tag = line[line.index(after: i)..<close]
                if let ts = Timecode.parse(tag) {
                    segments.append((currentStart, buf)); buf = ""
                    currentStart = ts
                }
                i = line.index(after: close)
            } else {
                buf.append(line[i]); i = line.index(after: i)
            }
        }
        segments.append((currentStart, buf))
        var words: [SubtitleWord] = []
        for (start, text) in segments {
            for (k, w) in Markup.strip(text).split(whereSeparator: { $0.isWhitespace }).enumerated() {
                // Rarely multiple words share one timestamp; nudge to keep order.
                words.append(SubtitleWord(start: start + Double(k) * 0.001, end: start, text: String(w)))
            }
        }
        for k in words.indices {
            words[k].end = k + 1 < words.count ? words[k + 1].start : max(cueEnd, words[k].start)
        }
        return words
    }
}

// MARK: - Word-timed JSON (from ../karaoke)

public enum WordJSONParser {
    struct File: Decodable {
        var version: Int?
        var lines: [Line]
    }
    struct Line: Decodable {
        var start: Double
        var end: Double
        var text: String
        var words: [SubtitleWord]?
    }

    public static func parse(_ data: Data) throws -> [SubtitleCue] {
        do {
            let f = try JSONDecoder().decode(File.self, from: data)
            return renumber(f.lines.map { SubtitleCue(id: 0, start: $0.start, end: $0.end, text: $0.text, words: $0.words ?? []) })
        } catch {
            throw SubtitleError.invalidJSON(String(describing: error))
        }
    }
}

// MARK: - Lookup

public extension Array where Element == SubtitleCue {
    /// Index of the last cue whose start is <= t (binary search), or nil if before the first cue.
    func lastStarted(at t: Double) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
