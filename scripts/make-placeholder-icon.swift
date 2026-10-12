#!/usr/bin/env swift
// Generates the neutral placeholder app icon (a plain ring on a dark rounded square).
// It is deliberately not a character: the Bipuu mark comes with the original design system.
// usage: swift scripts/make-placeholder-icon.swift Bipuu/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [(pt: Int, scale: Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.08
    let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset),
                            xRadius: s * 0.22, yRadius: s * 0.22)
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    body.fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: s*0.28, y: s*0.28, width: s*0.44, height: s*0.44))
    ring.lineWidth = s * 0.05
    NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
    ring.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! render(px: pt * scale).write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: out).appendingPathComponent("Contents.json"))
