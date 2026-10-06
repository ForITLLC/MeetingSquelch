// MacFinder.swift: where to reach the paired Mac (docs/remote-protocol.md, Finding the Mac). Bonjour first: the
// _squelch._tcp service whose TXT "id" is the paired Mac's id. If Bonjour finds nothing within 2 s, the host and
// port from the pairing code, then the last address that worked.
import Foundation
import Network

/// DNSServiceErrorType kDNSServiceErr_PolicyDenied: iOS refused Local Network access.
let policyDenied: Int32 = -65570

public struct MacSearch: Equatable {
    public var endpoints: [NWEndpoint]
    public var bonjour: Bool          // the first endpoint came from Bonjour
    public var denied: Bool           // Local Network access is off for this app

    public init(endpoints: [NWEndpoint], bonjour: Bool, denied: Bool) {
        self.endpoints = endpoints
        self.bonjour = bonjour
        self.denied = denied
    }
}

public final class MacFinder {
    /// How long Bonjour gets before the stored addresses are tried.
    public var wait: TimeInterval
    public var useBonjour: Bool
    public var serviceType: String

    public init(wait: TimeInterval = 2, useBonjour: Bool = true, serviceType: String = Remote.serviceType) {
        self.wait = wait
        self.useBonjour = useBonjour
        self.serviceType = serviceType
    }

    /// The addresses to try for this Mac, best first, without duplicates.
    @MainActor
    public func search(_ p: StoredPairing) async -> MacSearch {
        var found: NWEndpoint?
        var denied = false
        if useBonjour { (found, denied) = await browse(mac: p.mac) }
        var out: [NWEndpoint] = found.map { [$0] } ?? []
        for (host, port) in [(p.host, p.port), (p.lastHost, p.lastPort ?? p.port)] {
            guard let h = host, let e = Self.endpoint(host: h, port: port), !out.contains(e) else { continue }
            out.append(e)
        }
        return MacSearch(endpoints: out, bonjour: found != nil, denied: denied && found == nil)
    }

    /// The service with TXT id == mac, or nil after `wait`. denied = the browser was refused Local Network access.
    @MainActor
    private func browse(mac: String) async -> (NWEndpoint?, Bool) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
        let run = Browse()
        return await withCheckedContinuation { (k: CheckedContinuation<(NWEndpoint?, Bool), Never>) in
            run.finish = { e in
                guard !run.done else { return }
                run.done = true
                b.stateUpdateHandler = nil
                b.browseResultsChangedHandler = nil
                b.cancel()
                k.resume(returning: (e, run.denied))
            }
            b.stateUpdateHandler = { st in
                MainActor.assumeIsolated {
                    switch st {
                    // While iOS shows the Local Network prompt the browser waits with PolicyDenied, then goes on
                    // once the user allows it. So a denial only counts if it still stands when the wait runs out.
                    case .waiting(let e): run.denied = Self.isDenied(e)
                    case .ready: run.denied = false
                    case .failed(let e):
                        run.denied = Self.isDenied(e)
                        run.finish(nil)
                    default: break
                    }
                }
            }
            b.browseResultsChangedHandler = { results, _ in
                MainActor.assumeIsolated {
                    if let r = results.first(where: { Self.txtID($0) == mac }) { run.finish(r.endpoint) }
                }
            }
            b.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated { run.finish(nil) } }
        }
    }

    // One browse's state, touched only on the main queue.
    private final class Browse {
        var done = false
        var denied = false
        var finish: (NWEndpoint?) -> Void = { _ in }
    }

    /// ws://host:port/ as a URL endpoint. A WebSocket NWConnection to a bare .hostPort endpoint is aborted
    /// (ECONNABORTED) before its upgrade request is sent; a URL or a Bonjour service endpoint works.
    public static func endpoint(host: String, port: UInt16) -> NWEndpoint? {
        guard !host.isEmpty, port != 0 else { return nil }
        // IPv6 goes in brackets, and its zone's % is escaped: ws://[fe80::1%25en0]:47214/
        let h = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "ws://\(h):\(port)/").map { NWEndpoint.url($0) }
    }

    static func txtID(_ r: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = r.metadata { return txt["id"] }
        return nil
    }

    static func isDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == policyDenied }
        return false
    }
}
