import AppKit
import SwiftUI
import WorkbenchKit

/// Microphone button: dictates into the message box on this Mac. Partial results show as you speak;
/// the text is appended to whatever was already typed.
struct DictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = Dictation()
    @State private var baseText = ""
    @State private var errorMessage: String?
    @AppStorage(AudioInputs.preferenceKey) private var preferredUID = ""

    var body: some View {
        Button(action: toggle) {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                .symbolEffect(.pulse, isActive: dictation.isRecording)
        }
        .buttonStyle(.plain)
        .help(dictation.isRecording
              ? "Stop dictation (\(dictation.deviceName ?? "microphone"))"
              : "Dictate with \(AudioInputs.resolve(preferredUID: preferredUID.isEmpty ? nil : preferredUID)?.name ?? "the default microphone"). Right-click to choose a microphone.")
        .accessibilityLabel("Dictation")
        .contextMenu {
            Button {
                preferredUID = ""
            } label: {
                if preferredUID.isEmpty { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(AudioInputs.all().filter { !$0.isVirtual }) { input in
                Button {
                    preferredUID = input.uid
                } label: {
                    if preferredUID == input.uid { Label(input.name, systemImage: "checkmark") } else { Text(input.name) }
                }
            }
        }
        .alert("Dictation unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func toggle() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        Task {
            guard await dictation.requestAuthorization() else {
                errorMessage = "Allow Workbench to use the microphone and speech recognition in System Settings → Privacy & Security."
                return
            }
            baseText = text.isEmpty ? "" : text + (text.hasSuffix(" ") ? "" : " ")
            do {
                try dictation.start(
                    onPartial: { partial in text = baseText + partial },
                    onFinal: { final in text = baseText + final }
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Camera button: takes an interactive screenshot (drag to select, space for a window) and attaches it.
struct ScreenshotButton: View {
    let onCapture: (URL) -> Void

    var body: some View {
        Button(action: capture) {
            Image(systemName: "camera.viewfinder").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach a screenshot")
        .accessibilityLabel("Screenshot")
    }

    private func capture() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("workbench-screenshot-\(Int(Date().timeIntervalSince1970)).png")
        let window = NSApp.keyWindow
        window?.orderOut(nil)
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            try? process.run()
            process.waitUntilExit()
            await MainActor.run {
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // Cancelling the capture leaves no file.
                if FileManager.default.fileExists(atPath: url.path) { onCapture(url) }
            }
        }
    }
}

/// Speaker button on assistant replies.
struct ReadAloudButton: View {
    let text: String
    let id: String
    @ObservedObject private var reader = WorkbenchSpeech.reader

    var body: some View {
        let speaking = reader.speakingID == id
        ToolbarButton(icon: speaking ? "stop.circle" : "speaker.wave.2", text: "") {
            if speaking { reader.stop() } else { reader.speak(text, id: id) }
        }
        .help(speaking ? "Stop reading" : "Read aloud")
        .accessibilityLabel(speaking ? "Stop reading" : "Read aloud")
    }
}

@MainActor
enum WorkbenchSpeech {
    static let reader = SpeechReader()
}
