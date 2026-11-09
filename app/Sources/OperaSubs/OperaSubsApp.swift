import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PlayerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        handleArguments()
        // Playback shortcuts are bare keys (Space, arrows), which menu key equivalents would steal
        // from text fields such as the find bar. While editable text has focus, deliver them to it.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty, [" ", "\u{F702}", "\u{F703}"].contains(e.charactersIgnoringModifiers ?? ""),
                  let tv = e.window?.firstResponder as? NSTextView, tv.isEditable else { return e }
            tv.keyDown(with: e)
            return nil
        }
    }

    /// `OperaSubs [--subs FILE] [VIDEO]`
    private func handleArguments() {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--subs"), i + 1 < args.count {
            model.openSubtitles(URL(fileURLWithPath: args[i + 1]))
            args.removeSubrange(i...(i + 1))
        }
        if let v = args.first(where: { !$0.hasPrefix("-") }) { model.openVideo(URL(fileURLWithPath: v)) }
    }

    /// Finder / `open` file events (routed to the existing window, see `handlesExternalEvents`).
    func open(_ url: URL) {
        // Command-line file arguments may also arrive as open events; those are handled above.
        let argPaths = Set(CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !argPaths.contains(url.standardizedFileURL.path) else { return }
        if ["srt", "vtt", "json"].contains(url.pathExtension.lowercased()) { model.openSubtitles(url) } else { model.openVideo(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OperaSubsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Single window: File > New is removed, and external open events are routed to the
        // existing window instead of spawning a new one.
        WindowGroup("Opera Subs") {
            ContentView().environmentObject(delegate.model)
                .onOpenURL { delegate.open($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1280, height: 760)
        .commands { AppCommands(model: delegate.model) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: PlayerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Video…") { pick(subtitles: false) }.keyboardShortcut("o")
            Button("Open Subtitles…") { pick(subtitles: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Playback") {
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
            Button("Back 5s") { model.skip(-5) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Forward 5s") { model.skip(5) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back 30s") { model.skip(-30) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("Forward 30s") { model.skip(30) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            Divider()
            Picker("Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                ForEach(PlayerModel.rates, id: \.self) { Text(PlayerModel.rateLabel($0)).tag($0) }
            }
            Button("Faster") { model.stepRate(1) }.keyboardShortcut("+")
            Button("Slower") { model.stepRate(-1) }.keyboardShortcut("-")
            Button("Normal Speed") { model.setRate(1) }.keyboardShortcut("0")
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Transcript…") {
                model.showColumn = true  // the column may need a layout pass to rejoin the window
                DispatchQueue.main.async { model.transcript.find(.showFindInterface) }
            }.keyboardShortcut("f")
            Button("Find Next") { model.transcript.find(.nextMatch) }.keyboardShortcut("g")
            Button("Find Previous") { model.transcript.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu("Subtitles") {
            Toggle("Show Column", isOn: $model.showColumn).keyboardShortcut("l")
            Divider()
            Button("Bigger Text") { model.fontSize += 2 }.keyboardShortcut("+", modifiers: [.command, .option])
            Button("Smaller Text") { model.fontSize = max(10, model.fontSize - 2) }.keyboardShortcut("-", modifiers: [.command, .option])
        }
    }

    private func pick(subtitles: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if subtitles {
            panel.allowedContentTypes = ["srt", "vtt", "json"].compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK, let url = panel.url {
            subtitles ? model.openSubtitles(url) : model.openVideo(url)
        }
    }
}
