#!/usr/bin/env swift
import AppKit
import CoreGraphics

let sz: CGFloat = 1024

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(sz), height: Int(sz),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Failed to create context"); exit(1)
}

// ── Background ──────────────────────────────────────────────────────────
// Deep navy rounded rect
ctx.setFillColor(CGColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 1.0))
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: sz, height: sz),
                  cornerWidth: 200, cornerHeight: 200, transform: nil))
ctx.fillPath()

// Subtle inner highlight at top
ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.04))
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: sz * 0.5, width: sz, height: sz * 0.5),
                  cornerWidth: 200, cornerHeight: 200, transform: nil))
ctx.fillPath()

// ── Microphone body (white capsule) ─────────────────────────────────────
// Centered at x=512; y runs bottom-up in CG
let micCX: CGFloat = 512
let micBodyW: CGFloat = 240
let micBodyH: CGFloat = 360
let micBodyBottom: CGFloat = 480
let micBodyTop: CGFloat = micBodyBottom + micBodyH  // = 840
let micBodyLeft = micCX - micBodyW / 2              // = 392

ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.addPath(CGPath(roundedRect: CGRect(x: micBodyLeft, y: micBodyBottom,
                                      width: micBodyW, height: micBodyH),
                  cornerWidth: micBodyW / 2, cornerHeight: micBodyW / 2, transform: nil))
ctx.fillPath()

// Horizontal lines inside mic body — suggest transcription text
ctx.setFillColor(CGColor(red: 0.10, green: 0.13, blue: 0.22, alpha: 0.18))
let lineX = micBodyLeft + 44
let lineW = micBodyW - 88
for i in 0..<4 {
    let lineY = micBodyBottom + 90 + CGFloat(i) * 56
    ctx.fill(CGRect(x: lineX, y: lineY, width: lineW, height: 18))
}

// ── Stand arm (U-shape arc below mic body) ───────────────────────────────
// Arc center at base of mic body; arcs downward then back up
let arcCY = micBodyBottom                            // = 480
let arcR: CGFloat = 190
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.setLineWidth(50)
ctx.setLineCap(.round)
// clockwise from π (left) to 0 (right) draws the bottom arc
ctx.addArc(center: CGPoint(x: micCX, y: arcCY),
           radius: arcR, startAngle: .pi, endAngle: 0, clockwise: true)
ctx.strokePath()

// ── Stand vertical line ──────────────────────────────────────────────────
let arcBottom = arcCY - arcR                        // = 290
let baseY: CGFloat = 220
ctx.setLineWidth(50)
ctx.move(to: CGPoint(x: micCX, y: arcBottom))
ctx.addLine(to: CGPoint(x: micCX, y: baseY))
ctx.strokePath()

// ── Stand base (horizontal) ──────────────────────────────────────────────
ctx.setLineWidth(50)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: micCX - 160, y: baseY))
ctx.addLine(to: CGPoint(x: micCX + 160, y: baseY))
ctx.strokePath()

// ── Recording indicator dot (red) ───────────────────────────────────────
let dotR: CGFloat = 58
let dotX = micBodyLeft + micBodyW - 12              // right edge of mic body
let dotY = micBodyTop - 12                          // top edge of mic body
ctx.setFillColor(CGColor(red: 0.95, green: 0.25, blue: 0.28, alpha: 1.0))
ctx.addEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
ctx.fillPath()

// Red dot white inner ring
ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
ctx.setLineWidth(8)
ctx.addEllipse(in: CGRect(x: dotX - dotR + 14, y: dotY - dotR + 14,
                          width: (dotR - 14) * 2, height: (dotR - 14) * 2))
ctx.strokePath()

// ── Save PNG ─────────────────────────────────────────────────────────────
guard let cgImage = ctx.makeImage() else { print("makeImage failed"); exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else {
    print("PNG encoding failed"); exit(1)
}
let outPath = "AppIcon_1024.png"
try! data.write(to: URL(fileURLWithPath: outPath))
print("Saved: \(outPath)")
