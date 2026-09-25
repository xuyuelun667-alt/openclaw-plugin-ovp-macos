import Foundation

/// Two-level file cache.
///  - OCR layer keyed by the raw-pixel hash: the expensive part (Vision) is reused
///    even when windows/AX changed underneath an identical frame.
///  - State layer keyed by state_hash: exact repeat calls return instantly.
final class StateCache {
    let root: URL
    let ocrDir: URL
    let stateDir: URL

    init() {
        root = cacheRoot()
        ocrDir = root.appendingPathComponent("ocr", isDirectory: true)
        stateDir = root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: ocrDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    private func file(_ dir: URL, _ key: String) -> URL {
        dir.appendingPathComponent("\(key).json")
    }

    func getOCR(_ pixHash: String) -> [OCRItem]? {
        let f = file(ocrDir, pixHash)
        guard let d = FileManager.default.contents(atPath: f.path) else { return nil }
        return try? JSONDecoder().decode([OCRItem].self, from: d)
    }

    func putOCR(_ pixHash: String, _ items: [OCRItem]) {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: file(ocrDir, pixHash))
        prune(ocrDir, keep: 400)
    }

    func getState(_ hash: String) -> VisualState? {
        let f = file(stateDir, hash)
        guard let d = FileManager.default.contents(atPath: f.path) else { return nil }
        return try? JSONDecoder().decode(VisualState.self, from: d)
    }

    func putState(_ hash: String, _ s: VisualState) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: file(stateDir, hash))
        prune(stateDir, keep: 400)
    }

    func clear() {
        for d in [ocrDir, stateDir] {
            if let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
                for f in files { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    func stats() -> (ocr: Int, state: Int, bytes: Int) {
        var bytes = 0
        func count(_ dir: URL) -> Int {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            for f in files {
                if let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { bytes += sz }
            }
            return files.count
        }
        let o = count(ocrDir), s = count(stateDir)
        return (o, s, bytes)
    }

    private func prune(_ dir: URL, keep: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        if files.count <= keep { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }
}
