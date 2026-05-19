#!/usr/bin/env swift
import CoreGraphics
import CoreText
import ImageIO
import Foundation

let size = 1024
let s = CGFloat(size)

let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Flip so y=0 is top
ctx.translateBy(x: 0, y: s)
ctx.scaleBy(x: 1, y: -1)

// Background gradient: indigo → deep purple
let bg = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: 0.38, green: 0.22, blue: 0.90, alpha: 1),
             CGColor(red: 0.18, green: 0.08, blue: 0.60, alpha: 1)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bg,
    start: CGPoint(x: s * 0.5, y: 0),
    end:   CGPoint(x: s * 0.5, y: s),
    options: [])

// Draw emoji centered
let emoji = "💬"
let fontSize = s * 0.62
let font = CTFontCreateWithName("Apple Color Emoji" as CFString, fontSize, nil)
let cfAttrs = [kCTFontAttributeName: font] as CFDictionary
let attrStr = CFAttributedStringCreate(nil, emoji as CFString, cfAttrs)!
let line = CTLineCreateWithAttributedString(attrStr)

let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let x = (s - bounds.width)  / 2 - bounds.origin.x
let y = (s - bounds.height) / 2 - bounds.origin.y

ctx.textPosition = CGPoint(x: x, y: y)
CTLineDraw(line, ctx)

// Save
let image = ctx.makeImage()!
let outURL = URL(fileURLWithPath: "Blabber/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("Done → \(outURL.path)")
