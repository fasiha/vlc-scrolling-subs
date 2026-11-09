import AppKit
import SubtitleKit
import SwiftUI
import VLCKit

struct VideoView: NSViewRepresentable {
    let player: VLCMediaPlayer
    func makeNSView(context: Context) -> VLCVideoView {
        let v = VLCVideoView()
        v.backColor = .black
        player.drawable = v
        return v
    }
    func updateNSView(_ nsView: VLCVideoView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var model: PlayerModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    VideoView(player: model.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.videoURL == nil {
                        Text("File > Open Video… (⌘O)").foregroundStyle(.secondary)
                    }
                }
                .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
                .onTapGesture { model.togglePlay() }
                ControlsBar()
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if model.showColumn {
                SubtitleColumn()
                    .frame(minWidth: 180, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct ControlsBar: View {
    @EnvironmentObject var model: PlayerModel
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            TimeSlider(clock: model.clock, scrubbing: $scrubbing)
            Text(format(model.duration)).monospacedDigit().font(.caption)
            Menu(PlayerModel.rateLabel(model.rate)) {
                ForEach(PlayerModel.rates, id: \.self) { r in
                    Button(PlayerModel.rateLabel(r)) { model.setRate(r) }
                }
            }
            .menuStyle(.borderlessButton).font(.caption.monospacedDigit()).frame(width: 64).help("Playback speed (⌘+ / ⌘−)")
            Button { model.showColumn.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help("Toggle subtitle column (⌘L)")
        }
        .padding(8)
        .background(.bar)
    }

    func format(_ t: Double) -> String { Self.format(t) }
    static func format(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct TimeSlider: View {
    @EnvironmentObject var model: PlayerModel
    @ObservedObject var clock: TransportClock
    @Binding var scrubbing: Double?
    var body: some View {
        Text(ControlsBar.format(scrubbing ?? clock.time)).monospacedDigit().font(.caption)
        Slider(value: Binding(get: { scrubbing ?? clock.time }, set: { scrubbing = $0 }),
               in: 0...max(model.duration, 1)) { editing in
            if !editing, let s = scrubbing { model.seek(to: s); scrubbing = nil }
        }
    }
}

struct SubtitleColumn: View {
    @EnvironmentObject var model: PlayerModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TranscriptView(controller: model.transcript)
            if model.cues.isEmpty {
                Text("No subtitles.\nFile > Open Subtitles… (⇧⌘O)").multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            FollowButton(transcript: model.transcript)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FollowButton: View {
    @ObservedObject var transcript: TranscriptController
    var body: some View {
        if transcript.mode == .free {
            Button("Follow") { transcript.follow(animated: true) }
                .controlSize(.small).padding(8).help("Resume auto-scrolling to the current line")
        }
    }
}
