import AVFoundation
import Foundation
import Speech

public enum DictationError: LocalizedError {
    case recognizerUnavailable
    case noMicrophone

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "Speech recognition isn't available for this language right now."
        case .noMicrophone: return "No usable microphone input was found."
        }
    }
}

/// Microphone dictation via SFSpeechRecognizer, on-device when the locale supports it.
/// Requires NSSpeechRecognitionUsageDescription and NSMicrophoneUsageDescription in Info.plist.
public final class Dictation: ObservableObject {
    @Published public private(set) var isRecording = false

    private let recognizer: SFSpeechRecognizer?
    /// Created only while dictating: an idle engine is enough to light the microphone indicator.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    public func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start(onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void) throws {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw DictationError.recognizerUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero format (no input device, or access denied) makes installTap raise an Objective-C exception.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            throw DictationError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        self.engine = engine
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            self.engine = nil
            throw error
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            DispatchQueue.main.async {
                if done {
                    onFinal(text ?? "")
                    self?.teardown()
                } else if let text {
                    onPartial(text)
                }
            }
        }
        isRecording = true
    }

    /// Stops listening; the final transcript is still delivered through `onFinal`.
    public func stop() {
        guard isRecording else { return }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request?.endAudio()
        isRecording = false
    }

    private func teardown() {
        if let engine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request = nil
        task = nil
        isRecording = false
    }
}
