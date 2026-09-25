import Foundation
import AppKit
import CoreGraphics

enum InspectTarget: Equatable {
    case file(String)
    case screen
    case window(Int)
}

struct InspectOptions {
    var target: InspectTarget
    var level: String = "normal"     // fast | normal
    var maxChars: Int = 500
    var noCache: Bool = false
    // cost-control render options
    var headlineOnly: Bool = false
    var includePreamble: Bool = true
    var lineMax: Int = 120
    var groupLines: Bool = true
    var grep: String? = nil
    var region: [Int]? = nil
    var withMeta: Bool = false

    var renderOptions: TextRenderer.Options {
        TextRenderer.Options(maxChars: maxChars, headlineOnly: headlineOnly,
                             includePreamble: includePreamble, lineMax: lineMax,
                             groupLines: groupLines, grep: grep, region: region, withMeta: withMeta)
    }
}

struct InspectOutcome {
    var state: VisualState
    var text: String
    var json: String
}

/// The whole pipeline: capture -> metadata -> windows -> AX -> OCR -> regions -> priority -> state -> render.
func inspect(_ opt: InspectOptions, cache: StateCache, ocr: OCREngine) throws -> InspectOutcome {
    let tAll = Date()
    var timings: [String: Int] = [:]
    func mark(_ k: String, _ t0: Date) { timings[k] = Int(Date().timeIntervalSince(t0) * 1000) }

    // 1. capture
    var t = Date()
    let cap: Captured
    switch opt.target {
    case .file(let p): cap = try captureFile(p)
    case .screen: cap = try captureScreen()
    case .window(let id): cap = try captureWindow(id)
    }
    var source = cap.source
    mark("capture", t)

    // 2. windows / application information (CGWindowList)
    t = Date()
    let scale = cap.screen.scale
    let originX = cap.screen.originX, originY = cap.screen.originY
    func toPX(_ r: CGRect) -> [Int] {
        [Int(((Double(r.origin.x) - originX) * scale).rounded()),
         Int(((Double(r.origin.y) - originY) * scale).rounded()),
         Int((Double(r.width) * scale).rounded()),
         Int((Double(r.height) * scale).rounded())]
    }
    let frontApp = frontmostAppName()
    var rawWindows: [RawWindow] = []
    var windows: [WindowInfo] = []
    switch opt.target {
    case .screen:
        rawWindows = windowList(onScreenOnly: true, maxLayers: 0)
        // the app's main window is its largest layer-0 window (Chrome exposes several small strips)
        var frontID = -1
        if let fa = frontApp {
            let candidates = rawWindows.filter { $0.app == fa }
            if let biggest = candidates.max(by: { ($0.boundsPt.width * $0.boundsPt.height) < ($1.boundsPt.width * $1.boundsPt.height) }) {
                frontID = biggest.id
            }
        }
        for w in rawWindows.prefix(12) {
            windows.append(WindowInfo(id: w.id, app: w.app, title: w.title.isEmpty ? nil : truncate(w.title, 80),
                                      layer: w.layer, z: w.z, bounds_pt: [Double(w.boundsPt.minX), Double(w.boundsPt.minY),
                                                                           Double(w.boundsPt.width), Double(w.boundsPt.height)],
                                      bounds_px: toPX(w.boundsPt), frontmost: w.id == frontID))
        }
    case .window(let id):
        if let w = windowList(onScreenOnly: false).first(where: { $0.id == id }) {
            rawWindows = [w]
            windows = [WindowInfo(id: w.id, app: w.app, title: w.title.isEmpty ? nil : truncate(w.title, 80),
                                  layer: w.layer, z: 0,
                                  bounds_pt: [Double(w.boundsPt.minX), Double(w.boundsPt.minY),
                                              Double(w.boundsPt.width), Double(w.boundsPt.height)],
                                  bounds_px: [0, 0, cap.image.width, cap.image.height], frontmost: true)]
        }
    case .file:
        break   // a file has no live window context; do not invent one
    }
    mark("windows", t)

    // decide app / title — never borrow the frontmost app for a plain file
    var appName: String? = nil
    var windowTitle: String? = nil
    switch opt.target {
    case .file:
        appName = "unknown"               // explicit, per source-kind contract
        windowTitle = nil
    case .window:
        appName = source.app ?? "unknown"
        windowTitle = source.title
    case .screen:
        appName = frontApp
        if let fw = windows.first(where: { $0.frontmost }) {
            appName = fw.app
            windowTitle = fw.title
        }
    }

    // 3. Accessibility-first (live screen / window sources only)
    t = Date()
    var ax = AXSnapshot()
    var axPid: pid_t = 0
    switch opt.target {
    case .screen: axPid = frontmostPid()
    case .window: axPid = rawWindows.first?.pid ?? 0
    case .file: axPid = 0
    }
    if axPid > 0 {
        let budget = opt.level == "fast" ? 300 : 800
        let cap2 = opt.level == "fast" ? 400 : 1500
        var restrict: CGRect? = nil
        if case .window = opt.target { restrict = rawWindows.first?.boundsPt }
        ax = readAX(pid: axPid, screen: cap.screen, budgetMs: budget, nodeCap: cap2, restrictPt: restrict)
        ax = sanitizeAX(ax, imageW: cap.image.width, imageH: cap.image.height)
    }
    mark("ax", t)

    // 4. OCR (cacheable by raw-pixel hash)
    t = Date()
    var cacheInfo = CacheInfo(ocr: opt.noCache ? "disabled" : "miss", state: "disabled")
    var items: [OCRItem] = []
    if let hit = opt.noCache ? nil : cache.getOCR(cap.image.sha256) {
        items = hit
        cacheInfo.ocr = "hit"
    } else {
        items = ocr.recognize(cap.cgImage, fast: false)
        if !opt.noCache { cache.putOCR(cap.image.sha256, items) }
        cacheInfo.ocr = opt.noCache ? "disabled" : "miss"
    }
    mark("ocr", t)

    // 4b. file-source refinement: dense small text implies a screen capture after all
    if case .file = opt.target, source.kind == "image_file", items.count >= 12 {
        source.kind = "screenshot_file"
        source.kind_reason = "text-density(ocr=\(items.count))"
    }

    // 5. text items: noise + duplicate marking, then region assignment
    var duplicatesDropped = 0
    var noiseDropped = 0
    var kept: [TextItem] = []
    var seen: [String: [Int]] = [:]
    for it in items {
        let noise = Priority.isNoise(it.text, confidence: it.confidence)
        if !noise {
            if Priority.isDuplicate(it.text, bbox: it.bbox, seen: seen) { duplicatesDropped += 1; continue }
            seen[it.text.lowercased().trimmingCharacters(in: .whitespaces)] = it.bbox
        } else {
            noiseDropped += 1
        }
        kept.append(TextItem(id: "t\(kept.count + 1)", text: it.text, bbox: it.bbox,
                             confidence: it.confidence, region_id: nil,
                             cls: "normal", noise: noise ? true : nil))
    }
    var text = kept

    t = Date()
    var regions = RegionFinder.detect(bitmap: cap.bitmap, screen: cap.screen, frontApp: appName,
                                      windows: windows, dialogs: ax.dialogs, level: opt.level)
    RegionFinder.assignText(&text, regions: &regions)
    let dialogRects = regions.filter { $0.kind == "dialog" }.map { $0.bbox }
    let foregroundRect = windows.first(where: { $0.frontmost })?.bounds_px
    // 5b. priority classification (alert > error > focus > foreground > result > normal)
    // two passes: strong evidence first; bare dialog-button labels are only trusted afterwards
    for i in text.indices {
        let c = Priority.classify(text: text[i].text, bbox: text[i].bbox, dialogRects: dialogRects,
                                  foregroundRect: foregroundRect, allowButtonWords: false,
                                  focusedBBox: ax.focused?.bbox, focusedTitle: ax.focused?.title,
                                  focusedValue: nil)
        text[i].cls = c.rawValue
    }
    let strongEvidence = !dialogRects.isEmpty || text.contains { $0.cls == "alert" || $0.cls == "error" }
    if strongEvidence {
        for i in text.indices where text[i].cls == "normal" {
            let c = Priority.classify(text: text[i].text, bbox: text[i].bbox, dialogRects: dialogRects,
                                      foregroundRect: foregroundRect, allowButtonWords: true,
                                      focusedBBox: ax.focused?.bbox, focusedTitle: ax.focused?.title,
                                      focusedValue: nil)
            if c == .alert { text[i].cls = c.rawValue }
        }
    }
    mark("regions", t)

    // 6. objects: only from AX (no pixel guessing in this phase)
    let objects: [StateObject] = ax.elements.filter { $0.type == "image" }.prefix(10).enumerated().map {
        StateObject(id: "o\($0.offset + 1)", kind: "image", bbox: $0.element.bbox,
                    label: $0.element.title, source: "ax", confidence: 1.0)
    }

    // 7. meta numbers
    let weighted = text.filter { $0.noise != true }.reduce(0.0) { $0 + $1.confidence * Double(max(1, $1.text.count)) }
    let weight = text.filter { $0.noise != true }.reduce(0.0) { $0 + Double(max(1, $1.text.count)) }
    let confidence = weight > 0 ? weighted / weight : 0.0
    var explain: [[Int]] = text.filter { $0.noise != true }.map { $0.bbox }
    for r in regions where r.kind == "window" || r.kind == "dialog" { explain.append(r.bbox) }
    let imgArea = Double(cap.image.width * cap.image.height)
    let coverage = imgArea > 0 ? min(1.0, rectUnionArea(explain) / imgArea) : 0.0

    var counts = ClassCounts(alert: 0, error: 0, focus: 0, foreground: 0, result: 0, normal: 0)
    for t in text where t.noise != true {
        switch TextClass(rawValue: t.cls ?? "normal")! {
        case .alert: counts.alert += 1
        case .error: counts.error += 1
                case .focus: counts.focus += 1
        case .foreground: counts.foreground += 1
        case .result: counts.result += 1
        case .normal: counts.normal += 1
        }
    }

    let accessibility = (ax.available && !ax.unreliable) ? "available" : "unavailable"
    let state = StateInfo(app: appName, window_title: windowTitle, accessibility: accessibility,
                          ax_available: ax.available, ax_truncated: ax.truncated,
                          ax_unreliable: ax.unreliable, ax_dropped: ax.dropped, ax_nodes: ax.nodes,
                          windows: windows, focused: ax.focused)

    let hash = computeStateHash(imageSHA: cap.image.sha256, level: opt.level,
                                windows: windows, text: text, ui: ax.elements)

    // 8. state cache
    var cachedHit = false
    var vs: VisualState
    if !opt.noCache, let cached = cache.getState(hash) {
        vs = cached
        cacheInfo.state = "hit"
        cachedHit = true
    } else {
        let placeholder = HiddenInfo(text_lines_shown: 0, text_lines_hidden: 0, ui_elements_hidden: 0,
                                     regions_hidden: 0, duplicates_dropped: duplicatesDropped,
                                     noise_dropped: noiseDropped)
        let meta = Meta(level: opt.level, role: "visual_input_substitute",
                        latency_ms: 0, coverage: coverage, confidence: confidence,
                        truncated: false, escalation: nil, hidden: placeholder, class_counts: counts, tokens_est: 0,
                        timings: timings, cache: cacheInfo, ocr_lines: text.filter { $0.noise != true }.count,
                        image_sha256: cap.image.sha256)
        vs = VisualState(image: cap.image, source: source, regions: regions, text: text,
                         ui_elements: ax.elements, objects: Array(objects), state: state,
                         meta: meta, state_hash: hash)
    }

    // 9. selection pass -> truncation facts -> render
    let sel = TextRenderer.selection(vs, opt.renderOptions)
    let interestingUI = vs.ui_elements.filter {
        ["button", "text_field", "text_area", "checkbox", "radio_button", "popup_button", "menu_button",
         "close_button", "tab_group", "dialog", "slider", "link", "menu_item", "progress", "disclosure"].contains($0.type)
    }.count
    let uiShown = min(interestingUI, max(3, opt.maxChars / 40))
    let usable = vs.text.filter { $0.noise != true }.count
    let shownIDs = Set(sel.items.map { $0.id })
    let regionsHidden = vs.regions.filter { r in
        r.kind == "generic_region" && !vs.text.contains { shownIDs.contains($0.id) && $0.region_id == r.id }
    }.count
    let hidden = HiddenInfo(text_lines_shown: sel.items.count,
                            text_lines_hidden: max(0, usable - sel.items.count),
                            ui_elements_hidden: max(0, interestingUI - uiShown),
                            regions_hidden: regionsHidden,
                            duplicates_dropped: duplicatesDropped,
                            noise_dropped: noiseDropped)
    // 8b. escalation decision — triggers came from measured real-scene comparisons:
    //   possible_dialog: text smells like a dialog/error but no structure was detected (AX absent,
    //                    e.g. a screenshot file). A VL model answered this correctly in testing.
    //   icon_heavy:      almost no readable text + almost no coverage => the frame is graphics/icons.
    //                    OVP has nothing to say here; a VL model described the controls.
    var escalation: String? = nil
    let usableText = vs.text.filter { $0.noise != true }.count
    let hasDialogRegion = vs.regions.contains { $0.kind == "dialog" }
    let alertish = counts.alert + counts.error
    if !hasDialogRegion && alertish > 0 {
        escalation = "vlm:possible_dialog"
    } else if coverage < 0.10 && usableText < 8 {
        escalation = "vlm:icon_heavy"
    }
    vs.meta.escalation = escalation
    vs.meta.hidden = hidden
    vs.meta.truncated = hidden.text_lines_hidden > 0 || hidden.ui_elements_hidden > 0
    vs.meta.class_counts = counts
    vs.meta.cache = cacheInfo
    vs.meta.latency_ms = Int(Date().timeIntervalSince(tAll) * 1000)
    vs.meta.timings = timings

    let rendered0 = TextRenderer.render(vs, opt.renderOptions)
    vs.meta.tokens_est = estimateTokens(rendered0)
    let rendered = TextRenderer.render(vs, opt.renderOptions)
    if !cachedHit, !opt.noCache { cache.putState(hash, vs) }
    return InspectOutcome(state: vs, text: rendered, json: encodeJSON(vs, pretty: true))
}
