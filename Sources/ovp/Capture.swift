import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ScreenInfo {
    var ptWidth: Double
    var ptHeight: Double
    var scale: Double
    var originX: Double
    var originY: Double
}

func mainScreenInfo() -> ScreenInfo {
    let screen = NSScreen.main ?? NSScreen.screens.first
    let f = screen?.frame ?? CGRect(x: 0, y: 0, width: 1470, height: 956)
    return ScreenInfo(ptWidth: Double(f.width), ptHeight: Double(f.height),
                      scale: Double(screen?.backingScaleFactor ?? 2.0),
                      originX: Double(f.origin.x), originY: Double(f.origin.y))
}

struct Captured {
    var cgImage: CGImage
    var source: SourceInfo
    var image: ImageInfo
    var bitmap: Bitmap          // native-size RGBA (used for hashing)
    var screen: ScreenInfo
}

enum CaptureError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let m): return m }
    }
}

private func imageFormat(_ cg: CGImage, data: Data) -> (String, String?, Double) {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
        return ("unknown", nil, 1.0)
    }
    let type = (CGImageSourceGetType(src) as String?) ?? ""
    let fmt: String
    switch type {
    case "public.png": fmt = "png"
    case "public.jpeg": fmt = "jpeg"
    case "public.heic": fmt = "heic"
    case "com.compuserve.gif": fmt = "gif"
    case "public.tiff": fmt = "tiff"
    default: fmt = type.isEmpty ? "unknown" : type
    }
    var cs: String? = nil
    if let model = props[kCGImagePropertyColorModel] as? String { cs = model }
    if let profile = props[kCGImagePropertyProfileName] as? String, !profile.isEmpty {
        cs = cs.map { "\($0)/\(profile)" } ?? profile
    }
    let dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 0
    return (fmt, cs, dpi)
}

private func buildCaptured(cg: CGImage, data: Data, source: SourceInfo, screen: ScreenInfo) throws -> Captured {
    guard let bmp = makeBitmap(cg) else { throw CaptureError.failed("cannot rasterize image") }
    let (fmt, cs, _) = imageFormat(cg, data: data)
    let pxHash = sha256Hex(Data(bmp.data))
    let info = ImageInfo(width: cg.width, height: cg.height,
                         scale: Double(cg.width) / max(1.0, screen.ptWidth),
                         format: fmt, color_space: cs, bytes: data.count, sha256: pxHash)
    return Captured(cgImage: cg, source: source, image: info, bitmap: bmp, screen: screen)
}

/// Distinguish a screen capture from an ordinary image, using deterministic local signals only.
/// Returns (kind, reason). Order: filename hint -> exact display-pixel match -> (text density checked later in the pipeline).
func classifyFileSource(_ cg: CGImage, path: String) -> (String, String) {
    let name = (path as NSString).lastPathComponent.lowercased()
    let hints = ["screenshot", "screen shot", "截屏", "屏幕快照", "截图", "snipaste", "cleanshot"]
    if hints.contains(where: { name.contains($0) }) { return ("screenshot_file", "filename") }
    for s in NSScreen.screens {
        let pxW = Double(s.frame.width) * Double(s.backingScaleFactor)
        let pxH = Double(s.frame.height) * Double(s.backingScaleFactor)
        if (abs(Double(cg.width) - pxW) < 2 && abs(Double(cg.height) - pxH) < 2) ||
           (abs(Double(cg.width) - pxH) < 2 && abs(Double(cg.height) - pxW) < 2) {
            return ("screenshot_file", "display-size-match")
        }
    }
    return ("image_file", "no-screen-signal")
}

func captureFile(_ path: String) throws -> Captured {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw CaptureError.failed("cannot read file: \(path)")
    }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CaptureError.failed("cannot decode image: \(path)")
    }
    let screen = mainScreenInfo()
    // for plain files the notion of "scale" is DPI-derived; keep the pixel/point convention at 1
    var s = screen
    s.ptWidth = Double(cg.width); s.ptHeight = Double(cg.height); s.scale = 1.0
    let (kind, reason) = classifyFileSource(cg, path: path)
    let src2 = SourceInfo(kind: kind, path: path, window_id: nil,
                          app: "unknown",                       // a file carries no live app context
                          title: (path as NSString).lastPathComponent,
                          bounds_px: [0, 0, cg.width, cg.height], bounds_pt: nil,
                          kind_reason: reason)
    return try buildCaptured(cg: cg, data: data, source: src2, screen: s)
}

private func tempShotPath(_ tag: String) -> String {
    let dir = cacheRoot().appendingPathComponent("tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(tag)-\(UUID().uuidString).png").path
}

func captureScreen() throws -> Captured {
    let out = tempShotPath("screen")
    defer { try? FileManager.default.removeItem(atPath: out) }
    let rc = runProcess("/usr/sbin/screencapture", ["-x", "-o", out])
    guard rc == 0, let data = FileManager.default.contents(atPath: out) else {
        throw CaptureError.failed("screencapture failed rc=\(rc)")
    }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CaptureError.failed("cannot decode screenshot")
    }
    var screen = mainScreenInfo()
    screen.scale = Double(cg.width) / max(1.0, screen.ptWidth)
    let src2 = SourceInfo(kind: "live_screen", path: nil, window_id: nil,
                          app: NSWorkspace.shared.frontmostApplication?.localizedName,
                          title: nil,
                          bounds_px: [0, 0, cg.width, cg.height],
                          bounds_pt: [screen.originX, screen.originY, screen.ptWidth, screen.ptHeight],
                          kind_reason: "live-capture")
    return try buildCaptured(cg: cg, data: data, source: src2, screen: screen)
}

func captureWindow(_ id: Int) throws -> Captured {
    let out = tempShotPath("window")
    defer { try? FileManager.default.removeItem(atPath: out) }
    let rc = runProcess("/usr/sbin/screencapture", ["-x", "-o", "-l\(id)", out])
    guard rc == 0, let data = FileManager.default.contents(atPath: out) else {
        throw CaptureError.failed("screencapture -l\(id) failed rc=\(rc)")
    }
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw CaptureError.failed("cannot decode window screenshot")
    }
    let win = windowList(onScreenOnly: false).first { $0.id == id }
    var screen = mainScreenInfo()
    if let w = win, w.boundsPt.width > 0 {
        screen.scale = Double(cg.width) / Double(w.boundsPt.width)
        screen.ptWidth = Double(w.boundsPt.width)
        screen.ptHeight = Double(w.boundsPt.height)
        screen.originX = Double(w.boundsPt.minX)
        screen.originY = Double(w.boundsPt.minY)
    }
    let src2 = SourceInfo(kind: "window_capture", path: nil, window_id: id,
                          app: win?.app ?? "unknown", title: win?.title,
                          bounds_px: [0, 0, cg.width, cg.height],
                          bounds_pt: win.map { [Double($0.boundsPt.minX), Double($0.boundsPt.minY), Double($0.boundsPt.width), Double($0.boundsPt.height)] },
                          kind_reason: "window-id-capture")
    return try buildCaptured(cg: cg, data: data, source: src2, screen: screen)
}
