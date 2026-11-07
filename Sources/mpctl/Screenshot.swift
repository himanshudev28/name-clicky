import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO

/// Active displays with the main display first (matches `screencapture -D 1`).
private func orderedDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let main = CGMainDisplayID()
    return [main] + ids.filter { $0 != main }
}

private func resample(_ image: CGImage, to size: CGSize) -> CGImage? {
    let w = max(Int(size.width.rounded()), 1)
    let h = max(Int(size.height.rounded()), 1)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// MacPilot writes "allow" or "deny" here before each request (Settings › Claude › screen access).
private func screenshotAllowed() -> Bool {
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacPilot/screen-access")
    guard let s = try? String(contentsOf: file, encoding: .utf8) else { return true } // not run by MacPilot
    return s.trimmingCharacters(in: .whitespacesAndNewlines) == "allow"
}

func cmdScreenshot(_ rawArgs: [String]) {
    guard screenshotAllowed() else {
        fail("screenshot not allowed for this request (the user didn't ask about the screen). " +
             "Use the accessibility tree instead: mpctl ui <app>, mpctl find <app> <text>, or read state with AppleScript/shell.")
    }
    var args = rawArgs
    let displayN = takeInt("--display", &args, default: 1)
    let appName = takeOption("--app", &args)
    let outOpt = takeOption("--out", &args)
    guard args.isEmpty else { usage("screenshot [--display N] [--app <app>] [--out path]") }

    let displays = orderedDisplays()
    guard displayN >= 1, displayN <= displays.count else { fail("error: --display must be 1..\(displays.count)") }
    let bounds = CGDisplayBounds(displays[displayN - 1])

    // Window frame to crop to (global points), resolved before capturing.
    var cropFrame: CGRect?
    if let name = appName {
        let ctx = windowContext(name)
        guard let f = axFrame(ctx.windows[ctx.defaultIndex]) else { fail("error: cannot read window frame of \(name)") }
        cropFrame = f.intersection(bounds)
        if cropFrame!.isNull || cropFrame!.isEmpty { fail("error: \(name)'s window is not on display \(displayN)") }
    }

    if !CGPreflightScreenCaptureAccess() {
        FileHandle.standardError.write(Data("warning: Screen Recording permission missing; capture may show only the desktop\n".utf8))
    }

    let fm = FileManager.default
    let rawPath = NSTemporaryDirectory() + "macpilot-raw-\(UUID().uuidString).png"
    defer { try? fm.removeItem(atPath: rawPath) }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-t", "png", "-D", String(displayN), rawPath]
    do { try task.run() } catch { fail("error: cannot run screencapture: \(error.localizedDescription)") }
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: rawPath) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("error: screencapture failed (is Screen Recording permission granted?)")
    }

    let scale = CGFloat(full.width) / bounds.width
    var image = full
    var outSize = bounds.size
    var offset = bounds.origin
    if let crop = cropFrame {
        let px = CGRect(x: (crop.minX - bounds.minX) * scale, y: (crop.minY - bounds.minY) * scale,
                        width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = full.cropping(to: px) else { fail("error: crop failed") }
        image = cropped
        outSize = crop.size
        offset = crop.origin
    }
    guard let scaled = resample(image, to: outSize) else { fail("error: image scaling failed") }

    let path: String
    if let o = outOpt {
        path = (o as NSString).expandingTildeInPath
    } else {
        path = NSTemporaryDirectory() + "macpilot-shot-\(Int(Date().timeIntervalSince1970)).jpg"
    }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil) else {
        fail("error: cannot write \(path)")
    }
    CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("error: JPEG encode failed") }

    print(path)
    if offset != .zero {
        print("size: \(scaled.width)x\(scaled.height) offset: \(Int(offset.x)),\(Int(offset.y)) (add offset to image coords to get click coords)")
    }
}
