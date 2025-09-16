import AVFoundation
import SwiftUI

// MARK: - Back Camera Preview
struct BackCameraPreviewView: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer

  func makeUIView(context: Context) -> PreviewLayerView {
    let view = PreviewLayerView()
    view.previewLayer = previewLayer
    return view
  }

  func updateUIView(_ uiView: PreviewLayerView, context: Context) {
    // Update if needed
  }
}

// MARK: - Front Camera Preview
struct FrontCameraPreviewView: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer
  @Binding var position: CGPoint
  let size: CGSize

  func makeUIView(context: Context) -> DraggablePreviewView {
    let view = DraggablePreviewView()
    view.previewLayer = previewLayer
    view.onPositionChanged = { newPosition in
      DispatchQueue.main.async {
        position = newPosition
      }
    }
    return view
  }

  func updateUIView(_ uiView: DraggablePreviewView, context: Context) {
    uiView.updateFrame(position: position, size: size)
  }
}

// MARK: - Base Preview Layer View
class PreviewLayerView: UIView {
  var previewLayer: AVCaptureVideoPreviewLayer? {
    didSet {
      if let oldLayer = oldValue {
        oldLayer.removeFromSuperlayer()
      }

      if let newLayer = previewLayer {
        layer.addSublayer(newLayer)
        updateLayerFrame()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateLayerFrame()
  }

  private func updateLayerFrame() {
    previewLayer?.frame = bounds
  }
}

// MARK: - Draggable Preview View
class DraggablePreviewView: UIView {
  var previewLayer: AVCaptureVideoPreviewLayer? {
    didSet {
      if let oldLayer = oldValue {
        oldLayer.removeFromSuperlayer()
      }

      if let newLayer = previewLayer {
        // Add rounded corners
        newLayer.cornerRadius = 20
        newLayer.masksToBounds = true
        layer.addSublayer(newLayer)
        updateLayerFrame()
      }
    }
  }

  var onPositionChanged: ((CGPoint) -> Void)?
  private var initialTouchPoint: CGPoint = .zero
  private var initialCenter: CGPoint = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupGestures()
    setupAppearance()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupGestures()
    setupAppearance()
  }

  private func setupGestures() {
    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(panGesture)
  }

  private func setupAppearance() {
    // Add border to make it look like FaceTime overlay
    layer.borderWidth = 3
    layer.borderColor = UIColor.white.cgColor
    layer.cornerRadius = 20
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.3
    layer.shadowOffset = CGSize(width: 0, height: 2)
    layer.shadowRadius = 8
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard let window = window else { return }

    switch gesture.state {
    case .began:
      initialTouchPoint = gesture.location(in: window)
      initialCenter = center

      // Add scale animation when dragging starts
      UIView.animate(withDuration: 0.2) {
        self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
      }

    case .changed:
      let translation = gesture.translation(in: window)
      let newCenter = CGPoint(
        x: initialCenter.x + translation.x,
        y: initialCenter.y + translation.y
      )

      //      // Keep the view within bounds with some padding
      //      let padding: CGFloat = 20
      //      let clampedCenter = CGPoint(
      //        x: max(
      //          bounds.width / 2 + padding,
      //          min(newCenter.x, window.bounds.width - bounds.width / 2 - padding)),
      //        y: max(
      //          bounds.height / 2 + padding,
      //          min(newCenter.y, window.bounds.height - bounds.height / 2 - padding))
      //      )

      center = newCenter

    case .ended, .cancelled:
      // Return to normal scale
      UIView.animate(withDuration: 0.2) {
        self.transform = .identity
      }

      // Animate to nearest corner or edge for better UX
      animateToNearestPosition()

    default:
      break
    }
  }

  private func animateToNearestPosition() {
    guard let window = window else { return }

    let padding: CGFloat = 20
    let cornerSize = bounds.size

    // Define corner positions
    let topLeft = CGPoint(x: cornerSize.width / 2 + padding, y: cornerSize.height / 2 + padding)
    let topRight = CGPoint(
      x: window.bounds.width - cornerSize.width / 2 - padding, y: cornerSize.height / 2 + padding
    )
    let bottomLeft = CGPoint(
      x: cornerSize.width / 2 + padding,
      y: window.bounds.height - cornerSize.height / 2 - padding)
    let bottomRight = CGPoint(
      x: window.bounds.width - cornerSize.width / 2 - padding,
      y: window.bounds.height - cornerSize.height / 2 - padding)

    let corners = [topLeft, topRight, bottomLeft, bottomRight]

    // Find the nearest corner
    let nearestCorner =
      corners.min { corner1, corner2 in
        let distance1 = sqrt(pow(corner1.x - center.x, 2) + pow(corner1.y - center.y, 2))
        let distance2 = sqrt(pow(corner2.x - center.x, 2) + pow(corner2.y - center.y, 2))
        return distance1 < distance2
      } ?? topRight

    // Animate to the nearest corner
    UIView.animate(
      withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5
    ) {
      self.center = nearestCorner
    } completion: { _ in
      self.onPositionChanged?(nearestCorner)
    }
  }

  func updateFrame(position: CGPoint, size: CGSize) {
    frame = CGRect(
      x: position.x - size.width / 2,
      y: position.y - size.height / 2,
      width: size.width,
      height: size.height
    )
    updateLayerFrame()
  }

  private func updateLayerFrame() {
    previewLayer?.frame = bounds
  }
}
