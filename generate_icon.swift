#!/usr/bin/env swift
import CoreGraphics
import ImageIO
import Foundation

let size = 1024
let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let s = CGFloat(size)
// Flip so y=0 is top
ctx.translateBy(x: 0, y: s)
ctx.scaleBy(x: 1, y: -1)

// ── Background gradient: deep navy → slightly lighter navy ───────────────────
func makeGradient(_ pairs: [(CGFloat,CGFloat,CGFloat,CGFloat)], locations: [CGFloat]) -> CGGradient {
    let colors = pairs.map { CGColor(red:$0.0, green:$0.1, blue:$0.2, alpha:$0.3) } as CFArray
    return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: colors, locations: locations)!
}

let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red:0.04,green:0.04,blue:0.16,alpha:1),
                             CGColor(red:0.07,green:0.09,blue:0.24,alpha:1)] as CFArray,
                    locations: [0,1])!
ctx.drawLinearGradient(bg,
    start: CGPoint(x:s*0.5,y:0), end: CGPoint(x:s*0.5,y:s), options:[])

// ── Radial glow (subtle blue bloom) ──────────────────────────────────────────
let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [CGColor(red:0.2,green:0.4,blue:1.0,alpha:0.30),
                                CGColor(red:0.2,green:0.4,blue:1.0,alpha:0.0)] as CFArray,
                       locations: [0,1])!
ctx.drawRadialGradient(bloom,
    startCenter: CGPoint(x:s*0.5,y:s*0.46), startRadius: 0,
    endCenter:   CGPoint(x:s*0.5,y:s*0.46), endRadius: s*0.55, options:[])

// ── Speech bubble ─────────────────────────────────────────────────────────────
let bW = s*0.70, bH = s*0.52
let bX = (s-bW)/2,  bY = s*0.15
let bR = s*0.105

func bubbleBodyPath() -> CGPath {
    CGPath(roundedRect: CGRect(x:bX,y:bY,width:bW,height:bH),
           cornerWidth: bR, cornerHeight: bR, transform: nil)
}

// 1. Shadow pass
ctx.saveGState()
ctx.setShadow(offset: CGSize(width:0, height:s*0.018), blur:s*0.07,
              color: CGColor(red:0.1,green:0.25,blue:1.0,alpha:0.55))
ctx.setFillColor(CGColor(red:0.1,green:0.14,blue:0.38,alpha:1))
ctx.addPath(bubbleBodyPath()); ctx.fillPath()
ctx.restoreGState()

// 2. Fill bubble with gradient
ctx.saveGState()
ctx.addPath(bubbleBodyPath()); ctx.clip()
let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red:0.14,green:0.20,blue:0.50,alpha:1),
                               CGColor(red:0.08,green:0.11,blue:0.32,alpha:1)] as CFArray,
                      locations: [0,1])!
ctx.drawLinearGradient(fill,
    start: CGPoint(x:bX,y:bY), end: CGPoint(x:bX,y:bY+bH), options:[])
ctx.restoreGState()

// 3. Glass sheen on top edge
ctx.saveGState()
let sheenRect = CGRect(x:bX+s*0.05, y:bY+s*0.022, width:bW*0.65, height:bH*0.16)
ctx.addPath(CGPath(roundedRect:sheenRect,cornerWidth:s*0.025,cornerHeight:s*0.025,transform:nil))
ctx.clip()
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [CGColor(red:1,green:1,blue:1,alpha:0.22),
                                CGColor(red:1,green:1,blue:1,alpha:0.0)] as CFArray,
                       locations: [0,1])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x:sheenRect.midX, y:sheenRect.minY),
    end:   CGPoint(x:sheenRect.midX, y:sheenRect.maxY), options:[])
ctx.restoreGState()

// 4. Bubble border
ctx.saveGState()
ctx.addPath(bubbleBodyPath())
ctx.setStrokeColor(CGColor(red:0.45,green:0.60,blue:1.0,alpha:0.40))
ctx.setLineWidth(s*0.009)
ctx.strokePath()
ctx.restoreGState()

// 5. Tail (bottom-left, below the bubble)
let tailTipX = s*0.285, tailTipY = s*0.785
let tailBaseY = bY+bH - bR*0.35
let tail = CGMutablePath()
tail.move(to: CGPoint(x:bX+bR*0.5, y:tailBaseY))
tail.addCurve(to: CGPoint(x:tailTipX, y:tailTipY),
              control1: CGPoint(x:bX+s*0.02, y:tailBaseY+s*0.04),
              control2: CGPoint(x:tailTipX+s*0.02, y:tailTipY-s*0.03))
tail.addCurve(to: CGPoint(x:bX+bR*1.5, y:tailBaseY),
              control1: CGPoint(x:tailTipX+s*0.055, y:tailTipY-s*0.01),
              control2: CGPoint(x:bX+bR*1.1, y:tailBaseY+s*0.04))
tail.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width:0,height:s*0.01), blur:s*0.04,
              color: CGColor(red:0.1,green:0.25,blue:1.0,alpha:0.45))
ctx.setFillColor(CGColor(red:0.10,green:0.14,blue:0.36,alpha:1))
ctx.addPath(tail); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tail); ctx.clip()
ctx.drawLinearGradient(fill,
    start: CGPoint(x:0,y:tailBaseY), end: CGPoint(x:0,y:tailTipY), options:[])
ctx.restoreGState()

// ── Waveform bars (drawn AFTER bubble, no global clip) ────────────────────────
let barCount = 9
let heights: [CGFloat] = [0.20, 0.38, 0.56, 0.74, 0.92, 0.74, 0.56, 0.38, 0.20]
let totalW  = bW * 0.68
let barW    = totalW / CGFloat(barCount) * 0.46
let spacing = totalW / CGFloat(barCount)
let startX  = bX + (bW - totalW)/2 + spacing*0.27
let centerY = bY + bH * 0.50
let maxH    = bH * 0.52

for i in 0..<barCount {
    let bx   = startX + CGFloat(i)*spacing
    let bh   = maxH * heights[i]
    let by   = centerY - bh/2
    let barR = barW*0.5
    let barRect = CGRect(x:bx, y:by, width:barW, height:bh)
    let barPath = CGPath(roundedRect:barRect, cornerWidth:barR, cornerHeight:barR, transform:nil)

    // Outer glow
    ctx.saveGState()
    ctx.setShadow(offset:.zero, blur:s*0.025,
                  color: CGColor(red:0.35,green:0.70,blue:1.0,alpha:1.0))
    ctx.setFillColor(CGColor(red:0.50,green:0.80,blue:1.0,alpha:1.0))
    ctx.addPath(barPath); ctx.fillPath()
    ctx.restoreGState()

    // Bar gradient fill
    ctx.saveGState()
    ctx.addPath(barPath); ctx.clip()
    let barGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red:0.65,green:0.90,blue:1.00,alpha:1),
                                      CGColor(red:0.30,green:0.55,blue:0.98,alpha:1)] as CFArray,
                             locations: [0,1])!
    ctx.drawLinearGradient(barGrad,
        start: CGPoint(x:bx,y:by), end: CGPoint(x:bx,y:by+bh), options:[])
    ctx.restoreGState()
}

// ── Three typing dots (bottom-right inside bubble) ────────────────────────────
let dotY   = bY + bH*0.80
let dotR   = s*0.019
let dotBaseX = bX + bW*0.66
let dotGap = s*0.052
let dotAlphas: [CGFloat] = [0.45, 1.0, 0.45]
for i in 0..<3 {
    let dx = dotBaseX + CGFloat(i)*dotGap
    ctx.saveGState()
    ctx.setShadow(offset:.zero, blur:s*0.014,
                  color: CGColor(red:0.4,green:0.7,blue:1.0,alpha:0.9))
    ctx.setFillColor(CGColor(red:0.55,green:0.80,blue:1.0,alpha:dotAlphas[i]))
    ctx.fillEllipse(in: CGRect(x:dx-dotR, y:dotY-dotR, width:dotR*2, height:dotR*2))
    ctx.restoreGState()
}

// ── Save ──────────────────────────────────────────────────────────────────────
let image = ctx.makeImage()!
let outURL = URL(fileURLWithPath: "Blabber/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
let dest   = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Done → \(outURL.path)")
