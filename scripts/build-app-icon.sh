#!/usr/bin/env bash
# Generates assets/AppIcon.icns from assets/AppIcon-source.png using native macOS
# CoreGraphics/AppKit continuous squircle masking (Apple macOS 824/1024 icon grid)
# and /usr/bin/iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_PNG="${1:-$ROOT/assets/AppIcon-source.png}"
OUT_ICNS="${2:-$ROOT/assets/AppIcon.icns}"
PREVIEW_PNG="${3:-}"

if [ ! -f "$SRC_PNG" ]; then
    echo "ERROR: Source icon image not found at: $SRC_PNG" >&2
    exit 1
fi

WORK_TMP="$(mktemp -d /tmp/sts2-app-icon.XXXXXX)"
cleanup() {
    rm -rf "$WORK_TMP"
}
trap cleanup EXIT

ICONSET_DIR="$WORK_TMP/AppIcon.iconset"
mkdir -p "$ICONSET_DIR" "$(dirname "$OUT_ICNS")"

swift - "$SRC_PNG" "$ICONSET_DIR" "$PREVIEW_PNG" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: swift script <srcImage> <iconsetDir> [previewPng]\n", stderr)
    exit(2)
}

let srcURL = URL(fileURLWithPath: args[1])
let iconsetDir = URL(fileURLWithPath: args[2], isDirectory: true)
let previewPath = args.count >= 4 ? args[3] : ""

guard let srcImageSource = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let srcCGImage = CGImageSourceCreateImageAtIndex(srcImageSource, 0, nil) else {
    fputs("ERROR: Failed to decode source image at \(srcURL.path)\n", stderr)
    exit(1)
}

/// Uses Apple's exact native SwiftUI `.continuous` corner curvature (22.5% radius on 824px body)
/// so straight edges stay crisp and match macOS system icons in Dock & Finder bit-for-bit.
func makeAppleSquirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .path(in: rect)
        .cgPath
}

func renderFramedMaster(size: Int) -> CGImage {
    let s = CGFloat(size)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext")
    }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Apple macOS icon grid: 824x824 icon body centered on 1024x1024 canvas, 185.4px continuous radius
    let bodyRatio: CGFloat = 824.0 / 1024.0
    let bodySize = s * bodyRatio
    let inset = (s - bodySize) * 0.5
    let cornerRadius = bodySize * 0.225
    let bodyRect = CGRect(x: inset, y: inset, width: bodySize, height: bodySize)
    let squircle = makeAppleSquirclePath(in: bodyRect, cornerRadius: cornerRadius)

    // 1. Subtle macOS ambient drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * (12.0 / 1024.0)),
        blur: s * (20.0 / 1024.0),
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.34)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Clipped full-bleed master artwork inside Apple continuous squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.draw(srcCGImage, in: bodyRect)

    // 3. Delicate glass specular inner rim highlight
    let rimWidth = max(1.0, s * (1.8 / 1024.0))
    let rimRect = bodyRect.insetBy(dx: rimWidth * 0.5, dy: rimWidth * 0.5)
    let rimPath = makeAppleSquirclePath(in: rimRect, cornerRadius: cornerRadius - rimWidth * 0.5)
    ctx.addPath(rimPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16))
    ctx.setLineWidth(rimWidth)
    ctx.strokePath()
    ctx.restoreGState()

    guard let result = ctx.makeImage() else {
        fatalError("Failed to make master CGImage")
    }
    return result
}

func downscale(_ master: CGImage, to pixelSize: Int) -> CGImage {
    if master.width == pixelSize && master.height == pixelSize {
        return master
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create downscale CGContext")
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Failed to create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Failed to write PNG at \(url.path)")
    }
}

let master1024 = renderFramedMaster(size: 1024)

if !previewPath.isEmpty {
    writePNG(master1024, to: URL(fileURLWithPath: previewPath))
}

let iconSpecs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (fileName, px) in iconSpecs {
    let resized = downscale(master1024, to: px)
    writePNG(resized, to: iconsetDir.appendingPathComponent(fileName))
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"
echo "Generated macOS icon: $OUT_ICNS ($(du -h "$OUT_ICNS" | awk '{print $1}'))"
