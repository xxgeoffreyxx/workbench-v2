import Foundation
import WorkbenchKit

/// Plain-text diagnostics at ~/Library/Application Support/Workbench/diagnostics.log: one line per send, result
/// and error, so failures can be traced without a debugger. Never logs message content or keys.
enum Diagnostics {
    private static let url = Workbench.supportDirectory.appendingPathComponent("diagnostics.log")
    private static let queue = DispatchQueue(label: "workbench.diagnostics")
    private static let formatter = ISO8601DateFormatter()

    static func log(_ line: String) {
        let entry = "\(formatter.string(from: Date())) \(line)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                try? handle.close()
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
