import Foundation

enum PiPCorner: CaseIterable {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing
}

// What the back preview was showing when the shutter fired, and where the PiP sat inside it.
struct ViewfinderFraming {
  let size: CGSize
  let pipRect: CGRect
}

enum PiPLayout {
  static let shortEdgeFraction: CGFloat = 0.28
  static let aspectRatio: CGFloat = 3.0 / 4.0
  static let marginFraction: CGFloat = 0.04
  static let cornerRadiusFraction: CGFloat = 0.18
  static let borderWidthFraction: CGFloat = 0.03

  // Measured off the frame's short edge, so the PiP keeps its size relative to the frame instead
  // of ballooning when the frame turns landscape. It turns with the frame for the same reason.
  static func size(in frame: CGSize) -> CGSize {
    let shortEdge = min(frame.width, frame.height) * shortEdgeFraction

    if frame.width > frame.height {
      return CGSize(width: shortEdge / aspectRatio, height: shortEdge)
    }
    return CGSize(width: shortEdge, height: shortEdge / aspectRatio)
  }

  // Both are relative to the PiP itself, so the screen and the saved photo agree at any scale.
  static func cornerRadius(forPiP pip: CGSize) -> CGFloat {
    min(pip.width, pip.height) * cornerRadiusFraction
  }

  static func borderWidth(forPiP pip: CGSize) -> CGFloat {
    min(pip.width, pip.height) * borderWidthFraction
  }

  static func center(for corner: PiPCorner, in container: CGSize) -> CGPoint {
    let pip = size(in: container)
    let margin = min(container.width, container.height) * marginFraction

    let x: CGFloat
    switch corner {
    case .topLeading, .bottomLeading:
      x = margin + pip.width / 2
    case .topTrailing, .bottomTrailing:
      x = container.width - margin - pip.width / 2
    }

    let y: CGFloat
    switch corner {
    case .topLeading, .topTrailing:
      y = margin + pip.height / 2
    case .bottomLeading, .bottomTrailing:
      y = container.height - margin - pip.height / 2
    }

    return CGPoint(x: x, y: y)
  }

  static func rect(for corner: PiPCorner, in container: CGSize) -> CGRect {
    let pip = size(in: container)
    let middle = center(for: corner, in: container)
    let origin = CGPoint(x: middle.x - pip.width / 2, y: middle.y - pip.height / 2)
    return CGRect(origin: origin, size: pip)
  }

  static func nearestCorner(to point: CGPoint, in container: CGSize) -> PiPCorner {
    func distance(to corner: PiPCorner) -> CGFloat {
      let center = center(for: corner, in: container)
      return hypot(center.x - point.x, center.y - point.y)
    }

    return PiPCorner.allCases.min { distance(to: $0) < distance(to: $1) } ?? .topTrailing
  }
}
