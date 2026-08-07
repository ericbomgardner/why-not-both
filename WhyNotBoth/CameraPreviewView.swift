import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
  let previewLayer: AVCaptureVideoPreviewLayer

  func makeUIView(context: Context) -> PreviewLayerView {
    let view = PreviewLayerView()
    view.previewLayer = previewLayer
    return view
  }

  func updateUIView(_ uiView: PreviewLayerView, context: Context) {
    uiView.previewLayer = previewLayer
  }
}

final class PreviewLayerView: UIView {
  var previewLayer: AVCaptureVideoPreviewLayer? {
    didSet {
      guard previewLayer !== oldValue else { return }
      oldValue?.removeFromSuperlayer()
      if let previewLayer {
        layer.addSublayer(previewLayer)
      }
      setNeedsLayout()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Layer frame changes animate implicitly, which leaves the preview lagging behind its view.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    previewLayer?.frame = bounds
    CATransaction.commit()
  }
}
