// swift-tools-version:6.0
import PackageDescription

// Workbench-specific logic that has no dependency on Warden's app types, so it can be reused by a future iOS app
// and by the Babelfish bridge. The app target glues it into Warden's UI and tool loop.
let package = Package(
    name: "WorkbenchKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "WorkbenchKit", targets: ["WorkbenchKit"])],
    targets: [
        .target(name: "WorkbenchKit"),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit"]),
    ],
    swiftLanguageModes: [.v5]
)
