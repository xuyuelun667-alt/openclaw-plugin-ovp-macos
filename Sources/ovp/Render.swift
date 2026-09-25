import Foundation

/// Cost-aware compact renderer.
///
/// Priorities (highest first): dialog/alert text -> error text -> focused element -> result-ish text -> rest.
/// The output always states (a) that OVP is a substitute for visual input, (b) whether it was truncated,
/// (c) which follow-up queries are available. Silence about truncation is a cost bug: the agent then
/// re-derives the whole screen with other tools.
enum TextRenderer {

    static let preamble = "You are a text-only model. Do not call view_image. Visual information has been preprocessed by OVP and is provided below."

    struct Options {
        var maxChars: Int = 500
        var headlineOnly: Bool = false
        var includePreamble: Bool = true
        var lineMax: Int = 120
        var groupLines: Bool = true
        var grep: String? = nil
        var region: [Int]? = nil
        var withMeta: Bool = false
    }

    static func render(_ s: VisualState, _ o: Options) -> String {
        // ---- query modes operate on the (cached) state, they never re-capture ----
        if let pat = o.grep { return renderGrep(s, pat, o) }
        if let r = o.region { return renderRegion(s, r, o) }

        var out: [String] = []
        if o.includePreamble { out.append(preamble) }

        let m = s.meta
        let shown = m.hidden.text_lines_shown
        let hidden = m.hidden.text_lines_hidden
        let focused = s.state.focused

        // ---- headline: the one line that must carry the answer-bearing facts ----
        var head = "HEADLINE: source=\(s.source.kind)"
        head += " app=\(s.source.app ?? "unknown")"
        if let w = s.state.window_title, !w.isEmpty { head += " window=\"\(truncate(w, 60))\"" }
        let dialogs = s.regions.filter { $0.kind == "dialog" }.count
        head += " | dialog=\(dialogs) text=\(s.text.count) shown=\(shown)"
        head += " ui=\(s.ui_elements.count)"
        if let f = focused {
            head += " focused=\(f.role ?? "?")"
            if let t = f.title, !t.isEmpty { head += " \"\(truncate(t, 30))\"" }
        }
        head += " | alert=\(m.class_counts.alert) error=\(m.class_counts.error) focus=\(m.class_counts.focus)"
        head += " result=\(m.class_counts.result) fg=\(m.class_counts.foreground)"
        head += " | truncated=\(m.truncated)"
        out.append(head)

        if o.headlineOnly {
            out.append(moreLine(s, o))
            return clamp(out, o.maxChars)
        }

        // ---- priority blocks ----
        let picked = selection(s, o)
        let rendered = picked.items

        let alertItems = rendered.filter { $0.cls == "alert" || $0.cls == "error" }
        if !alertItems.isEmpty {
            out.append("ALERT/ERROR (\(alertItems.count)):")
            for t in alertItems.prefix(6) { out.append("  " + oneLine(t, o, withTag: true)) }
        }

        let body = rendered.filter { $0.cls != "alert" && $0.cls != "error" }
        out.append("TEXT (\(s.text.count) total, \(body.count) shown):")
        if o.groupLines {
            for (rid, items) in groupByRegion(body, regions: s.regions) {
                let bboxStr = items.first.map { $0.bbox.map(String.init).joined(separator: ",") } ?? ""
                let head2 = rid.isEmpty ? "[\(bboxStr)]" : "[\(rid) \(bboxStr)]"
                let joined = items.map { itemText($0, o) }.joined(separator: " · ")
                out.append("  \(head2) \(joined)")
            }
        } else {
            for t in body { out.append("  " + oneLine(t, o, withTag: true)) }
        }

        if !s.ui_elements.isEmpty {
            let interesting = s.ui_elements.filter {
                ["button", "text_field", "text_area", "checkbox", "radio_button", "popup_button", "menu_button",
                 "close_button", "tab_group", "dialog", "slider", "link", "menu_item", "progress", "disclosure"].contains($0.type)
            }
            let uiBudget = max(3, o.maxChars / 40)
            out.append("UI (\(interesting.count)):")
            for u in interesting.prefix(uiBudget) { out.append("  " + oneUI(u)) }
            if interesting.count > uiBudget { out.append("  …(+\(interesting.count - uiBudget) ui)") }
        }

        out.append(moreLine(s, o))
        if let esc = s.meta.escalation {
            out.append("ESCALATE: \(esc) | local state is insufficient here; an opt-in vision call can resolve it (sends the image off-machine).")
        }
        if o.withMeta {
            out.append("META: \(m.level) \(m.latency_ms)ms cov=\(f2(m.coverage)) conf=\(f2(m.confidence)) "
                       + "cache=\(m.cache.ocr)/\(m.cache.state) hash=\(shortHash(s.state_hash)) ~\(m.tokens_est)t")
        }
        return clamp(out, o.maxChars)
    }

    // MARK: - follow-up queries

    private static func renderGrep(_ s: VisualState, _ pat: String, _ o: Options) -> String {
        var out: [String] = []
        if o.includePreamble { out.append(preamble) }
        let lower = pat.lowercased()
        let direct = s.text.filter { $0.text.lowercased().contains(lower) }
        // a label alone is rarely the answer ("总营收" vs its value) - pull in what sits next to it
        var hits = direct
        var seenIDs = Set(direct.map { $0.id })
        for d in direct {
            for t in s.text where !seenIDs.contains(t.id) {
                let sameRegion = (t.region_id != nil && t.region_id == d.region_id)
                let nearVert = abs(t.bbox[1] - d.bbox[1]) <= 60
                let nearHoriz = abs(t.bbox[0] - d.bbox[0]) <= 700
                if sameRegion || (nearVert && nearHoriz) { hits.append(t); seenIDs.insert(t.id) }
            }
        }
        hits.sort { ($0.bbox[1], $0.bbox[0]) < ($1.bbox[1], $1.bbox[0]) }
        let uiHits = s.ui_elements.filter {
            ($0.title ?? "").lowercased().contains(lower) || ($0.value ?? "").lowercased().contains(lower)
        }
        out.append("GREP \"\(pat)\": direct=\(direct.count) with-context=\(hits.count) ui=\(uiHits.count)  (source=\(s.source.kind) hash=\(shortHash(s.state_hash)))")
        for t in hits.prefix(40) { out.append("  " + oneLine(t, o, withTag: true)) }
        for u in uiHits.prefix(20) { out.append("  " + oneUI(u)) }
        if hits.isEmpty && uiHits.isEmpty {
            out.append("  no match. try a shorter substring, or --max-chars/--region for the full state.")
        }
        return clamp(out, max(o.maxChars, 800))
    }

    private static func renderRegion(_ s: VisualState, _ r: [Int], _ o: Options) -> String {
        var out: [String] = []
        if o.includePreamble { out.append(preamble) }
        func hit(_ b: [Int]) -> Bool {
            !(b[0] + b[2] < r[0] || b[0] > r[0] + r[2] || b[1] + b[3] < r[1] || b[1] > r[1] + r[3])
        }
        let texts = s.text.filter { hit($0.bbox) }
        let uis = s.ui_elements.filter { hit($0.bbox) }
        let regs = s.regions.filter { hit($0.bbox) }
        out.append("REGION [\(r.map(String.init).joined(separator: ","))]: text=\(texts.count) ui=\(uis.count) regions=\(regs.count)  (source=\(s.source.kind) hash=\(shortHash(s.state_hash)))")
        for g in regs.prefix(5) { out.append("  region \(g.kind) [\(g.bbox.map(String.init).joined(separator: ","))]") }
        for t in texts.prefix(40) { out.append("  " + oneLine(t, o, withTag: true)) }
        for u in uis.prefix(20) { out.append("  " + oneUI(u)) }
        if texts.isEmpty && uis.isEmpty { out.append("  nothing in that rect.") }
        return clamp(out, max(o.maxChars, 800))
    }

    // MARK: - helpers

    private static func moreLine(_ s: VisualState, _ o: Options) -> String {
        let h = s.meta.hidden
        var more = "MORE: truncated=\(s.meta.truncated)"
        if s.meta.truncated {
            more += " hidden=text:\(h.text_lines_hidden) ui:\(h.ui_elements_hidden) reg:\(h.regions_hidden) dup:\(h.duplicates_dropped) noise:\(h.noise_dropped)"
        }
        more += " | query: --grep <s> | --region x,y,w,h | --max-chars N | --headline-only"
        return more
    }

    private static func groupByRegion(_ items: [TextItem], regions: [Region]) -> [(String, [TextItem])] {
        var order: [String] = []
        var map: [String: [TextItem]] = [:]
        for t in items {
            let key = t.region_id ?? "?"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(t)
        }
        // keep region order as it appears in the state, orphans last
        var out: [(String, [TextItem])] = []
        for (i, r) in regions.enumerated() {
            if let v = map[r.id] { out.append(("r\(i + 1)/\(r.kind)", v)) }
        }
        if let orphan = map["?"] { out.append(("", orphan)) }
        if out.isEmpty { out = order.compactMap { k in map[k].map { (k, $0) } } }
        return out
    }

    /// Measured overhead of the fixed parts, so content selection always leaves room for them.
    static func reserve(_ o: Options) -> Int {
        var r = 0
        if o.includePreamble { r += preamble.count + 1 }
        r += 170          // headline
        r += 175          // MORE / follow-up contract
        r += 60           // section headers + slack
        if o.withMeta { r += 95 }
        return r
    }

    /// Deterministic content selection: priority order, then budget. Shared by the pipeline
    /// (to fill `meta.hidden`) and by the renderer, so the two never disagree.
    static func selection(_ s: VisualState, _ o: Options) -> (items: [TextItem], hidden: Int) {
        let ranked = s.text.filter { $0.noise != true }.sorted {
            let a = TextClass(rawValue: $0.cls ?? "normal")!.rank
            let b = TextClass(rawValue: $1.cls ?? "normal")!.rank
            if a != b { return a < b }
            return ($0.bbox[1], $0.bbox[0]) < ($1.bbox[1], $1.bbox[0])
        }
        var budget = o.maxChars - reserve(o)
        budget = max(60, budget)
        var used = 0
        var picked: [TextItem] = []
        for t in ranked {
            let cost = lineCost(t, o)
            if used + cost > budget { break }
            used += cost
            picked.append(t)
        }
        // an alert/error line is never silently dropped by budget
        let alerts = ranked.filter { $0.cls == "alert" || $0.cls == "error" }
        for a in alerts where !picked.contains(where: { $0.id == a.id }) { picked.append(a) }
        return (picked, max(0, ranked.count - picked.count))
    }

    private static func itemText(_ t: TextItem, _ o: Options) -> String {
        let tag = TextClass(rawValue: t.cls ?? "normal")!.tag
        let prefix = tag == " " ? "" : "\(tag) "
        return "\(prefix)\(truncate(t.text, o.lineMax))"
    }

    private static func oneLine(_ t: TextItem, _ o: Options, withTag: Bool) -> String {
        let tag = withTag ? TextClass(rawValue: t.cls ?? "normal")!.tag : " "
        let b = t.bbox.map(String.init).joined(separator: ",")
        return "\(tag)[\(b)] c=\(f2(t.confidence)) \(truncate(t.text, o.lineMax))"
    }

    private static func oneUI(_ u: UIElement) -> String {
        var d = "\(u.type)"
        if let t = u.title, !t.isEmpty { d += " \"\(truncate(t, 40))\"" }
        if let v = u.value, !v.isEmpty, u.type == "text_field" || u.type == "text_area" { d += " val=\"\(truncate(v, 40))\"" }
        d += " [\(u.bbox.map(String.init).joined(separator: ","))]"
        if let a = u.actions, !a.isEmpty { d += " act=\(a.prefix(3).joined(separator: ","))" }
        return d
    }

    private static func lineCost(_ t: TextItem, _ o: Options) -> Int {
        min(t.text.count, o.lineMax) + 26
    }

    private static func clamp(_ lines: [String], _ maxChars: Int) -> String {
        // line-wise: never cut a line in half; the decision-bearing lines (HEADLINE +
        // the MARROW contract) are never dropped, even when the budget is tiny.
        var out: [String] = []
        var used = 0
        for l in lines {
            let essential = l.hasPrefix("MORE:") || l.hasPrefix("META:") || l.hasPrefix("HEADLINE:") || l.hasPrefix("ESCALATE:")
            let cost = l.count + 1
            if !essential && used + cost > maxChars { continue }
            if used + cost > maxChars + 200 { break }
            out.append(l)
            used += cost
        }
        return out.joined(separator: "\n")
    }

    private static func f2(_ d: Double) -> String { String(format: "%.2f", d) }
}
