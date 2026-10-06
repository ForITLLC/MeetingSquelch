// fake-mac.swift: a stand-in Mac for sim-smoke.sh. The Mac app's real RemoteServer on port 47299 with a
// throwaway store, in a pretend Zoom call, toggling mute on every "mic" press. It opens a pairing window, writes
// the code's link (pointed at 127.0.0.1) to the path in argv[1], and exits after argv[2] seconds (default 120).
// Built by sim-smoke.sh together with Sources/RemoteServer.swift, Sources/Log.swift and SquelchProtocol.
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: fake-mac <url-file> [seconds]\n".data(using: .utf8)!)
    exit(2)
}
let urlFile = args[1]
let lifetime = args.count >= 3 ? TimeInterval(args[2]) ?? 120 : 120

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squelch-fake-mac-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let server = RemoteServer(port: 47299, dir: dir)
var state = RemoteMessage(t: "state", app: "Zoom", muted: false, camera: true, share: false)
server.onPress = { what, reply in
    print("press: \(what)")
    if what == "mic" { state.muted = !(state.muted ?? false) }
    reply(RemoteMessage(t: "done", what: what, app: "Zoom", muted: state.muted, ok: true))
    server.publish(state)
}
server.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    server.publish(state)
    var code = server.beginPairing()
    code.host = "127.0.0.1"
    try! code.url.absoluteString.write(toFile: urlFile, atomically: true, encoding: .utf8)
    print("pairing open")
}
DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
    try? FileManager.default.removeItem(at: dir)
    exit(0)
}
RunLoop.main.run()
