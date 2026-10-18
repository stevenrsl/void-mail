#!/usr/bin/env swift
// Generates Void Mail's app icon (all macOS sizes) into Assets.xcassets/AppIcon.appiconset.
// An envelope on Void's night background, its flap sealed by Void's eclipse — a letter at first
// glance, of the Void family.
// Usage: swift scripts/make-icon.swift [output folder] [--preview file.png]
//        swift scripts/make-icon.swift --ios   (one full square for the iPhone app: iOS rounds it)
import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())
let previewPath = args.firstIndex(of: "--preview").map { args[$0 + 1] }
let ios = args.contains("--ios")
let output = URL(fileURLWithPath: args.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "VoidMail/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = ios ? 0 : s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = ios ? 0 : body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.45))
    ctx.addPath(path); ctx.setFillColor(color(0x0B0B0E)); ctx.fillPath()
    ctx.restoreGState()

    // Background: deep night gradient, faint violet glow in the middle.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0x1B1A26), color(0x07070A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let center = CGPoint(x: s / 2, y: s / 2)
    let glow = CGGradient(colorsSpace: space, colors: [color(0x7B6CFF, 0.32), color(0x7B6CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: body.width * 0.5, options: [])

    // The envelope: slightly lighter than the night, a little below the middle.
    let envW = body.width * 0.70, envH = body.height * 0.50
    let env = CGRect(x: center.x - envW / 2, y: center.y - envH / 2 - body.height * 0.03, width: envW, height: envH)
    let envRadius = envW * 0.09
    let envPath = CGPath(roundedRect: env, cornerWidth: envRadius, cornerHeight: envRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035, color: color(0x000000, 0.55))
    ctx.addPath(envPath); ctx.setFillColor(color(0x17161F)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(envPath); ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0x23222F), color(0x14131B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: env.midX, y: env.maxY), end: CGPoint(x: env.midX, y: env.minY), options: [])
    // The flap: two lines from the top corners to a point a little below the middle.
    let tip = CGPoint(x: env.midX, y: env.midY - envH * 0.08)
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.move(to: CGPoint(x: env.minX + envRadius * 0.4, y: env.maxY - envRadius * 0.4))
    ctx.addLine(to: tip)
    ctx.addLine(to: CGPoint(x: env.maxX - envRadius * 0.4, y: env.maxY - envRadius * 0.4))
    ctx.strokePath()
    ctx.restoreGState()

    // Hairline on the envelope's edge.
    ctx.addPath(envPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    // Void's eclipse seals the flap.
    let r = envW * 0.12
    let eclipseCenter = tip
    ctx.saveGState()
    let halo = CGGradient(colorsSpace: space, colors: [color(0x9D8FFF, 0.40), color(0x9D8FFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: eclipseCenter, startRadius: r * 0.8, endCenter: eclipseCenter, endRadius: r * 1.8, options: [])
    ctx.addEllipse(in: CGRect(x: eclipseCenter.x - r, y: eclipseCenter.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    let corona = CGGradient(colorsSpace: space, colors: [color(0xF6F3FF), color(0xA597FF), color(0x4B3FD0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(corona, start: CGPoint(x: eclipseCenter.x - r, y: eclipseCenter.y - r),
                           end: CGPoint(x: eclipseCenter.x + r, y: eclipseCenter.y + r), options: [])
    ctx.restoreGState()
    let vr = r * 0.86
    let offset = r * 0.12
    ctx.addEllipse(in: CGRect(x: eclipseCenter.x - vr + offset, y: eclipseCenter.y - vr + offset, width: 2 * vr, height: 2 * vr))
    ctx.setFillColor(color(0x121118))
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline highlight on the icon's edge.
    if !ios {
        ctx.addPath(path)
        ctx.setStrokeColor(color(0xFFFFFF, 0.08))
        ctx.setLineWidth(max(1, s * 0.004))
        ctx.strokePath()
    }

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

if let previewPath {
    // Preview: the icon at 512, 128, 64, 32 and 16 px side by side.
    let sizes = [512, 128, 64, 32, 16]
    let width = sizes.reduce(0, +) + 20 * (sizes.count + 1)
    let sheet = NSImage(size: NSSize(width: width, height: 552))
    sheet.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 552).fill()
    var x = 20
    for size in sizes {
        NSImage(data: render(size * 2))!.draw(in: NSRect(x: x, y: 20, width: size, height: size))
        x += size + 20
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewPath))
    print("Preview written to \(previewPath)")
    exit(0)
}

if ios {
    let folder = URL(fileURLWithPath: "VoidMailiOS/Assets.xcassets/AppIcon.appiconset")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! render(1024).write(to: folder.appendingPathComponent("icon.png"))
    let contents: [String: Any] = ["images": [["filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], "info": ["author": "xcode", "version": 1]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
    print("iOS icon written to \(folder.path)")
    exit(0)
}

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: output.appendingPathComponent("Contents.json"))
print("Icon written to \(output.path)")
