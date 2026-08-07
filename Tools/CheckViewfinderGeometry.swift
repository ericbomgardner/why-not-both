// Checks that the mask tells the truth: what the viewfinder frames is what gets saved, at every
// capture aspect and PiP corner, in both orientations. Multi-cam won't run in the simulator, so
// this is how the layout arithmetic gets exercised without a device.
// Usage: swiftc -o /tmp/check-viewfinder WhyNotBoth/PiPLayout.swift Tools/CheckViewfinderGeometry.swift && /tmp/check-viewfinder

import CoreGraphics
import Foundation

// Mirrors ContentView. Kept in step by hand — these are the numbers the view lays out from.
let shutterDiameter: CGFloat = 80
let shutterMargin: CGFloat = 24
let controlStripThickness = shutterDiameter + shutterMargin * 2

func isLandscape(_ container: CGSize) -> Bool { container.width > container.height }

func availableSize(in container: CGSize) -> CGSize {
  if isLandscape(container) {
    return CGSize(width: max(container.width - controlStripThickness, 0), height: container.height)
  }
  return CGSize(width: container.width, height: max(container.height - controlStripThickness, 0))
}

func viewfinderSize(in container: CGSize, aspect: CGFloat) -> CGSize {
  let available = availableSize(in: container)
  guard available.width > 0, available.height > 0 else { return .zero }
  let clamped = max(aspect, available.width / available.height)
  return CGSize(width: available.width, height: available.width / clamped)
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
  let pip = PiPLayout.size(inContainerOfWidth: frame.width)
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

// iPhone 15 Pro safe areas, and the two capture shapes multi-cam offers.
let portraitSafeArea = CGSize(width: 393, height: 852 - 59 - 34)
let landscapeSafeArea = CGSize(width: 852 - 59 * 2, height: 393 - 21)
let fourThree = CGSize(width: 4032, height: 3024)
let sixteenNine = CGSize(width: 1920, height: 1080)

// A device held portrait captures a portrait-shaped still, and vice versa.
let cases: [(String, CGSize, CGFloat, CGSize)] = [
  (
    "portrait-4:3", portraitSafeArea, fourThree.height / fourThree.width,
    CGSize(width: 3024, height: 4032)
  ),
  (
    "portrait-16:9", portraitSafeArea, sixteenNine.height / sixteenNine.width,
    CGSize(width: 1080, height: 1920)
  ),
  ("landscape-4:3", landscapeSafeArea, fourThree.width / fourThree.height, fourThree),
  ("landscape-16:9", landscapeSafeArea, sixteenNine.width / sixteenNine.height, sixteenNine),
]

@main
enum CheckViewfinderGeometry {
  static func main() {
    for (name, safeArea, aspect, photo) in cases {
      run(name: name, safeArea: safeArea, aspect: aspect, photo: photo)
    }

    // Dropping the PiP nearest a corner selects that corner.
    for corner in PiPCorner.allCases {
      let frame = viewfinderSize(in: portraitSafeArea, aspect: 0.75)
      let center = PiPLayout.center(for: corner, in: frame)
      check(
        "\(corner) snaps to itself",
        PiPLayout.nearestCorner(to: center, in: frame) == corner,
        "center \(center)")
    }

    print(failures.isEmpty ? "\nALL PASSED" : "\nFAILED: \(failures)")
    exit(failures.isEmpty ? 0 : 1)
  }

  static func run(name: String, safeArea: CGSize, aspect: CGFloat, photo: CGSize) {
    let frame = viewfinderSize(in: safeArea, aspect: aspect)
    let available = availableSize(in: safeArea)

  // No bars down the sides, whatever the capture shape.
  check(
    "\(name) frame fills the available width",
    approx(frame.width, available.width),
    "frame width \(frame.width) vs available \(available.width)")

  check(
    "\(name) frame fits the available height",
    frame.height <= available.height + 0.01,
    "frame height \(frame.height) vs available \(available.height)")

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
      let size = PiPLayout.size(inContainerOfWidth: frame.width)
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
