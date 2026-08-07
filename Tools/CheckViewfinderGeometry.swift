// Checks that the mask tells the truth: what the viewfinder frames is what gets saved, at every
// capture aspect and PiP corner. Multi-cam won't run in the simulator, so this is how the layout
// arithmetic gets exercised without a device.
// Usage: swiftc -o /tmp/check-viewfinder WhyNotBoth/PiPLayout.swift Tools/CheckViewfinderGeometry.swift && /tmp/check-viewfinder

import CoreGraphics
import Foundation

// Mirrors ContentView. Kept in step by hand — these are the numbers the view lays out from.
let shutterDiameter: CGFloat = 80
let shutterMargin: CGFloat = 24
let controlStripThickness = shutterDiameter + shutterMargin * 2

func viewfinderSize(in container: CGSize, aspect: CGFloat) -> CGSize {
  guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }

  let height = min(container.width / aspect, max(container.height - controlStripThickness, 0))
  return CGSize(width: container.width, height: height)
}

// Mirrors CameraManager.composite.
func canvasAndPiP(viewfinder: CGSize, photo: CGSize, pipRect: CGRect) -> (CGSize, CGRect) {
  let previewScale = max(viewfinder.width / photo.width, viewfinder.height / photo.height)
  let canvas = CGSize(
    width: min((viewfinder.width / previewScale).rounded(), photo.width),
    height: min((viewfinder.height / previewScale).rounded(), photo.height)
  )
  let scaled = pipRect.applying(CGAffineTransform(scaleX: 1 / previewScale, y: 1 / previewScale))
  return (canvas, scaled)
}

// Mirrors ContentView.clamped.
func clamped(_ translation: CGSize, from corner: PiPCorner, in frame: CGSize) -> CGSize {
  let anchor = PiPLayout.center(for: corner, in: frame)
  let pip = PiPLayout.size(in: frame)
  let x = min(max(anchor.x + translation.width, pip.width / 2), frame.width - pip.width / 2)
  let y = min(max(anchor.y + translation.height, pip.height / 2), frame.height - pip.height / 2)
  return CGSize(width: x - anchor.x, height: y - anchor.y)
}

func approx(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
  abs(a - b) <= tolerance
}

var failures: [String] = []

func check(_ name: String, _ passed: Bool, _ detail: String) {
  print("\(passed ? "PASS" : "FAIL")  \(name)  \(detail)")
  if !passed { failures.append(name) }
}

// The app is portrait-locked, so the container is always the portrait safe area. 4:3 is what
// format selection asks for; 16:9 is what a device that can't afford it falls back to.
let safeArea = CGSize(width: 393, height: 852 - 59 - 34)
let fourThreePhoto = CGSize(width: 3024, height: 4032)
let sixteenNinePhoto = CGSize(width: 1080, height: 1920)

let cases: [(String, CGFloat, CGSize)] = [
  ("4:3", fourThreePhoto.width / fourThreePhoto.height, fourThreePhoto),
  ("16:9", sixteenNinePhoto.width / sixteenNinePhoto.height, sixteenNinePhoto),
]

@main
enum CheckViewfinderGeometry {
  static func main() {
    for (name, aspect, photo) in cases {
      run(name: name, aspect: aspect, photo: photo)
    }

    fourThreeKeepsTheWholeSensorFrame()
    pipHoldsItsShapeInEitherFrame()

    // Dropping the PiP nearest a corner selects that corner.
    for corner in PiPCorner.allCases {
      let frame = viewfinderSize(in: safeArea, aspect: 0.75)
      let center = PiPLayout.center(for: corner, in: frame)
      check(
        "\(corner) snaps to itself",
        PiPLayout.nearestCorner(to: center, in: frame) == corner,
        "center \(center)")
    }

    print(failures.isEmpty ? "\nALL PASSED" : "\nFAILED: \(failures)")
    exit(failures.isEmpty ? 0 : 1)
  }

  // The whole point of choosing a 4:3 format: the frame fits it exactly, so nothing is cropped.
  static func fourThreeKeepsTheWholeSensorFrame() {
    let frame = viewfinderSize(
      in: safeArea, aspect: fourThreePhoto.width / fourThreePhoto.height)
    let (canvas, _) = canvasAndPiP(
      viewfinder: frame, photo: fourThreePhoto,
      pipRect: PiPLayout.rect(for: .topTrailing, in: frame))

    check(
      "4:3 saves the whole sensor frame",
      canvas == fourThreePhoto,
      "canvas \(canvas) vs photo \(fourThreePhoto)")
  }

  // PiPLayout is measured off the short edge so it can't balloon if it ever meets a wide frame.
  static func pipHoldsItsShapeInEitherFrame() {
    let tall = CGSize(width: 393, height: 524)
    let wide = CGSize(width: 524, height: 393)
    let tallPiP = PiPLayout.size(in: tall)
    let widePiP = PiPLayout.size(in: wide)

    let tallShare = (tallPiP.width * tallPiP.height) / (tall.width * tall.height)
    let wideShare = (widePiP.width * widePiP.height) / (wide.width * wide.height)

    check(
      "pip covers a similar share of either frame",
      approx(tallShare, wideShare, 0.02),
      "tall \(round(tallShare * 1000) / 10)% vs wide \(round(wideShare * 1000) / 10)%")

    check(
      "pip turns with the frame",
      tallPiP.width < tallPiP.height && widePiP.width > widePiP.height,
      "tall \(tallPiP) wide \(widePiP)")
  }

  static func run(name: String, aspect: CGFloat, photo: CGSize) {
    let frame = viewfinderSize(in: safeArea, aspect: aspect)

    // No bars down the sides, and the controls always have their room.
    check(
      "\(name) frame fills the width",
      approx(frame.width, safeArea.width),
      "frame width \(frame.width) vs container \(safeArea.width)")

    check(
      "\(name) frame leaves room for the controls",
      frame.height <= safeArea.height - controlStripThickness + 0.01,
      "frame height \(frame.height) vs \(safeArea.height - controlStripThickness)")

    for corner in PiPCorner.allCases {
      let pip = PiPLayout.rect(for: corner, in: frame)
      let (canvas, mapped) = canvasAndPiP(viewfinder: frame, photo: photo, pipRect: pip)

      // What's saved is shaped like the frame, and is a crop of a real photo.
      check(
        "\(name) \(corner) saved shape matches the frame",
        approx(canvas.width / canvas.height, frame.width / frame.height, 0.001),
        "canvas aspect \(canvas.width / canvas.height) vs frame \(frame.width / frame.height)")

      check(
        "\(name) \(corner) saved area is within the photo",
        canvas.width <= photo.width + 0.01 && canvas.height <= photo.height + 0.01,
        "canvas \(canvas.width)x\(canvas.height) vs photo \(photo.width)x\(photo.height)")

      // The PiP holds its size and its distance from every edge, on screen and in the file.
      check(
        "\(name) \(corner) pip width fraction",
        approx(pip.width / frame.width, mapped.width / canvas.width, 0.0001),
        "frame \(pip.width / frame.width) vs saved \(mapped.width / canvas.width)")

      let frameGaps = [
        pip.minX / frame.width, (frame.width - pip.maxX) / frame.width,
        pip.minY / frame.height, (frame.height - pip.maxY) / frame.height,
      ]
      let savedGaps = [
        mapped.minX / canvas.width, (canvas.width - mapped.maxX) / canvas.width,
        mapped.minY / canvas.height, (canvas.height - mapped.maxY) / canvas.height,
      ]
      check(
        "\(name) \(corner) pip edge gaps",
        zip(frameGaps, savedGaps).allSatisfy { approx($0, $1, 0.0001) },
        "frame \(frameGaps.map { round($0 * 1000) / 1000 }) "
          + "saved \(savedGaps.map { round($0 * 1000) / 1000 })")

      // A drag that runs off the screen still leaves the PiP inside the frame, so it can't be
      // dropped somewhere it wouldn't be saved.
      for runaway in [CGSize(width: -9999, height: -9999), CGSize(width: 9999, height: 9999)] {
        let translation = clamped(runaway, from: corner, in: frame)
        let anchor = PiPLayout.center(for: corner, in: frame)
        let size = PiPLayout.size(in: frame)
        let origin = CGPoint(
          x: anchor.x + translation.width - size.width / 2,
          y: anchor.y + translation.height - size.height / 2)
        let dragged = CGRect(origin: origin, size: size)

        check(
          "\(name) \(corner) runaway drag stays in frame",
          dragged.minX >= -0.01 && dragged.minY >= -0.01
            && dragged.maxX <= frame.width + 0.01 && dragged.maxY <= frame.height + 0.01,
          "dragged \(dragged) in \(frame)")
      }
    }
  }
}
