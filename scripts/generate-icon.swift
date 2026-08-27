#!/usr/bin/env swift
// Generates Assets/AppIcon.icns — a reproducible, programmatic app icon.
//
// Design: macOS squircle with a deep indigo gradient, a white audio
// waveform, and a red record dot — "this app records audio" at a glance.
//
// Usage: swift scripts/generate-icon.swift

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("Assets")
let iconsetDir = assetsDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// Waveform bar heights as fractions of max amplitude (symmetric envelope).
let waveform: [CGFloat] = [
    0.18, 0.32, 0.24, 0.52, 0.38, 0.72, 0.55, 0.95,
    0.65, 0.85, 0.45, 0.60, 0.30, 0.42, 0.22, 0.15,
]

func draw(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // macOS icon grid: squircle occupies ~82.5% of the canvas.
    let inset = s * 0.0875
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Soft drop shadow behind the squircle.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.008),
        blur: s * 0.03,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.28, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Gradient fill: deep indigo -> violet.
    squircle.addClip()
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.26, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.48, alpha: 1),
            NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.63, alpha: 1),
        ]
    )!
    gradient.draw(in: rect, angle: 90)

    // Subtle top highlight (full height to avoid a visible seam).
    let highlight = NSGradient(
        colors: [
            NSColor.white.withAlphaComponent(0.0),
            NSColor.white.withAlphaComponent(0.02),
            NSColor.white.withAlphaComponent(0.14),
        ],
        atLocations: [0.0, 0.55, 1.0],
        colorSpace: .deviceRGB
    )!
    highlight.draw(in: rect, angle: 90)

    // Waveform bars.
    let barCount = waveform.count
    let waveWidth = rect.width * 0.68
    let barGap = waveWidth / CGFloat(barCount)
    let barWidth = barGap * 0.55
    let maxBarHeight = rect.height * 0.42
    let baselineY = rect.midY - rect.height * 0.06
    let startX = rect.midX - waveWidth / 2 + (barGap - barWidth) / 2

    for (index, amplitude) in waveform.enumerated() {
        let barHeight = max(maxBarHeight * amplitude, barWidth)
        let barRect = CGRect(
            x: startX + CGFloat(index) * barGap,
            y: baselineY - barHeight / 2,
            width: barWidth,
            height: barHeight
        )
        let bar = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor.white.withAlphaComponent(0.92).setFill()
        bar.fill()
    }

    // Record dot: red circle with a soft glow, top-right of the waveform.
    let dotRadius = rect.width * 0.075
    let dotCenter = CGPoint(
        x: rect.midX + waveWidth / 2 - dotRadius * 0.2,
        y: rect.midY + rect.height * 0.26
    )
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: dotRadius * 1.2,
        color: NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 0.8).cgColor
    )
    NSColor(calibratedRed: 1, green: 0.27, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )).fill()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode PNG for \(url.lastPathComponent)")
    }
    try png.write(to: url)
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = draw(size: variant.size)
    try writePNG(image, to: iconsetDir.appendingPathComponent("\(variant.name).png"))
}

// Compile to .icns.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", assetsDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(task.terminationStatus)")
}
try? FileManager.default.removeItem(at: iconsetDir)
print("Wrote \(assetsDir.appendingPathComponent("AppIcon.icns").path)")
