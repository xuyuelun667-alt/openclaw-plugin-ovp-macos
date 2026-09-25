import Foundation

// MARK: - Visual State Schema v1
// Field names are snake_case and stable; the JSON encoder sorts keys so output is deterministic.

struct VisualState: Codable {
    var schema_version: Int = 1
    var image: ImageInfo
    var source: SourceInfo
    var regions: [Region]
    var text: [TextItem]
    var ui_elements: [UIElement]
    var objects: [StateObject]
    var state: StateInfo
    var meta: Meta
    var state_hash: String
}

struct ImageInfo: Codable {
    var width: Int
    var height: Int
    var scale: Double          // pixel / point ratio of the captured source
    var format: String         // png | jpeg | …
    var color_space: String?
    var bytes: Int             // encoded bytes of the captured frame
    var sha256: String         // hash of RAW rasterized pixels (deterministic across encoders)
}

struct SourceInfo: Codable {
    var kind: String           // live_screen | window_capture | screenshot_file | image_file
    var path: String?
    var window_id: Int?
    var app: String?           // "unknown" when the source cannot carry app context (files)
    var title: String?
    var bounds_px: [Int]?
    var bounds_pt: [Double]?
    var kind_reason: String?   // why we classified it that way (display-size match, filename hint, text density)
}

struct Region: Codable {
    var id: String
    var kind: String           // window | dialog | generic_region
    var bbox: [Int]
    var source: String         // cgwindow | ax | cv
    var confidence: Double
    var label: String?
    var text_ids: [String]
}

struct TextItem: Codable {
    var id: String
    var text: String
    var bbox: [Int]
    var confidence: Double
    var region_id: String?
    var cls: String?           // alert | error | focus | result | normal
    var noise: Bool?           // icon-glyph / stray-punctuation OCR noise (kept in JSON, omitted from compact text)
}

struct UIElement: Codable {
    var id: String
    var role: String           // AX role verbatim
    var type: String           // normalized type
    var title: String?
    var value: String?
    var bbox: [Int]
    var source: String         // ax
    var confidence: Double
    var enabled: Bool?
    var actions: [String]?
    var parent_id: String?
}

struct StateObject: Codable {
    var id: String
    var kind: String           // image
    var bbox: [Int]
    var label: String?
    var source: String
    var confidence: Double
}

struct StateInfo: Codable {
    var app: String?
    var window_title: String?
    var accessibility: String    // available | unavailable
    var ax_available: Bool
    var ax_truncated: Bool
    var ax_unreliable: Bool      // AX bboxes failed bounds validation (common with Electron)
    var ax_dropped: Int          // AX elements dropped because their bbox was outside the frame
    var ax_nodes: Int
    var windows: [WindowInfo]
    var focused: FocusedInfo?
}

struct WindowInfo: Codable {
    var id: Int
    var app: String
    var title: String?
    var layer: Int
    var z: Int
    var bounds_pt: [Double]
    var bounds_px: [Int]?
    var frontmost: Bool
}

struct FocusedInfo: Codable {
    var role: String?
    var title: String?
    var bbox: [Int]?
}

struct Meta: Codable {
    var level: String          // fast | normal
    var role: String           // visual_input_substitute
    var latency_ms: Int
    var coverage: Double       // share of image area explained by known rects (windows ∪ text)
    var confidence: Double     // length-weighted mean OCR confidence (0 when no text)
    var truncated: Bool        // true when the compact text had to drop content
    var escalation: String?    // nil | "vlm:possible_dialog" | "vlm:icon_heavy"  (measured triggers)
    var hidden: HiddenInfo
    var class_counts: ClassCounts
    var tokens_est: Int        // rough token estimate of the rendered compact text
    var timings: [String: Int]
    var cache: CacheInfo
    var ocr_lines: Int
    var image_sha256: String
}

struct HiddenInfo: Codable {
    var text_lines_shown: Int
    var text_lines_hidden: Int
    var ui_elements_hidden: Int
    var regions_hidden: Int
    var duplicates_dropped: Int
    var noise_dropped: Int
}

struct ClassCounts: Codable {
    var alert: Int
    var error: Int
    var focus: Int
    var foreground: Int
    var result: Int
    var normal: Int
}

struct CacheInfo: Codable {
    var ocr: String            // hit | miss | disabled
    var state: String
}

// MARK: - canonical encoding

func jsonEncoder(pretty: Bool) -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                               : [.sortedKeys, .withoutEscapingSlashes]
    return e
}

func encodeJSON<T: Encodable>(_ v: T, pretty: Bool) -> String {
    guard let d = try? jsonEncoder(pretty: pretty).encode(v),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// Components that define "the same visual state".
func computeStateHash(imageSHA: String, level: String, windows: [WindowInfo],
                      text: [TextItem], ui: [UIElement]) -> String {
    // the salt invalidates cached states whenever classification/render semantics change
    var parts: [String] = ["v2-priority-render", level, imageSHA]
    for w in windows.sorted(by: { $0.id < $1.id }) {
        parts.append("w:\(w.id):\(w.app):\(w.title ?? ""):\(w.bounds_pt.map { Int($0) })")
    }
    for t in text.sorted(by: { $0.id < $1.id }) {
        parts.append("t:\(t.bbox):\(t.text)")
    }
    for u in ui.sorted(by: { $0.id < $1.id }) {
        parts.append("u:\(u.role):\(u.title ?? ""):\(u.value ?? ""):\(u.bbox)")
    }
    return sha256Hex(parts.joined(separator: "\n"))
}
