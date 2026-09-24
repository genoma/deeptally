// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeepTally visual identity generator — AppKit + CoreGraphics only, zero dependencies.
//
// Usage:  swift Scripts/make-icon.swift
//
// Writes (deterministic: no randomness, no timers, no network, no date-dependent output):
//   dist/icon/AppIcon.iconset/                      the 10 canonical iconset PNGs (dist/ is git-ignored)
//   Resources/AppIcon.icns                          via /usr/bin/iconutil (committed: actool needs Xcode)
//   Resources/MenuBarIconTemplate.png, ...@2x.png   black + alpha status-item glyphs
//   docs/assets/hero.png                            1200x400 README hero
//
// The script verifies its own output (sizes, template purity, non-blank hero) and exits non-zero on any
// mismatch. Design rationale and exact hex values: docs/ICON.md — keep the palette in sync.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

/// sRGB hex values shared by the icon, the menu bar glyph and the hero. Documented in docs/ICON.md.
private enum Palette {
  // App icon body: indigo at the top, through navy, into teal at the base.
  static let indigo: UInt32 = 0x252B72
  static let navy: UInt32 = 0x131B4C
  static let deep: UInt32 = 0x0C3F58
  static let teal: UInt32 = 0x0B7A6E
  static let shade: UInt32 = 0x03060E

  // Dial.
  static let track: UInt32 = 0xA7E8DE
  static let arcLight: UInt32 = 0x6FF0DC
  static let arcDeep: UInt32 = 0x2BB8A8
  static let amberDeep: UInt32 = 0xE08A2B
  static let amber: UInt32 = 0xFFB454
  static let amberLight: UInt32 = 0xFFD79A
  static let hub: UInt32 = 0xFFF3DC

  // Hero.
  static let heroBackground: UInt32 = 0x070B18
  static let ink: UInt32 = 0xEAF2FF
  static let wordTeal: UInt32 = 0x4DE3CE
  static let steel: UInt32 = 0x8FA6CC
}

// MARK: - Locations

private let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
private let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let iconsetDirectory = repoRoot.appendingPathComponent("dist/icon/AppIcon.iconset")
private let icnsURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
private let menuBarGlyphURL = repoRoot.appendingPathComponent("Resources/MenuBarIconTemplate.png")
private let menuBarGlyph2xURL = repoRoot.appendingPathComponent(
  "Resources/MenuBarIconTemplate@2x.png")
private let heroURL = repoRoot.appendingPathComponent("docs/assets/hero.png")

// MARK: - Failures

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("make-icon: error: " + message + "\n").utf8))
  exit(1)
}

// MARK: - Colors and paths

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha)
}

/// Superellipse squircle: |x/a|^n + |y/b|^n = 1. n = 5 approximates Apple's continuous-curvature icon
/// shape closely enough that it does not read as a plain rounded rectangle.
private func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
  let path = CGMutablePath()
  let steps = 720
  let power = 2 / exponent
  for step in 0...steps {
    let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
    let cosine = cos(angle)
    let sine = sin(angle)
    let point = CGPoint(
      x: rect.midX + rect.width / 2 * (cosine < 0 ? -1 : 1) * pow(abs(cosine), power),
      y: rect.midY + rect.height / 2 * (sine < 0 ? -1 : 1) * pow(abs(sine), power))
    if step == 0 {
      path.move(to: point)
    } else {
      path.addLine(to: point)
    }
  }
  path.closeSubpath()
  return path
}

// MARK: - Gradients and fills

private struct Stop {
  let hex: UInt32
  let alpha: CGFloat
  let location: CGFloat

  init(_ hex: UInt32, alpha: CGFloat = 1, at location: CGFloat) {
    self.hex = hex
    self.alpha = alpha
    self.location = location
  }
}

private func gradient(_ stops: [Stop]) -> CGGradient {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let gradient = CGGradient(
      colorsSpace: space,
      colors: stops.map { color($0.hex, alpha: $0.alpha).cgColor } as CFArray,
      locations: stops.map { $0.location })
  else {
    fail("could not build a gradient")
  }
  return gradient
}

private func fill(_ path: CGPath, color fillColor: NSColor, in cg: CGContext) {
  cg.saveGState()
  cg.addPath(path)
  cg.setFillColor(fillColor.cgColor)
  cg.fillPath()
  cg.restoreGState()
}

private func fill(
  _ path: CGPath, linear gradient: CGGradient, from: CGPoint, to: CGPoint, in cg: CGContext
) {
  cg.saveGState()
  cg.addPath(path)
  cg.clip()
  cg.drawLinearGradient(
    gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  cg.restoreGState()
}

private func fill(
  _ path: CGPath, radial gradient: CGGradient, center: CGPoint, radius: CGFloat, in cg: CGContext
) {
  cg.saveGState()
  cg.addPath(path)
  cg.clip()
  cg.drawRadialGradient(
    gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  cg.restoreGState()
}

private func stroke(
  _ path: CGPath, color strokeColor: NSColor, width: CGFloat, cap: CGLineCap, in cg: CGContext
) {
  cg.saveGState()
  cg.addPath(path)
  cg.setStrokeColor(strokeColor.cgColor)
  cg.setLineWidth(width)
  cg.setLineCap(cap)
  cg.setLineJoin(.round)
  cg.strokePath()
  cg.restoreGState()
}

/// Fillable outline of a stroked path, so bands can be painted with a gradient.
private func band(_ path: CGPath, width: CGFloat, cap: CGLineCap) -> CGPath {
  path.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 10)
}

// MARK: - Canvas

private struct Canvas {
  let cg: CGContext
  let pixelsWide: Int
  let pixelsHigh: Int

  func image() -> CGImage {
    guard let image = cg.makeImage() else {
      fail("could not snapshot a \(pixelsWide)x\(pixelsHigh) canvas")
    }
    return image
  }

  func pngData() -> Data {
    guard let data = NSBitmapImageRep(cgImage: image()).representation(using: .png, properties: [:])
    else {
      fail("could not PNG-encode a \(pixelsWide)x\(pixelsHigh) canvas")
    }
    return data
  }
}

private func render(pixelsWide: Int, pixelsHigh: Int, _ body: (CGContext) -> Void) -> Canvas {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let cg = CGContext(
      data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    fail("could not allocate a \(pixelsWide)x\(pixelsHigh) bitmap context")
  }
  cg.setShouldAntialias(true)
  cg.setAllowsAntialiasing(true)
  cg.interpolationQuality = .high

  let canvas = Canvas(cg: cg, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
  let previous = NSGraphicsContext.current
  NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
  body(cg)
  NSGraphicsContext.current = previous
  return canvas
}

// MARK: - App icon

/// Everything is laid out in a 1024×1024 design space (y grows upwards) and scaled to the target size.
private let designSize: CGFloat = 1024

private func drawAppIcon(_ cg: CGContext, pixels: Int) {
  cg.saveGState()
  cg.scaleBy(x: CGFloat(pixels) / designSize, y: CGFloat(pixels) / designSize)
  defer { cg.restoreGState() }

  let body = squircle(in: CGRect(x: 100, y: 100, width: 824, height: 824))
  let panel = squircle(in: CGRect(x: 136, y: 136, width: 752, height: 752))
  let rim = squircle(in: CGRect(x: 102, y: 102, width: 820, height: 820))

  // Soft drop shadow, then the body itself.
  cg.saveGState()
  cg.setShadow(
    offset: CGSize(width: 0, height: -20), blur: 44,
    color: color(Palette.shade, alpha: 0.55).cgColor)
  cg.addPath(body)
  cg.setFillColor(color(Palette.navy).cgColor)
  cg.fillPath()
  cg.restoreGState()

  // Depth gradient: indigo → navy → deep teal.
  fill(
    body,
    linear: gradient([
      Stop(Palette.indigo, at: 0),
      Stop(Palette.navy, at: 0.42),
      Stop(Palette.deep, at: 0.78),
      Stop(Palette.teal, at: 1),
    ]),
    from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: cg)

  cg.saveGState()
  cg.addPath(body)
  cg.clip()

  // Glass sheen: teal glow behind the dial, a soft top wash and a corner highlight.
  fill(
    body,
    radial: gradient([
      Stop(Palette.arcDeep, alpha: 0.22, at: 0),
      Stop(Palette.arcDeep, alpha: 0, at: 1),
    ]),
    center: CGPoint(x: 512, y: 470), radius: 520, in: cg)
  fill(
    body,
    linear: gradient([
      Stop(0xFFFFFF, alpha: 0.16, at: 0),
      Stop(0xFFFFFF, alpha: 0, at: 1),
    ]),
    from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 500), in: cg)
  fill(
    body,
    radial: gradient([
      Stop(0xFFFFFF, alpha: 0.10, at: 0),
      Stop(0xFFFFFF, alpha: 0, at: 1),
    ]),
    center: CGPoint(x: 330, y: 830), radius: 430, in: cg)
  fill(
    body,
    linear: gradient([
      Stop(Palette.shade, alpha: 0.38, at: 0),
      Stop(Palette.shade, alpha: 0, at: 1),
    ]),
    from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 410), in: cg)

  // Layered inner squircle panel.
  fill(panel, color: color(0xFFFFFF, alpha: 0.04), in: cg)
  stroke(panel, color: color(0xFFFFFF, alpha: 0.09), width: 3, cap: .butt, in: cg)

  drawDial(in: cg)

  cg.restoreGState()

  // Dark hairline rim so the icon keeps its edge on light backgrounds.
  stroke(rim, color: color(Palette.shade, alpha: 0.35), width: 3, cap: .butt, in: cg)
}

/// Centered gauge: track arc, filled value arc and an amber needle pointing at its end.
private func drawDial(in cg: CGContext) {
  let center = CGPoint(x: 512, y: 486)
  let radius: CGFloat = 278
  let thickness: CGFloat = 100
  let sweepStart = -28 * CGFloat.pi / 180
  let sweepEnd = 208 * CGFloat.pi / 180
  let valueEnd = 60 * CGFloat.pi / 180

  let track = CGMutablePath()
  track.addArc(
    center: center, radius: radius, startAngle: sweepStart, endAngle: sweepEnd, clockwise: false)
  fill(band(track, width: thickness, cap: .round), color: color(Palette.track, alpha: 0.34), in: cg)

  let value = CGMutablePath()
  value.addArc(
    center: center, radius: radius, startAngle: sweepStart, endAngle: valueEnd, clockwise: false)
  fill(
    band(value, width: thickness, cap: .round),
    linear: gradient([
      Stop(Palette.arcDeep, at: 0),
      Stop(Palette.arcLight, at: 1),
    ]),
    from: CGPoint(x: center.x + radius * cos(sweepStart), y: center.y + radius * sin(sweepStart)),
    to: CGPoint(x: center.x + radius * cos(valueEnd), y: center.y + radius * sin(valueEnd)), in: cg)

  // Tapered needle, warm accent.
  let tip = CGPoint(x: center.x + cos(valueEnd) * 258, y: center.y + sin(valueEnd) * 258)
  let perpendicular = CGPoint(x: -sin(valueEnd), y: cos(valueEnd))
  let baseHalf: CGFloat = 40
  let tipHalf: CGFloat = 14
  let needle = CGMutablePath()
  needle.move(
    to: CGPoint(x: center.x + perpendicular.x * baseHalf, y: center.y + perpendicular.y * baseHalf))
  needle.addLine(
    to: CGPoint(x: tip.x + perpendicular.x * tipHalf, y: tip.y + perpendicular.y * tipHalf))
  needle.addLine(
    to: CGPoint(x: tip.x - perpendicular.x * tipHalf, y: tip.y - perpendicular.y * tipHalf))
  needle.addLine(
    to: CGPoint(x: center.x - perpendicular.x * baseHalf, y: center.y - perpendicular.y * baseHalf))
  needle.closeSubpath()
  fill(
    needle,
    linear: gradient([
      Stop(Palette.amberDeep, at: 0),
      Stop(Palette.amberLight, at: 1),
    ]),
    from: center, to: tip, in: cg)

  // Hub: amber ring with a warm highlight core.
  fill(
    CGPath(
      ellipseIn: CGRect(x: center.x - 64, y: center.y - 64, width: 128, height: 128), transform: nil
    ),
    color: color(Palette.amber, alpha: 0.95), in: cg)
  fill(
    CGPath(
      ellipseIn: CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84), transform: nil),
    color: color(Palette.hub), in: cg)
}

// MARK: - Menu bar template glyph

/// Three descending tally bars — a depth chart, drawn in a 16×16 design space on whole pixels so the
/// 16 px bitmap stays crisp. Pure black + alpha so macOS can tint it for light and dark menu bars.
private func drawMenuBarGlyph(_ cg: CGContext, pixels: Int) {
  cg.saveGState()
  cg.scaleBy(x: CGFloat(pixels) / 16, y: CGFloat(pixels) / 16)
  defer { cg.restoreGState() }

  let bars = [
    CGRect(x: 2, y: 11, width: 12, height: 2),
    CGRect(x: 2, y: 7, width: 9, height: 2),
    CGRect(x: 2, y: 3, width: 6, height: 2),
  ]
  for bar in bars {
    let path = CGPath(
      roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil)
    fill(path, color: NSColor.black, in: cg)
  }
}

// MARK: - README hero

private func drawHero(_ cg: CGContext, pixelsWide: Int, pixelsHigh: Int) {
  let width = CGFloat(pixelsWide)
  let height = CGFloat(pixelsHigh)
  let background = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)

  fill(background, color: color(Palette.heroBackground), in: cg)
  fill(
    background,
    radial: gradient([
      Stop(Palette.indigo, alpha: 0.55, at: 0),
      Stop(Palette.indigo, alpha: 0, at: 1),
    ]),
    center: CGPoint(x: width * 0.18, y: height * 0.78), radius: width * 0.62, in: cg)
  fill(
    background,
    radial: gradient([
      Stop(Palette.arcDeep, alpha: 0.30, at: 0),
      Stop(Palette.arcDeep, alpha: 0, at: 1),
    ]),
    center: CGPoint(x: width * 0.10, y: height * 0.12), radius: width * 0.42, in: cg)
  fill(
    background,
    radial: gradient([
      Stop(0x000000, alpha: 0, at: 0.55),
      Stop(0x000000, alpha: 0.45, at: 1),
    ]),
    center: CGPoint(x: width / 2, y: height / 2), radius: width * 0.78, in: cg)

  let iconPixels = 300
  let icon = render(pixelsWide: iconPixels, pixelsHigh: iconPixels) {
    drawAppIcon($0, pixels: iconPixels)
  }
  cg.draw(icon.image(), in: CGRect(x: 64, y: 50, width: 300, height: 300))

  let wordmark = NSMutableAttributedString()
  let wordFont = NSFont.systemFont(ofSize: 104, weight: .bold)
  wordmark.append(
    NSAttributedString(
      string: "Deep",
      attributes: [.font: wordFont, .foregroundColor: color(Palette.ink), .kern: -1.5]))
  wordmark.append(
    NSAttributedString(
      string: "Tally",
      attributes: [.font: wordFont, .foregroundColor: color(Palette.wordTeal), .kern: -1.5]))
  let tagline = NSAttributedString(
    string: "DeepSeek balance · spend · cache-hit rate",
    attributes: [
      .font: NSFont.systemFont(ofSize: 28, weight: .medium),
      .foregroundColor: color(Palette.steel),
      .kern: 0.4,
    ])

  let wordSize = wordmark.size()
  let taglineSize = tagline.size()
  let textX: CGFloat = 412
  let ruleHeight: CGFloat = 6
  let gap: CGFloat = 26
  let blockHeight = wordSize.height + gap + ruleHeight + gap + taglineSize.height
  let wordBottom = (height + blockHeight) / 2 - wordSize.height
  let ruleY = wordBottom - gap - ruleHeight
  let taglineBottom = ruleY - gap - taglineSize.height

  wordmark.draw(at: CGPoint(x: textX, y: wordBottom))

  let rule = CGPath(
    roundedRect: CGRect(x: textX, y: ruleY, width: wordSize.width, height: ruleHeight),
    cornerWidth: ruleHeight / 2, cornerHeight: ruleHeight / 2, transform: nil)
  fill(
    rule,
    linear: gradient([
      Stop(Palette.amberDeep, at: 0),
      Stop(Palette.amber, at: 0.5),
      Stop(Palette.amberLight, at: 1),
    ]),
    from: CGPoint(x: textX, y: ruleY),
    to: CGPoint(x: textX + wordSize.width, y: ruleY + ruleHeight),
    in: cg)

  tagline.draw(at: CGPoint(x: textX, y: taglineBottom))
}

// MARK: - Output

private struct IconsetEntry {
  let name: String
  let pixels: Int
}

private let iconsetEntries = [
  IconsetEntry(name: "icon_16x16.png", pixels: 16),
  IconsetEntry(name: "icon_16x16@2x.png", pixels: 32),
  IconsetEntry(name: "icon_32x32.png", pixels: 32),
  IconsetEntry(name: "icon_32x32@2x.png", pixels: 64),
  IconsetEntry(name: "icon_128x128.png", pixels: 128),
  IconsetEntry(name: "icon_128x128@2x.png", pixels: 256),
  IconsetEntry(name: "icon_256x256.png", pixels: 256),
  IconsetEntry(name: "icon_256x256@2x.png", pixels: 512),
  IconsetEntry(name: "icon_512x512.png", pixels: 512),
  IconsetEntry(name: "icon_512x512@2x.png", pixels: 1024),
]

private func write(_ data: Data, to url: URL) {
  do {
    try data.write(to: url, options: .atomic)
  } catch {
    fail("could not write \(url.path): \(error)")
  }
}

private func runIconutil(iconset: URL, output: URL) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
  let pipe = Pipe()
  process.standardError = pipe
  process.standardOutput = pipe
  do {
    try process.run()
  } catch {
    fail("could not run /usr/bin/iconutil: \(error)")
  }
  let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  process.waitUntilExit()
  if process.terminationStatus != 0 {
    let detail = log.trimmingCharacters(in: .whitespacesAndNewlines)
    fail("iconutil failed (status \(process.terminationStatus)): \(detail)")
  }
}

// MARK: - Verification

private func bitmap(at url: URL) -> NSBitmapImageRep? {
  guard let data = try? Data(contentsOf: url) else { return nil }
  return NSBitmapImageRep(data: data)
}

private func verify() {
  var failures: [String] = []

  for entry in iconsetEntries {
    let url = iconsetDirectory.appendingPathComponent(entry.name)
    guard let rep = bitmap(at: url) else {
      failures.append("\(entry.name): missing or unreadable")
      continue
    }
    if rep.pixelsWide != entry.pixels || rep.pixelsHigh != entry.pixels {
      failures.append(
        "\(entry.name): \(rep.pixelsWide)x\(rep.pixelsHigh), expected \(entry.pixels)x\(entry.pixels)"
      )
    }
  }

  for (url, expected) in [(menuBarGlyphURL, 16), (menuBarGlyph2xURL, 32)] {
    let name = url.lastPathComponent
    guard let rep = bitmap(at: url) else {
      failures.append("\(name): missing or unreadable")
      continue
    }
    if rep.pixelsWide != expected || rep.pixelsHigh != expected {
      failures.append(
        "\(name): \(rep.pixelsWide)x\(rep.pixelsHigh), expected \(expected)x\(expected)")
    }
    var minAlpha: CGFloat = 1
    var maxAlpha: CGFloat = 0
    var coloredPixel = false
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide {
        guard let pixel = rep.colorAt(x: x, y: y) else { continue }
        let srgb = pixel.usingColorSpace(.sRGB) ?? pixel
        if srgb.redComponent > 0.004 || srgb.greenComponent > 0.004 || srgb.blueComponent > 0.004 {
          coloredPixel = true
        }
        minAlpha = min(minAlpha, srgb.alphaComponent)
        maxAlpha = max(maxAlpha, srgb.alphaComponent)
      }
    }
    if coloredPixel {
      failures.append("\(name): pixels are not pure black — template tinting would be wrong")
    }
    if minAlpha >= 1 || maxAlpha <= 0.5 {
      failures.append("\(name): no alpha coverage (min \(minAlpha), max \(maxAlpha))")
    }
  }

  guard let icnsData = try? Data(contentsOf: icnsURL) else {
    failures.append("Resources/AppIcon.icns: missing")
    return report(failures)
  }
  if String(data: icnsData.prefix(4), encoding: .ascii) != "icns" || icnsData.count < 10_000 {
    failures.append("Resources/AppIcon.icns: not a usable icns (\(icnsData.count) bytes)")
  }

  guard let heroRep = bitmap(at: heroURL) else {
    failures.append("docs/assets/hero.png: missing or unreadable")
    return report(failures)
  }
  if heroRep.pixelsWide != 1200 || heroRep.pixelsHigh != 400 {
    failures.append("hero.png: \(heroRep.pixelsWide)x\(heroRep.pixelsHigh), expected 1200x400")
  }
  var shades = Set<UInt32>()
  for y in stride(from: 0, to: heroRep.pixelsHigh, by: 4) {
    for x in stride(from: 0, to: heroRep.pixelsWide, by: 4) {
      guard let pixel = heroRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      let brightness = pixel.redComponent + pixel.greenComponent + pixel.blueComponent
      shades.insert(UInt32(brightness * 32))
    }
  }
  if shades.count < 8 {
    failures.append("hero.png: looks blank (only \(shades.count) tone levels)")
  }

  report(failures)
}

private func report(_ failures: [String]) {
  guard failures.isEmpty else {
    fail("output verification failed:\n  - " + failures.joined(separator: "\n  - "))
  }
}

// MARK: - Main

guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path)
else {
  fail(
    "repository root not found at \(repoRoot.path) — run this script from the DeepTally checkout")
}

let fileManager = FileManager.default
do {
  try fileManager.createDirectory(
    at: repoRoot.appendingPathComponent("Resources"), withIntermediateDirectories: true)
  try fileManager.createDirectory(
    at: repoRoot.appendingPathComponent("docs/assets"), withIntermediateDirectories: true)
  try fileManager.createDirectory(
    at: iconsetDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
  fail("could not create output directories: \(error)")
}
if fileManager.fileExists(atPath: iconsetDirectory.path) {
  do {
    try fileManager.removeItem(at: iconsetDirectory)
  } catch {
    fail("could not clear \(iconsetDirectory.path): \(error)")
  }
}
do {
  try fileManager.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
} catch {
  fail("could not create \(iconsetDirectory.path): \(error)")
}

for entry in iconsetEntries {
  let canvas = render(pixelsWide: entry.pixels, pixelsHigh: entry.pixels) {
    drawAppIcon($0, pixels: entry.pixels)
  }
  write(canvas.pngData(), to: iconsetDirectory.appendingPathComponent(entry.name))
}

write(
  render(pixelsWide: 16, pixelsHigh: 16) { drawMenuBarGlyph($0, pixels: 16) }.pngData(),
  to: menuBarGlyphURL)
write(
  render(pixelsWide: 32, pixelsHigh: 32) { drawMenuBarGlyph($0, pixels: 32) }.pngData(),
  to: menuBarGlyph2xURL)
write(
  render(pixelsWide: 1200, pixelsHigh: 400) { drawHero($0, pixelsWide: 1200, pixelsHigh: 400) }
    .pngData(),
  to: heroURL)

runIconutil(iconset: iconsetDirectory, output: icnsURL)
verify()

print("make-icon: \(iconsetEntries.count) iconset PNGs → dist/icon/AppIcon.iconset")
print("make-icon: Resources/AppIcon.icns (iconutil)")
print("make-icon: Resources/MenuBarIconTemplate.png 16x16 + @2x 32x32 (black + alpha)")
print("make-icon: docs/assets/hero.png 1200x400")
