import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard CommandLine.arguments.count == 3 else { fail("usage: verify-native-release-ui.swift APP OUTPUT") }
let appPath = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
guard AXIsProcessTrusted() else { fail("Accessibility permission unavailable") }
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == appPath }) else { fail("Accepted installed app is not running") }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func text(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].compactMap { attr(e, $0) as? String }
}
func elements(_ e: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = [], remaining = 15000
    func visit(_ e: AXUIElement, _ depth: Int) {
        remaining -= 1
        guard remaining >= 0, depth < 36 else { fail("Accessibility tree exceeds bound") }
        result.append(e)
        for child in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
    }
    visit(e, 0); return result
}
func window() -> AXUIElement {
    guard let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement], let w = windows.first else { fail("Installed app has no window") }
    return w
}
func find(_ label: String) -> AXUIElement? {
    elements(window()).first { text($0).contains(label) }
}
func press(_ label: String) {
    guard let e = find(label), AXUIElementPerformAction(e, kAXPressAction as CFString) == .success else { fail("Cannot activate \(label)") }
}
func selected(_ label: String) -> Bool {
    guard let e = find(label) else { return false }
    return (attr(e, kAXValueAttribute) as? NSNumber)?.intValue == 1
        || (attr(e, kAXSelectedAttribute) as? Bool) == true
}
func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(10)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}
func rect(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func geometry(_ r: CGRect) -> [String: Double] {
    ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
}
app.activate(options: [.activateAllWindows])
press("Jobs")
guard waitFor({ selected("Jobs") }) else { fail("Jobs tab did not become selected") }
guard waitFor({ find("WhatsOnlineBox") != nil }), let box = find("WhatsOnlineBox"),
      let boxRect = rect(box), let windowRect = rect(window()), boxRect.width > 0, boxRect.height > 0 else { fail("What's online box is not visibly measurable") }
guard boxRect.minX >= windowRect.minX, boxRect.minX - windowRect.minX < 60,
      boxRect.maxX < windowRect.minX + windowRect.width * 0.55,
      abs(windowRect.maxY - boxRect.maxY) < 80 else { fail("What's online box is not at the bottom left") }
let labels = elements(box).flatMap { e -> [String] in
    var values = text(e)
    if (attr(e, kAXRoleAttribute) as? String) == kAXStaticTextRole, let v = attr(e, kAXValueAttribute) as? String { values.append(v) }
    return values
}
guard labels.contains(where: { $0.contains("Saka") }), labels.contains(where: { $0.contains("Ang") }) else { fail("What's online box does not show Saka and Ang") }
press("Chats")
guard waitFor({ selected("Chats") }) else { fail("Chats tab did not become selected") }
let inspectorLabels = ["Chat settings", "Project folder and skills", "Model and router status"]
if !inspectorLabels.allSatisfy({ find($0) != nil }) {
    guard let button = find("Show or hide the inspector"), (attr(button, kAXEnabledAttribute) as? Bool) == true else { fail("Select an existing chat to verify the inspector") }
    press("Show or hide the inspector")
}
guard waitFor({ inspectorLabels.allSatisfy { find($0) != nil } }) else { fail("Chats inspector is not visible") }
let report: [String: Any] = ["observed_at": ISO8601DateFormatter().string(from: Date()), "application": appPath,
    "pid": app.processIdentifier, "jobs_bottom_left_box": geometry(boxRect), "window": geometry(windowRect),
    "resident_labels": labels.filter { $0.contains("Saka") || $0.contains("Ang") }, "chats_inspector_controls": inspectorLabels]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
print("Verified installed Jobs bottom-left box, Saka/Ang labels, and Chats inspector")
