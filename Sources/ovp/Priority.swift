import Foundation

/// Text classification used by the cost-aware renderer.
/// Ordered by priority: alert > error > focus > result > normal.
enum TextClass: String, Codable {
    case alert
    case error
    case focus
    case foreground
    case result
    case normal

    var rank: Int {
        switch self {
        case .alert: return 0
        case .error: return 1
        case .focus: return 3      // focused element / its label
        case .foreground: return 4 // text inside the frontmost window
        case .result: return 5
        case .normal: return 6
        }
    }
    var tag: String {
        switch self {
        case .alert: return "!"
        case .error: return "E"
        case .focus: return "*"
        case .foreground: return "F"
        case .result: return "="
        case .normal: return " "
        }
    }
}

enum Priority {
    static let errorWords = ["错误", "失败", "异常", "无法", "警告", "错误码", "不成功", "超时", "拒绝",
                             "error", "failed", "failure", "exception", "denied", "timeout", "crash",
                             "panic", "fatal", "unable", "invalid", "not found"]
    static let resultWords = ["结果", "输出", "总计", "合计", "完成", "成功", "余额", "金额", "得分", "通过",
                              "result", "output", "total", "done", "success", "summary", "passed"]

    static let dialogWords = ["确定", "取消", "好", "关闭", "是否", "继续", "警告", "提示", "确认",
                              "ok", "cancel", "continue", "quit", "close", "alert", "allow", "deny"]
    // substrings that strongly imply a modal surface (used with substring matching)
    static let dialogHints = ["dialog", "警告", "错误", "弹窗", "模态", "modal"]

    static func classify(text: String, bbox: [Int], dialogRects: [[Int]], foregroundRect: [Int]? = nil,
                         allowButtonWords: Bool = false,
                         focusedBBox: [Int]?, focusedTitle: String?, focusedValue: String?) -> TextClass {
        for d in dialogRects where contains(d, bbox) { return .alert }
        let lower = text.lowercased()
        if errorWords.contains(where: { lower.contains($0) }) { return .error }
        // weak evidence: a bare dialog button label - trusted only when a dialog/error already exists
        if allowButtonWords, dialogWords.contains(where: { lower == $0 }) { return .alert }
        if dialogHints.contains(where: { lower.contains($0) }) { return .alert }
        if let fb = focusedBBox, contains(fb, bbox) { return .focus }
        if let ft = focusedTitle, !ft.isEmpty, text == ft || text.contains(ft) { return .focus }
        if let fv = focusedValue, !fv.isEmpty, fv.count >= 2, text.contains(fv) { return .focus }
        if let fr = foregroundRect, contains(fr, bbox) { return .foreground }
        if resultWords.contains(where: { lower.contains($0) }) { return .result }
        return .normal
    }

    /// Pure-symbol / single-glyph OCR noise (icon glyphs, stray punctuation).
    static func isNoise(_ text: String, confidence: Double) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count == 1 && confidence < 0.9 { return true }
        if t.count <= 3 {
            let letters = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            if letters == 0 && confidence < 0.95 { return true }
        }
        return false
    }

    /// Duplicate detection: same normalized text close by (OCR often emits the same run twice).
    static func isDuplicate(_ text: String, bbox: [Int], seen: [String: [Int]]) -> Bool {
        let key = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let prev = seen[key] else { return false }
        let dy = abs(prev[1] - bbox[1])
        let dx = abs(prev[0] - bbox[0])
        return dy <= 24 && dx <= 400
    }
}

/// Rough token estimate: CJK ≈ 1 token/char, other ≈ 1 token / 4 chars.
func estimateTokens(_ s: String) -> Int {
    var cjk = 0, other = 0
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            cjk += 1
        default:
            other += 1
        }
    }
    return cjk + (other + 3) / 4
}
