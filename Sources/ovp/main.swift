import Foundation
import AppKit

let argv = Array(CommandLine.arguments.dropFirst())
let exePath = (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) ?? "ovp"

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
ovp — OpenClaw Visual Preprocessor (Phase 1)

USAGE
  ovp inspect <file>                     inspect an image file
  ovp inspect --screen                   inspect the current main display
  ovp inspect --window <window_id>       inspect one window (window ids from `ovp windows`)
  ovp windows                            list on-screen windows (id, app, title, bounds)
  ovp daemon [--stop|--status]           manage the resident process (keeps Vision warm)
  ovp cache stats|clear                  cache inspection / invalidation
  ovp ax-check                           accessibility trust + AX tree size per app
  ovp version

OPTIONS (inspect)
  --level fast|normal     fast: OCR+meta+windows+AX, no CV regions (default normal)
  --max-chars N           compact text budget (default 500)
  --headline-only         ultra-cheap: preamble + headline + follow-up contract only
  --grep <substring>      query the cached state for matching text/ui (no re-capture)
  --region x,y,w,h        query the cached state inside a rect (no re-capture)
  --line-max N            per-line text cap (default 120)
  --no-group              one line per OCR item instead of grouped region lines
  --no-preamble           omit the "text-only model / do not call view_image" preamble
  --json                  print JSON Visual State only (--compact for one line)
  --both                  print JSON then compact text
  --no-cache              bypass both cache layers
  --standalone            do not use/start the daemon (cold path)
"""

func parseInspect(_ args: [String]) -> InspectOptions? {
    var target: InspectTarget? = nil
    var level = "normal"
    var maxChars = 500
    var noCache = false
    var o = InspectOptions(target: .screen)
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--screen": target = .screen
        case "--window":
            i += 1
            if i < args.count, let id = Int(args[i]) { target = .window(id) }
        case "--level":
            i += 1
            if i < args.count { level = args[i] }
        case "--max-chars":
            i += 1
            if i < args.count, let n = Int(args[i]) { maxChars = n }
        case "--no-cache": noCache = true
        case "--headline-only": o.headlineOnly = true
        case "--with-meta": o.withMeta = true
        case "--no-preamble": o.includePreamble = false
        case "--no-group": o.groupLines = false
        case "--line-max":
            i += 1
            if i < args.count, let n = Int(args[i]) { o.lineMax = n }
        case "--grep":
            i += 1
            if i < args.count { o.grep = args[i] }
        case "--region":
            i += 1
            if i < args.count { o.region = args[i].split(separator: ",").compactMap { Int($0) } }
        default:
            if !a.hasPrefix("--"), target == nil { target = .file((a as NSString).expandingTildeInPath) }
        }
        i += 1
    }
    guard let t = target else { return nil }
    if level != "fast" && level != "normal" { level = "normal" }
    o.target = t
    o.level = level
    o.maxChars = maxChars
    o.noCache = noCache
    return o
}

func printOutcome(_ resp: DaemonResponse, json: Bool, text: Bool, compact: Bool) {
    if json, let s = resp.state {
        out(encodeJSON(s, pretty: !compact))
    }
    if text, let t = resp.text {
        out(t)
    }
}

let cmd = argv.first ?? "help"
let rest = Array(argv.dropFirst())

switch cmd {
case "version":
    out("ovp 0.2.0")

case "help", "--help", "-h":
    out(usage)

case "windows":
    let list = windowList(onScreenOnly: true, maxLayers: 0)
    for w in list {
        out("\(w.id)\t\(w.app)\t\(w.title.isEmpty ? "-" : w.title)\t[\(Int(w.boundsPt.minX)),\(Int(w.boundsPt.minY)),\(Int(w.boundsPt.width)),\(Int(w.boundsPt.height))]")
    }

case "ax-check":
    out("AX trusted: \(AXIsProcessTrusted())")
    let s = mainScreenInfo()
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let snap = readAX(pid: app.processIdentifier, screen: s, budgetMs: 400, nodeCap: 400)
        if snap.available {
            out("\(app.localizedName ?? "?") pid=\(app.processIdentifier) nodes=\(snap.nodes) ui=\(snap.elements.count) ms=\(snap.ms) trunc=\(snap.truncated)")
        } else {
            out("\(app.localizedName ?? "?") pid=\(app.processIdentifier) AX: none")
        }
    }

case "cache":
    let sub = rest.first ?? "stats"
    let c = StateCache()
    if sub == "clear" {
        c.clear()
        out("cache cleared")
    } else {
        let s = c.stats()
        out("ocr=\(s.ocr) state=\(s.state) bytes=\(s.bytes) dir=\(c.root.path)")
    }

case "daemon":
    let sub = rest.first
    if sub == "--stop" {
        if let r = daemonCall(DaemonRequest(cmd: "shutdown", target: nil, path: nil, window_id: nil, level: nil, max_chars: nil, no_cache: nil)) {
            out("daemon stopped: \(r.text ?? "ok")")
        } else { out("no daemon running") }
        exit(0)
    }
    if sub == "--status" {
        if let r = daemonCall(DaemonRequest(cmd: "stats", target: nil, path: nil, window_id: nil, level: nil, max_chars: nil, no_cache: nil)) {
            out("daemon: up pid=\(r.text ?? "?")")
        } else { out("daemon: down") }
        exit(0)
    }
    let d = Daemon()
    d.start()   // never returns

case "inspect":
    let json = rest.contains("--json")
    let both = rest.contains("--both")
    let compact = rest.contains("--compact")
    let standalone = rest.contains("--standalone")
    guard let opt = parseInspect(rest) else { err("ovp inspect: need <file> | --screen | --window <id>"); exit(2) }

    let req = DaemonRequest(cmd: "inspect", target: {
        switch opt.target {
        case .file: return "file"
        case .screen: return "screen"
        case .window: return "window"
        }
    }(), path: {
        if case .file(let p) = opt.target { return p } else { return nil }
    }(), window_id: {
        if case .window(let id) = opt.target { return id } else { return nil }
    }(), level: opt.level, max_chars: opt.maxChars, no_cache: opt.noCache,
        headline_only: opt.headlineOnly, no_preamble: !opt.includePreamble,
        line_max: opt.lineMax, no_group: !opt.groupLines, grep: opt.grep, region: opt.region,
        with_meta: opt.withMeta)

    func runLocal() {
        do {
            let o = try inspect(opt, cache: StateCache(), ocr: OCREngine())
            printOutcome(DaemonResponse(ok: true, error: nil, state: o.state, text: o.text),
                         json: json || both, text: !json || both, compact: compact)
        } catch {
            err("ovp: \(error)")
            exit(1)
        }
    }

    if standalone {
        runLocal()
        exit(0)
    }
    if let r = daemonCall(req) {
        if !r.ok { err("ovp: \(r.error ?? "error")"); exit(1) }
        printOutcome(r, json: json || both, text: !json || both, compact: compact)
        exit(0)
    }
    // no daemon yet: start one (it warms Vision before listening), else fall back to cold local run
    if ensureDaemon(executable: exePath), let r = daemonCall(req) {
        if !r.ok { err("ovp: \(r.error ?? "error")"); exit(1) }
        printOutcome(r, json: json || both, text: !json || both, compact: compact)
        exit(0)
    }
    runLocal()

default:
    err("ovp: unknown command '\(cmd)'\n\n\(usage)")
    exit(2)
}
