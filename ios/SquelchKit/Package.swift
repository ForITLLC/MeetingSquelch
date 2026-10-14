// swift-tools-version:5.9
// SquelchKit: the iPhone remote's code. SquelchProtocol is the wire contract and is also compiled into the
// Mac app by build.sh, so it stays Foundation + CryptoKit only. SquelchRemote is the phone's side of it:
// finding the Mac, the connection, the Keychain. The app and its Controls extension both link it. SquelchWatchLink is
// what the Apple Watch app and the phone say over WatchConnectivity; the Watch links only that.
import PackageDescription

let package = Package(
    name: "SquelchKit",
    platforms: [.iOS("18.0"), .macOS(.v14), .visionOS("2.0"), .watchOS("11.0")],
    products: [
        .library(name: "SquelchProtocol", targets: ["SquelchProtocol"]),
        .library(name: "SquelchRemote", targets: ["SquelchRemote"]),
        .library(name: "SquelchWatchLink", targets: ["SquelchWatchLink"]),
    ],
    targets: [
        .target(name: "SquelchProtocol"),
        .target(name: "SquelchRemote", dependencies: ["SquelchProtocol"]),
        .target(name: "SquelchWatchLink", dependencies: ["SquelchProtocol"]),
        .testTarget(name: "SquelchProtocolTests", dependencies: ["SquelchProtocol"]),
        .testTarget(name: "SquelchRemoteTests", dependencies: ["SquelchRemote"]),
        .testTarget(name: "SquelchWatchLinkTests", dependencies: ["SquelchWatchLink"]),
    ]
)
