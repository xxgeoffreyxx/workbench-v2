import AVFoundation
import Foundation

/// Reads assistant messages aloud. `speakingID` tracks which message is playing.
public final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published public private(set) var speakingID: String?
    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, id: String) {
        stop()
        let plain = Self.plainText(fromMarkdown: text)
        guard !plain.isEmpty else { return }
        speakingID = id
        synthesizer.speak(AVSpeechUtterance(string: plain))
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingID = nil
    }

    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish() }
    public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish() }

    private func finish() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.synthesizer.isSpeaking else { return }
            self.speakingID = nil
        }
    }

    /// Turns markdown into speakable text: fenced code becomes "code block omitted",
    /// links keep their text, and emphasis/heading/list/quote markers are dropped.
    public static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence { lines.append("code block omitted.") }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            lines.append(stripInline(stripBlockPrefix(trimmed)))
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBlockPrefix(_ line: String) -> String {
        if line.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { return "" }
        return line.replacingOccurrences(
            of: #"^(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)+"#, with: "", options: .regularExpression)
    }

    private static func stripInline(_ line: String) -> String {
        var s = line
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),        // images -> alt text
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),          // links -> text
            (#"<(https?://[^>]+)>"#, "$1"),              // autolinks
            (#"`([^`]*)`"#, "$1"),                       // inline code
            (#"(\*\*|__)(.+?)\1"#, "$2"),                // bold
            (#"(?<![\w*])[*_]([^*_\s][^*_]*?)[*_](?![\w*])"#, "$1"), // italics
            (#"~~(.+?)~~"#, "$1"),                       // strikethrough
            (#"</?[A-Za-z][^>]*>"#, ""),                 // html tags
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
