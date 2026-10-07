#!/usr/bin/env swift
//
// Builds Resources/AppIcon.icns from Resources/AppIcon-source.png.
//
//   swift Scripts/make-icon.swift <output-directory> [--source <png>] [--fill <0…1>]
//
// The artwork is placed on the macOS icon grid rather than used as-is. Apple's
// own icons occupy roughly 82 % of the canvas edge (Mail 82 %, Docker 83 %,
// measured on macOS 27); artwork that fills more than that looks oversized next
// to its neighbours in the Dock, which reads as amateurish even when nobody can
// say why. The source logo fills 88 %, so it is scaled down to match.
//
// `.icns` is deliberately still the format: macOS 27 does not mask legacy icon
// bundles into the unified rounded-rectangle shape — verified by checking that
// Apple's own Mail icon still has fully transparent corners — so a free-form
// illustration renders exactly as drawn.

import AppKit
import Foundation

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data(
        "usage: make-icon.swift <output-dir> [--source <png>] [--fill <0…1>]\n".utf8
    ))
    exit(64)
}
arguments.removeFirst()

let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
var sourceURL = outputDirectory.appendingPathComponent("AppIcon-source.png")

/// Fraction of the canvas edge the artwork's longest side should occupy.
/// 0.82 matches the macOS icon grid for a free-form illustration.
var fillFraction = 0.82

while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--source":
        guard !arguments.isEmpty else { fail("--source braucht einen Pfad") }
        sourceURL = URL(fileURLWithPath: arguments.removeFirst())
    case "--fill":
        guard !arguments.isEmpty, let value = Double(arguments.removeFirst()),
              value > 0, value <= 1 else { fail("--fill braucht einen Wert zwischen 0 und 1") }
        fillFraction = value
    default:
        fail("Unbekanntes Argument: \(flag)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(64)
}

// MARK: - Load source

guard FileManager.default.fileExists(atPath: sourceURL.path) else {
    fail("Quellbild nicht gefunden: \(sourceURL.path)")
}
guard let sourceImage = NSImage(contentsOf: sourceURL),
      let sourceData = sourceImage.tiffRepresentation,
      let sourceRep = NSBitmapImageRep(data: sourceData)
else {
    fail("Quellbild nicht lesbar: \(sourceURL.path)")
}

let sourceWidth = sourceRep.pixelsWide
let sourceHeight = sourceRep.pixelsHigh

// The largest slot in an icns is 1024×1024. Upscaling a smaller raster is
// possible but soft, so the build says so rather than quietly shipping it.
if sourceWidth < 1024 || sourceHeight < 1024 {
    FileHandle.standardError.write(Data("""
    make-icon: Hinweis — Quelle ist \(sourceWidth)×\(sourceHeight) px.
               Für die 1024-px-Variante wird hochskaliert; Konturen werden dabei weich.
               Besser: eine 1024-px- oder Vektor-Fassung unter \(sourceURL.lastPathComponent) ablegen.\n
    """.utf8))
}

/// Opaque bounding box of the artwork, so the grid is applied to what is
/// actually drawn rather than to the transparent canvas around it.
func opaqueBounds(of rep: NSBitmapImageRep) -> CGRect {
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    var minX = width, minY = height, maxX = -1, maxY = -1

    for y in 0..<height {
        for x in 0..<width {
            guard let alpha = rep.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.02 else { continue }
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
    // `colorAt` uses a top-left origin; CoreGraphics draws bottom-up.
    return CGRect(
        x: CGFloat(minX),
        y: CGFloat(height - 1 - maxY),
        width: CGFloat(maxX - minX + 1),
        height: CGFloat(maxY - minY + 1)
    )
}

let content = opaqueBounds(of: sourceRep)
guard let sourceCG = sourceRep.cgImage else { fail("Quellbild ohne Bitmap") }

// MARK: - Rendering

func renderPNG(size: Int) -> Data? {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let canvas = CGFloat(size)
    let target = canvas * CGFloat(fillFraction)
    let scale = min(target / content.width, target / content.height)

    let drawnWidth = CGFloat(sourceWidth) * scale
    let drawnHeight = CGFloat(sourceHeight) * scale
    // Centre the *content*, not the source canvas: the artwork is not
    // necessarily centred within its own transparent margins.
    let originX = (canvas - content.width * scale) / 2 - content.minX * scale
    let originY = (canvas - content.height * scale) / 2 - content.minY * scale

    context.draw(
        sourceCG,
        in: CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight)
    )

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Iconset

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Names and sizes mandated by `iconutil`.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

for variant in variants {
    guard let data = renderPNG(size: variant.pixels) else {
        fail("Konnte \(variant.name) nicht rendern")
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let output = outputDirectory.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fail("iconutil fehlgeschlagen (\(process.terminationStatus))")
}

try? FileManager.default.removeItem(at: iconset)

let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? nil
print("""
    Icon erzeugt: \(output.path)
      Quelle:      \(sourceURL.lastPathComponent) (\(sourceWidth)×\(sourceHeight))
      Inhalt:      \(Int(content.width))×\(Int(content.height)) px
      Kantenfüllung: \(Int(fillFraction * 100)) %
      Größe:       \(bytes.map { "\($0 / 1024) KiB" } ?? "?")
    """)
