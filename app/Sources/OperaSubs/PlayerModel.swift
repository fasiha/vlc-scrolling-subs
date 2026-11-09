import AppKit
import Combine
import SubtitleKit
import VLCKit

/// Coarse playback time for the transport bar (label + slider). Published at 2 Hz, not 30 Hz.
@MainActor
final class TransportClock: ObservableObject {
    @Published private(set) var time: Double = 0
    func update(_ t: Double, force: Bool = false) {
        if force || Int(t * 2) != Int(time * 2) { time = t }
    }
}

/// Owns VLC and the playback-time model. SwiftUI observes only rarely-changing state here;
/// the 30 Hz time is pushed directly to `transcript` (AppKit) and `clock` (2 Hz).
@MainActor
final class PlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let transcript = TranscriptController()
    let clock = TransportClock()

    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var videoURL: URL?
    @Published private(set) var subtitleURL: URL?
    @Published var errorMessage: String?

    @Published var fontSize: Double = 18 { didSet { transcript.setFontSize(fontSize) } }
    @Published var showColumn = true

    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    @Published private(set) var rate: Double = 1

    func setRate(_ r: Double) {
        // Re-anchor so the extrapolated clock doesn't jump when the multiplier changes.
        anchorTime = currentTime
        anchorDate = Date()
        rate = r
        player.rate = Float(r)
    }

    static func rateLabel(_ r: Double) -> String {
        (r == r.rounded() ? String(Int(r)) : String(r)) + "×"
    }

    func stepRate(_ dir: Int) {
        let i = Self.rates.firstIndex(of: rate) ?? Self.rates.firstIndex(of: 1)!
        setRate(Self.rates[max(0, min(Self.rates.count - 1, i + dir))])
    }

    /// Single source of truth for playback time (see PLAN.md "Playback time").
    private(set) var currentTime: Double = 0
    /// Interpolation anchor: VLC's time updates are coarse (~4 Hz), so we extrapolate between them.
    private var anchorTime: Double = 0
    private var anchorDate = Date()
    /// Seek target not yet confirmed by a VLC time report.
    private var pendingSeek: Double?
    private var pendingPlayingSince: Date?
    /// Runs only while playing.
    private var timer: Timer?

    override init() {
        super.init()
        player.delegate = self
        transcript.onSeek = { [weak self] t in self?.seek(to: t, follow: false) }
        transcript.onTogglePlay = { [weak self] in self?.togglePlay() }
    }

    func openVideo(_ url: URL) {
        // Subtitles opened before any media (subs-first flow) are kept unless a sibling is found;
        // subtitles belonging to a previous media file are always dropped.
        let keepSubs = videoURL == nil && subtitleURL != nil
        videoURL = url
        player.media = VLCMedia(url: url)
        player.play()
        player.rate = Float(rate)
        // Disable VLC's own subtitle rendering; the column is the subtitle display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.player.currentVideoSubTitleIndex = -1
            self.player.rate = Float(self.rate)
        }
        if let sibling = Self.findSiblingSubtitle(for: url) {
            openSubtitles(sibling)
        } else if !keepSubs {
            cues = []
            subtitleURL = nil
            transcript.load([], time: 0)
        }
    }

    func openSubtitles(_ url: URL) {
        do {
            cues = try SubtitleParser.parse(url: url)
            subtitleURL = url
            errorMessage = nil
            transcript.load(cues, time: currentTime)
        } catch {
            errorMessage = "Could not parse \(url.lastPathComponent): \(error)"
        }
    }

    static func findSiblingSubtitle(for video: URL) -> URL? {
        let base = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for ext in ["json", "en.vtt", "vtt", "en.srt", "srt"] where files.contains("\(base).\(ext)") {
            return dir.appendingPathComponent("\(base).\(ext)")
        }
        return nil
    }

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    /// `follow`: true for keyboard/slider seeks (column snaps to the new line); false for clicks
    /// in the column (the column must not move).
    func seek(to t: Double, follow: Bool = true) {
        let t = max(0, duration > 0 ? min(t, duration) : t)
        player.time = VLCTime(int: Int32(t * 1000))
        pendingSeek = t
        pendingPlayingSince = nil
        anchorTime = t
        anchorDate = Date()
        publish(t, force: true)
        if follow { transcript.follow(animated: false) }
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    private func publish(_ t: Double, force: Bool = false) {
        currentTime = t
        transcript.update(time: t)
        clock.update(t, force: force)
    }

    // MARK: VLCMediaPlayerDelegate

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated {
            let vlcTime = Double(player.time.intValue) / 1000
            if let p = pendingSeek {
                guard abs(vlcTime - p) < 1.5 else { return }
                pendingSeek = nil
            }
            anchorTime = vlcTime
            anchorDate = Date()
            if duration == 0, let len = player.media?.length.intValue, len > 0 { duration = Double(len) / 1000 }
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { syncPlaying() }
    }

    private func syncPlaying() {
        let playing = player.isPlaying
        guard playing != isPlaying else { return }
        // Re-anchor at the current extrapolated time so play/pause doesn't jump.
        anchorTime = currentTime
        anchorDate = Date()
        isPlaying = playing
        if playing {
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                t.tolerance = 0.005
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            clock.update(currentTime, force: true)
        }
    }

    private func tick() {
        guard player.isPlaying else { syncPlaying(); return }
        if pendingSeek != nil {
            if let since = pendingPlayingSince {
                if Date().timeIntervalSince(since) > 3 { pendingSeek = nil }
            } else { pendingPlayingSince = Date() }
        }
        publish(anchorTime + Date().timeIntervalSince(anchorDate) * rate)
    }
}
