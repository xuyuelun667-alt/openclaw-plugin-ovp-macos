import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - CGWindowList

struct RawWindow {
    var id: Int
    var pid: Int32
    var app: String
    var title: String
    var layer: Int
    var boundsPt: CGRect
    var z: Int
}

func windowList(onScreenOnly: Bool, maxLayers: Int = 0) -> [RawWindow] {
    let opts: CGWindowListOption = onScreenOnly
        ? [.optionOnScreenOnly, .excludeDesktopElements]
        : [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [RawWindow] = []
    for (i, w) in list.enumerated() {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
        if layer > max(0, maxLayers) { continue }
        guard let d = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        let rect = CGRect(x: (d["X"] as? NSNumber)?.doubleValue ?? 0,
                          y: (d["Y"] as? NSNumber)?.doubleValue ?? 0,
                          width: (d["Width"] as? NSNumber)?.doubleValue ?? 0,
                          height: (d["Height"] as? NSNumber)?.doubleValue ?? 0)
        if rect.width < 20 || rect.height < 20 { continue }
        out.append(RawWindow(id: (w[kCGWindowNumber as String] as? Int) ?? 0,
                             pid: Int32((w[kCGWindowOwnerPID as String] as? Int) ?? 0),
                             app: (w[kCGWindowOwnerName as String] as? String) ?? "",
                             title: (w[kCGWindowName as String] as? String) ?? "",
                             layer: layer, boundsPt: rect, z: i))
    }
    return out
}

// MARK: - AX

struct AXSnapshot {
    var trusted: Bool = false
    var available: Bool = false
    var truncated: Bool = false
    var unreliable: Bool = false
    var dropped: Int = 0
    var nodes: Int = 0
    var elements: [UIElement] = []
    var dialogs: [[Int]] = []          // px bboxes of AXSheet/AXDialog/alert windows
    var focused: FocusedInfo? = nil
    var appWindows: [[Int]] = []       // px bboxes of AX windows
    var ms: Int = 0
}

/// Drop AX elements whose bbox lies outside the captured frame.
/// Some apps (notably Electron shells) report inconsistent AX geometry; keeping those
/// rects would make the state actively wrong, so they are dropped and flagged instead.
func sanitizeAX(_ snap: AXSnapshot, imageW: Int, imageH: Int, tolerance: Int = 4) -> AXSnapshot {
    var s = snap
    func inside(_ b: [Int]) -> Bool {
        guard b.count == 4, b[2] > 0, b[3] > 0 else { return false }
        return b[0] >= -tolerance && b[1] >= -tolerance &&
               b[0] + b[2] <= imageW + tolerance && b[1] + b[3] <= imageH + tolerance
    }
    let kept = snap.elements.filter { inside($0.bbox) }
    s.dropped = snap.elements.count - kept.count
    s.elements = kept
    s.dialogs = snap.dialogs.filter(inside)
    if let f = snap.focused { s.focused = (f.bbox.map(inside) ?? true) ? f : FocusedInfo(role: f.role, title: f.title, bbox: nil) }
    if snap.available && (kept.count + s.dropped) > 5 && Double(s.dropped) > 0.2 * Double(kept.count + s.dropped) {
        s.unreliable = true
    }
    return s
}

private func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
private func axString(_ el: AXUIElement, _ name: String) -> String? {
    guard let s = axAttr(el, name) as? String else { return nil }
    let c = collapseWhitespace(s)
    return c.isEmpty ? nil : c
}
private func axBool(_ el: AXUIElement, _ name: String) -> Bool? {
    (axAttr(el, name) as? NSNumber)?.boolValue
}
private func axRect(_ el: AXUIElement) -> CGRect? {
    guard let posV = axAttr(el, kAXPositionAttribute), let sizeV = axAttr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    if !AXValueGetValue(posV as! AXValue, .cgPoint, &p) { return nil }
    if !AXValueGetValue(sizeV as! AXValue, .cgSize, &s) { return nil }
    return CGRect(x: p.x, y: p.y, width: s.width, height: s.height)
}

func axRoleType(_ role: String, subrole: String?) -> String {
    switch role {
    case "AXButton": return subrole == "AXCloseButton" ? "close_button" : "button"
    case "AXPopUpButton": return "popup_button"
    case "AXMenuButton": return "menu_button"
    case "AXMenuBar": return "menu_bar"
    case "AXMenuBarItem": return "menu_bar_item"
    case "AXMenuItem": return "menu_item"
    case "AXMenu": return "menu"
    case "AXCheckBox": return "checkbox"
    case "AXRadioButton": return "radio_button"
    case "AXTextField": return "text_field"
    case "AXTextArea": return "text_area"
    case "AXStaticText": return "static_text"
    case "AXComboBox": return "combo_box"
    case "AXSlider": return "slider"
    case "AXScrollBar": return "scrollbar"
    case "AXScrollArea": return "scroll_area"
    case "AXTabGroup": return "tab_group"
    case "AXRadioGroup": return "radio_group"
    case "AXToolbar": return "toolbar"
    case "AXTable": return "table"
    case "AXOutline": return "outline"
    case "AXList": return "list"
    case "AXRow": return "row"
    case "AXCell": return "cell"
    case "AXLink": return "link"
    case "AXImage": return "image"
    case "AXWindow": return subrole == "AXDialog" ? "dialog" : "window"
    case "AXSheet": return "dialog"
    case "AXDialog": return "dialog"
    case "AXGroup": return "group"
    case "AXSplitGroup": return "split_group"
    case "AXDisclosureTriangle": return "disclosure"
    case "AXProgressIndicator": return "progress"
    case "AXWebArea": return "web_area"
    default: return role.lowercased().hasPrefix("ax") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }
}

/// Accessibility-first read of an application's UI tree (bounded by node cap + time budget).
func readAX(pid: pid_t, screen: ScreenInfo, budgetMs: Int, nodeCap: Int, restrictPt: CGRect? = nil) -> AXSnapshot {
    var snap = AXSnapshot()
    snap.trusted = AXIsProcessTrusted()
    guard snap.trusted, pid > 0 else { return snap }
    let t0 = Date()
    let app = AXUIElementCreateApplication(pid)
    guard var wins = axAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return snap }
    // For a single-window capture, scope the tree to that window: an app-wide AX tree
    // would legitimately contain elements outside the cropped frame.
    if let rp = restrictPt {
        wins = wins.filter { w in
            guard let r = axRect(w) else { return false }
            return r.insetBy(dx: -12, dy: -12).intersects(rp)
        }
    }

    func toPX(_ r: CGRect) -> [Int] {
        let x = (Double(r.origin.x) - screen.originX) * screen.scale
        let y = (Double(r.origin.y) - screen.originY) * screen.scale
        return [Int(x.rounded()), Int(y.rounded()), Int((Double(r.width) * screen.scale).rounded()),
                Int((Double(r.height) * screen.scale).rounded())]
    }

    for w in wins {
        if let r = axRect(w) { snap.appWindows.append(toPX(r)) }
        let sub = axString(w, kAXSubroleAttribute)
        if sub == "AXDialog" || sub == "AXSystemDialog" { if let r = axRect(w) { snap.dialogs.append(toPX(r)) } }
    }

    var queue: [(AXUIElement, Int)] = wins.map { ($0, 0) }
    var seen = 0
    var ui: [UIElement] = []
    var dialogsFromSheets: [[Int]] = []
    while !queue.isEmpty {
        if seen >= nodeCap { snap.truncated = true; break }
        if Int(Date().timeIntervalSince(t0) * 1000) > budgetMs { snap.truncated = true; break }
        let (el, depth) = queue.removeFirst()
        seen += 1
        let role = (axString(el, kAXRoleAttribute) ?? "")
        let subrole = axString(el, kAXSubroleAttribute)
        if role == "AXSheet" || role == "AXDialog" { if let r = axRect(el) { dialogsFromSheets.append(toPX(r)) } }
        let type = axRoleType(role, subrole: subrole)
        let title = axString(el, kAXTitleAttribute) ?? axString(el, kAXDescriptionAttribute)
        var value: String? = nil
        if subrole != "AXSecureTextField" && type != "close_button" {
            if let v = axString(el, kAXValueAttribute) { value = truncate(v, 120) }
        }
        let interesting = !(title == nil && value == nil) ||
            ["button", "text_field", "text_area", "checkbox", "radio_button", "popup_button", "menu_button",
             "tab_group", "scroll_area", "toolbar", "dialog", "slider", "progress", "link", "menu_item",
             "menu_bar_item", "close_button", "image", "web_area", "disclosure"].contains(type)
        if interesting, let r = axRect(el) {
            var actions: [String]? = nil
            var names: CFArray?
            if AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String], !arr.isEmpty {
                actions = arr.filter { $0 != "AXShowMenu" || type.contains("button") }.prefix(6).map { $0 }
            }
            ui.append(UIElement(id: "u\(ui.count + 1)", role: role, type: type,
                                title: title.map { truncate($0, 80) },
                                value: value, bbox: toPX(r), source: "ax", confidence: 1.0,
                                enabled: axBool(el, kAXEnabledAttribute),
                                actions: (actions?.isEmpty ?? true) ? nil : actions,
                                parent_id: nil))
        }
        if depth < 14, let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { queue.append((k, depth + 1)) }
        }
    }

    snap.available = true
    snap.nodes = seen
    snap.elements = ui
    snap.dialogs.append(contentsOf: dialogsFromSheets)
    if let any = axAttr(app, kAXFocusedUIElementAttribute), CFGetTypeID(any) == AXUIElementGetTypeID() {
        let f = any as! AXUIElement
        snap.focused = FocusedInfo(role: axString(f, kAXRoleAttribute),
                                   title: axString(f, kAXTitleAttribute) ?? axString(f, kAXDescriptionAttribute),
                                   bbox: axRect(f).map(toPX))
    }
    snap.ms = Int(Date().timeIntervalSince(t0) * 1000)
    return snap
}

func frontmostPid() -> pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
func frontmostAppName() -> String? { NSWorkspace.shared.frontmostApplication?.localizedName }
func pidForApp(named name: String) -> pid_t? {
    NSWorkspace.shared.runningApplications.first { ($0.localizedName ?? "") == name || ($0.bundleIdentifier ?? "") == name }?.processIdentifier
}
