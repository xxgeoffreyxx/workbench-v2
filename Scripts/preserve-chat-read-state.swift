import Foundation
import CoreFoundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard CommandLine.arguments.count == 4 else { fail("usage: preserve-chat-read-state.swift snapshot|restore|verify DOMAIN FILE") }
let mode = CommandLine.arguments[1], domain = CommandLine.arguments[2] as CFString
let path = URL(fileURLWithPath: CommandLine.arguments[3])
let keys = ["workbench.chatUnreadSince", "workbench.chatLastViewed"]
func values() -> [String: Any] {
    var result: [String: Any] = [:]
    for key in keys {
        if let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
            result[key] = value
        }
    }
    return result
}
guard CFPreferencesAppSynchronize(domain) else { fail("Cannot synchronize read-state preferences") }
if mode == "snapshot" {
    let data = try PropertyListSerialization.data(fromPropertyList: ["domain": domain as String, "values": values()], format: .binary, options: 0)
    try data.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
} else {
    guard let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), options: [], format: nil) as? [String: Any],
          saved["domain"] as? String == domain as String,
          let original = saved["values"] as? [String: Any], Set(original.keys).isSubset(of: Set(keys)) else {
        fail("Invalid read-state snapshot")
    }
    if mode == "restore" {
        for key in keys {
            CFPreferencesSetValue(key as CFString, original[key] as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesAppSynchronize(domain) else { fail("Cannot persist restored read state") }
    } else if mode != "verify" { fail("Unknown read-state operation") }
    guard NSDictionary(dictionary: values()).isEqual(to: original) else { fail("Read-state restoration mismatch") }
    print("Read-state keys and absence restored; other preferences untouched")
}
