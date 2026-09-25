import Foundation
import Vision
import CoreGraphics

struct OCRItem: Codable {
    var text: String
    var bbox: [Int]          // pixels, origin top-left
    var confidence: Double
}

/// Apple Vision text recognition. The engine instance keeps the Vision model resident
/// inside a long-lived process (daemon), which removes the ~12s first-call model load.
final class OCREngine {
    private var warmed = false

    /// Load the recognizer by running it once on a tiny synthetic image.
    @discardableResult
    func warm() -> Bool {
        guard !warmed else { return true }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 96, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 32))
        guard let cg = ctx.makeImage() else { return false }
        _ = recognize(cg, fast: false)
        warmed = true
        return true
    }

    func recognize(_ cg: CGImage, fast: Bool = false, languageCorrection: Bool = true) -> [OCRItem] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = languageCorrection
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let W = Double(cg.width), H = Double(cg.height)
        var out: [OCRItem] = []
        for obs in (req.results ?? []) {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = collapseWhitespace(cand.string)
            if text.isEmpty { continue }
            let bb = obs.boundingBox  // normalized, origin bottom-left
            let x = bb.minX * W
            let y = (1 - bb.maxY) * H
            let w = bb.width * W
            let h = bb.height * H
            out.append(OCRItem(text: text,
                               bbox: [Int(x.rounded()), Int(y.rounded()), Int(w.rounded()), Int(h.rounded())],
                               confidence: Double(cand.confidence)))
        }
        out.sort { ($0.bbox[1], $0.bbox[0]) < ($1.bbox[1], $1.bbox[0]) }
        return out
    }
}
