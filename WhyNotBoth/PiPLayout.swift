import Foundation

enum PiPCorner: CaseIterable {
  case topLeading
  case topTrailing
  case bottomLeading
  case bottomTrailing
}

enum PiPLayout {
  static let widthFraction: CGFloat = 0.28
  static let aspectRatio: CGFloat = 3.0 / 4.0
  static let marginFraction: CGFloat = 0.04
  static let cornerRadiusFraction: CGFloat = 0.05
  static let borderWidthFraction: CGFloat = 0.008

  static func size(inContainerOfWidth width: CGFloat) -> CGSize {
    let pipWidth = width * widthFraction
    return CGSize(width: pipWidth, height: pipWidth / aspectRatio)
  }

  static func cornerRadius(inContainerOfWidth width: CGFloat) -> CGFloat {
    width * cornerRadiusFraction
  }

  static func borderWidth(inContainerOfWidth width: CGFloat) -> CGFloat {
    width * borderWidthFraction
  }

  static func center(for corner: PiPCorner, in container: CGSize) -> CGPoint {
    let pip = size(inContainerOfWidth: container.width)
    let margin = container.width * marginFraction

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
    let pip = size(inContainerOfWidth: container.width)
    let origin = center(for: corner, in: container)
    return CGRect(
      x: origin.x - pip.width / 2,
      y: origin.y - pip.height / 2,
      width: pip.width,
      height: pip.height
    )
  }

  static func nearestCorner(to point: CGPoint, in container: CGSize) -> PiPCorner {
    func distance(to corner: PiPCorner) -> CGFloat {
      let center = center(for: corner, in: container)
      return hypot(center.x - point.x, center.y - point.y)
    }

    return PiPCorner.allCases.min { distance(to: $0) < distance(to: $1) } ?? .topTrailing
  }
}
