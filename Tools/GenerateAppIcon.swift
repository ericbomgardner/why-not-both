// Renders the app icon: the viewfinder, with the front-camera PiP parked in its top trailing corner.
// Usage: swift Tools/GenerateAppIcon.swift [output-directory]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

// Deliberately coarser than PiPLayout's live fractions — at Spotlight size the real proportions
// shrink the PiP and its border into a smudge.
enum IconLayout {
  static let viewfinderHeightFraction: CGFloat = 0.74
  static let viewfinderAspectRatio: CGFloat = 3.0 / 4.0
  static let viewfinderCornerFraction: CGFloat = 0.18
  static let viewfinderStrokeFraction: CGFloat = 0.038
  static let pipWidthFraction: CGFloat = 0.44
  static let pipMarginFraction: CGFloat = 0.13
  static let pipCornerFraction: CGFloat = 0.18
  static let pipStrokeFraction: CGFloat = 0.12

  static var viewfinder: CGRect {
    let height = canvas * viewfinderHeightFraction
    let width = height * viewfinderAspectRatio
    return CGRect(
      x: (canvas - width) / 2, y: (canvas - height) / 2, width: width, height: height)
  }

  static var viewfinderStroke: CGFloat { canvas * viewfinderStrokeFraction }

  // Core Graphics puts the origin at the bottom left, so maxY is the top edge.
  static var pip: CGRect {
    let frame = viewfinder.insetBy(dx: viewfinderStroke / 2, dy: viewfinderStroke / 2)
    let width = viewfinder.width * pipWidthFraction
    let height = width / viewfinderAspectRatio
    let margin = viewfinder.width * pipMarginFraction
    return CGRect(
      x: frame.maxX - margin - width,
      y: frame.maxY - margin - height,
      width: width,
      height: height
    )
  }

  static var pipStroke: CGFloat { pip.width * pipStrokeFraction }
}

struct Variant {
  let filename: String
  let background: (top: CGFloat, bottom: CGFloat)?
  let viewfinderFill: CGFloat
  let pipFill: CGFloat
  let stroke: CGFloat
  let castsShadow: Bool
}

// Dark and tinted stay transparent so the system's own backdrop shows through behind the mark.
let variants = [
  Variant(
    filename: "AppIcon.png", background: (top: 0.12, bottom: 0.02),
    viewfinderFill: 0.07, pipFill: 0.20, stroke: 1.0, castsShadow: true),
  Variant(
    filename: "AppIcon-Dark.png", background: nil,
    viewfinderFill: 0.06, pipFill: 0.16, stroke: 0.95, castsShadow: true),
  Variant(
    filename: "AppIcon-Tinted.png", background: nil,
    viewfinderFill: 0.28, pipFill: 0.50, stroke: 1.0, castsShadow: false),
]

let colorSpace = CGColorSpaceCreateDeviceRGB()

func gray(_ level: CGFloat, alpha: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: colorSpace, components: [level, level, level, alpha])!
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ variant: Variant) -> CGImage {
  // App Store validation rejects a primary icon carrying an alpha channel, even a fully opaque one.
  let alpha: CGImageAlphaInfo = variant.background == nil ? .premultipliedLast : .noneSkipLast
  let context = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: alpha.rawValue)!

  if let background = variant.background {
    let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: [gray(background.top), gray(background.bottom)] as CFArray,
      locations: [0, 1])!
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])
  }

  let viewfinder = IconLayout.viewfinder
  let viewfinderStroke = IconLayout.viewfinderStroke
  let viewfinderPath = roundedPath(
    viewfinder.insetBy(dx: viewfinderStroke / 2, dy: viewfinderStroke / 2),
    radius: viewfinder.width * IconLayout.viewfinderCornerFraction)

  context.addPath(viewfinderPath)
  context.setFillColor(gray(1, alpha: variant.viewfinderFill))
  context.fillPath()

  context.addPath(viewfinderPath)
  context.setStrokeColor(gray(1, alpha: variant.stroke))
  context.setLineWidth(viewfinderStroke)
  context.strokePath()

  let pip = IconLayout.pip
  let pipStroke = IconLayout.pipStroke
  let pipPath = roundedPath(
    pip.insetBy(dx: pipStroke / 2, dy: pipStroke / 2),
    radius: pip.width * IconLayout.pipCornerFraction)

  context.saveGState()
  if variant.castsShadow {
    context.setShadow(
      offset: CGSize(width: 0, height: -pip.width * 0.04), blur: pip.width * 0.16,
      color: gray(0, alpha: 0.45))
  }
  context.addPath(pipPath)
  context.setFillColor(gray(1, alpha: variant.pipFill))
  context.fillPath()
  context.restoreGState()

  context.addPath(pipPath)
  context.setStrokeColor(gray(1, alpha: variant.stroke))
  context.setLineWidth(pipStroke)
  context.strokePath()

  return context.makeImage()!
}

let outputDirectory = URL(
  fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "WhyNotBoth/Assets.xcassets/AppIcon.appiconset")

for variant in variants {
  let url = outputDirectory.appendingPathComponent(variant.filename)
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else {
    FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
    exit(1)
  }

  CGImageDestinationAddImage(destination, render(variant), nil)
  guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not encode \(url.path)\n".utf8))
    exit(1)
  }

  print("wrote \(url.path)")
}
