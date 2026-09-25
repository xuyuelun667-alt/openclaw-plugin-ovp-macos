import Foundation
import Darwin

struct DaemonRequest: Codable {
    var cmd: String
    var target: String?      // file | screen | window
    var path: String?
    var window_id: Int?
    var level: String?
    var max_chars: Int?
    var no_cache: Bool?
    var headline_only: Bool?
    var no_preamble: Bool?
    var line_max: Int?
    var no_group: Bool?
    var grep: String?
    var region: [Int]?
    var with_meta: Bool?
}

struct DaemonResponse: Codable {
    var ok: Bool
    var error: String?
    var state: VisualState?
    var text: String?
}

enum OVP {
    static func socketPath() -> String { cacheRoot().appendingPathComponent("ovp.sock").path }
    static func pidPath() -> String { cacheRoot().appendingPathComponent("ovp.pid").path }
}

// MARK: - low level unix socket

private func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in bytes.enumerated() where i < dst.count - 1 { dst[i] = b }
    }
    return addr
}

func connectUnix(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = makeAddr(path)
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if rc != 0 { close(fd); return nil }
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { buf -> Int in
            write(fd, buf.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

func readLine(_ fd: Int32, maxBytes: Int = 8 * 1024 * 1024) -> Data? {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while out.count < maxBytes {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return out.isEmpty ? nil : out }
        out.append(contentsOf: buf[0..<n])
        if let nl = out.firstIndex(of: 0x0A) { return out.subdata(in: 0..<nl) }
    }
    return out
}

// MARK: - daemon

final class Daemon {
    let cache = StateCache()
    let ocr = OCREngine()
    var served = 0
    var ocrHits = 0

    func start() -> Never {
        let path = OVP.socketPath()
        _ = ocr.warm()                       // keep the Vision model resident
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { FileHandle.standardError.write(Data("socket() failed\n".utf8)); exit(1) }
        var addr = makeAddr(path)
        let bindRC = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0, listen(fd, 16) == 0 else {
            FileHandle.standardError.write(Data("bind/listen failed at \(path)\n".utf8)); exit(1)
        }
        try? "\(getpid())".write(toFile: OVP.pidPath(), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["OVP_VERBOSE"] == "1" {
            FileHandle.standardError.write(Data("ovp daemon listening on \(path) pid=\(getpid())\n".utf8))
        }
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let line = readLine(client), !line.isEmpty,
              let req = try? JSONDecoder().decode(DaemonRequest.self, from: line) else {
            respond(client, DaemonResponse(ok: false, error: "bad request", state: nil, text: nil))
            return
        }
        switch req.cmd {
        case "ping":
            respond(client, DaemonResponse(ok: true, error: nil, state: nil, text: "\(getpid())"))
        case "shutdown":
            respond(client, DaemonResponse(ok: true, error: nil, state: nil, text: "bye"))
            unlink(OVP.socketPath())
            exit(0)
        case "stats":
            let s = cache.stats()
            respond(client, DaemonResponse(ok: true, error: nil, state: nil,
                                           text: "served=\(served) ocr_hits=\(ocrHits) cache_ocr=\(s.ocr) cache_state=\(s.state) bytes=\(s.bytes)"))
        case "inspect":
            do {
                var opt = InspectOptions(target: parseTarget(req), level: req.level ?? "normal",
                                         maxChars: req.max_chars ?? 500, noCache: req.no_cache ?? false)
                opt.headlineOnly = req.headline_only ?? false
                opt.includePreamble = !(req.no_preamble ?? false)
                opt.lineMax = req.line_max ?? 120
                opt.groupLines = !(req.no_group ?? false)
                opt.grep = req.grep
                opt.region = req.region
                opt.withMeta = req.with_meta ?? false
                let out = try inspect(opt, cache: cache, ocr: ocr)
                served += 1
                if out.state.meta.cache.ocr == "hit" { ocrHits += 1 }
                respond(client, DaemonResponse(ok: true, error: nil, state: out.state, text: out.text))
            } catch {
                respond(client, DaemonResponse(ok: false, error: "\(error)", state: nil, text: nil))
            }
        default:
            respond(client, DaemonResponse(ok: false, error: "unknown cmd \(req.cmd)", state: nil, text: nil))
        }
    }

    private func respond(_ client: Int32, _ resp: DaemonResponse) {
        guard let d = try? JSONEncoder().encode(resp) else { return }
        var payload = d
        payload.append(0x0A)
        _ = writeAll(client, payload)
    }
}

func parseTarget(_ req: DaemonRequest) -> InspectTarget {
    switch req.target ?? "screen" {
    case "file": return .file(req.path ?? "")
    case "window": return .window(req.window_id ?? 0)
    default: return .screen
    }
}

// MARK: - client side

func daemonCall(_ req: DaemonRequest) -> DaemonResponse? {
    guard let fd = connectUnix(OVP.socketPath()) else { return nil }
    defer { close(fd) }
    guard let d = try? JSONEncoder().encode(req) else { return nil }
    var payload = d
    payload.append(0x0A)
    guard writeAll(fd, payload) else { return nil }
    guard let line = readLine(fd) else { return nil }
    return try? JSONDecoder().decode(DaemonResponse.self, from: line)
}

/// Returns true when a daemon is reachable (starting one if needed).
func ensureDaemon(executable: String, timeoutMs: Int = 40000, quiet: Bool = false) -> Bool {
    if daemonCall(DaemonRequest(cmd: "ping", target: nil, path: nil, window_id: nil,
                                level: nil, max_chars: nil, no_cache: nil)) != nil { return true }
    let shell = "/bin/sh"
    let cmd = "nohup '\(executable)' daemon >/dev/null 2>&1 &"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-c", cmd]
    try? p.run()
    p.waitUntilExit()
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if daemonCall(DaemonRequest(cmd: "ping", target: nil, path: nil, window_id: nil,
                                    level: nil, max_chars: nil, no_cache: nil)) != nil { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    if !quiet { FileHandle.standardError.write(Data("ovp: daemon did not come up within \(timeoutMs)ms\n".utf8)) }
    return false
}
