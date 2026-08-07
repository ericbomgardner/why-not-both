import AVFoundation
import SwiftUI

struct ContentView: View {
  @StateObject private var cameraManager = CameraManager()
  @Environment(\.scenePhase) private var scenePhase
  @State private var pipCorner: PiPCorner = .topTrailing
  @State private var dragTranslation: CGSize = .zero
  @State private var isDraggingPiP = false
  @State private var shutterOpacity: Double = 0
  @State private var showingError = false

  private let snapAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)
  private let shutterHold = Duration.milliseconds(60)
  private let shutterFade = 0.25
  private let shutterDiameter: CGFloat = 80
  private let shutterMargin: CGFloat = 24

  private var controlStripThickness: CGFloat { shutterDiameter + shutterMargin * 2 }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.ignoresSafeArea()

        if cameraManager.isSessionConfigured {
          let frame = viewfinderSize(in: geometry.size)

          VStack(spacing: 0) {
            viewfinder(frame)
            shutterButton(framing: framing(in: frame))
              .frame(height: controlStripThickness)
          }
          .onChange(of: frame) { _, _ in
            isDraggingPiP = false
            dragTranslation = .zero
          }
        } else {
          statusView
        }
      }
    }
    .onAppear {
      setupCamera()
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        cameraManager.startSession()
      case .background:
        cameraManager.stopSession()
      default:
        break
      }
    }
    .alert("Camera Error", isPresented: $showingError) {
      Button("OK") {}
      Button("Settings") {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(settingsURL)
        }
      }
    } message: {
      Text(cameraManager.error?.localizedDescription ?? "An unknown error occurred.")
    }
    .onChange(of: cameraManager.error) { _, error in
      showingError = error != nil
    }
    .statusBarHidden()
  }

  // The frame keeps the capture's own shape, centred in the space above the controls. A capture
  // too tall to fit gets cropped rather than pillarboxed, so no bars appear down the sides.
  private func viewfinderSize(in container: CGSize) -> CGSize {
    let aspect = cameraManager.viewfinderAspectRatio
    guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }

    let height = min(container.width / aspect, max(container.height - controlStripThickness, 0))
    return CGSize(width: container.width, height: height)
  }

  private func viewfinder(_ frame: CGSize) -> some View {
    ZStack {
      if let backPreviewLayer = cameraManager.backPreviewLayer {
        CameraPreviewView(previewLayer: backPreviewLayer)
          .frame(width: frame.width, height: frame.height)
          .clipped()
      }

      if let frontPreviewLayer = cameraManager.frontPreviewLayer {
        pictureInPicture(frontPreviewLayer, in: frame)
          .frame(width: frame.width, height: frame.height)
      }

      // Blacking out only the frame keeps the shutter from blinding you, the way Photos does.
      Color.black
        .frame(width: frame.width, height: frame.height)
        .opacity(shutterOpacity)
        .allowsHitTesting(false)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func framing(in frame: CGSize) -> ViewfinderFraming {
    ViewfinderFraming(size: frame, pipRect: PiPLayout.rect(for: pipCorner, in: frame))
  }

  private func pictureInPicture(
    _ previewLayer: AVCaptureVideoPreviewLayer, in frame: CGSize
  ) -> some View {
    let pipSize = PiPLayout.size(in: frame)
    let anchor = PiPLayout.center(for: pipCorner, in: frame)
    let shape = RoundedRectangle(
      cornerRadius: PiPLayout.cornerRadius(forPiP: pipSize), style: .continuous)

    return CameraPreviewView(previewLayer: previewLayer)
      .frame(width: pipSize.width, height: pipSize.height)
      .clipShape(shape)
      .overlay(
        shape.strokeBorder(
          Color.white, lineWidth: PiPLayout.borderWidth(forPiP: pipSize))
      )
      .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
      .scaleEffect(isDraggingPiP ? 1.1 : 1)
      .animation(.easeInOut(duration: 0.2), value: isDraggingPiP)
      .position(
        x: anchor.x + dragTranslation.width,
        y: anchor.y + dragTranslation.height
      )
      .gesture(dragGesture(in: frame))
  }

  private func dragGesture(in frame: CGSize) -> some Gesture {
    // Global space: the view moves and scales mid-drag, which distorts translation in local space.
    DragGesture(coordinateSpace: .global)
      .onChanged { value in
        isDraggingPiP = true
        dragTranslation = clamped(value.translation, in: frame)
      }
      .onEnded { value in
        let anchor = PiPLayout.center(for: pipCorner, in: frame)
        let translation = clamped(value.translation, in: frame)
        let dropped = CGPoint(
          x: anchor.x + translation.width,
          y: anchor.y + translation.height
        )

        isDraggingPiP = false
        withAnimation(snapAnimation) {
          pipCorner = PiPLayout.nearestCorner(to: dropped, in: frame)
          dragTranslation = .zero
        }
      }
  }

  // Keeping the PiP inside the frame keeps it inside the saved photo.
  private func clamped(_ translation: CGSize, in frame: CGSize) -> CGSize {
    let anchor = PiPLayout.center(for: pipCorner, in: frame)
    let pip = PiPLayout.size(in: frame)
    let x = min(max(anchor.x + translation.width, pip.width / 2), frame.width - pip.width / 2)
    let y = min(max(anchor.y + translation.height, pip.height / 2), frame.height - pip.height / 2)
    return CGSize(width: x - anchor.x, height: y - anchor.y)
  }

  private func shutterButton(framing: ViewfinderFraming) -> some View {
    Button {
      capturePhoto(framing: framing)
    } label: {
      ZStack {
        Circle()
          .stroke(Color.white, lineWidth: 4)
          .frame(width: shutterDiameter, height: shutterDiameter)

        Circle()
          .fill(cameraManager.isCapturing ? Color.red : Color.white)
          .frame(width: shutterDiameter * 0.85, height: shutterDiameter * 0.85)
          .scaleEffect(cameraManager.isCapturing ? 0.8 : 1.0)
          .animation(.easeInOut(duration: 0.2), value: cameraManager.isCapturing)
      }
    }
    .disabled(cameraManager.isCapturing)
  }

  private var statusView: some View {
    VStack {
      if let error = cameraManager.error {
        Image(systemName: "camera.fill")
          .font(.system(size: 60))
          .foregroundColor(.white)

        Text("Camera Error")
          .font(.title)
          .foregroundColor(.white)
          .padding()

        Text(error.localizedDescription)
          .foregroundColor(.gray)
          .multilineTextAlignment(.center)
          .padding()

        Button("Retry") {
          setupCamera()
        }
        .foregroundColor(.blue)
        .padding()
      } else {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
          .scaleEffect(2.0)

        Text("Setting up cameras...")
          .foregroundColor(.white)
          .padding()
      }
    }
  }

  private func setupCamera() {
    Task {
      await cameraManager.setupCamera()
    }
  }

  private func capturePhoto(framing: ViewfinderFraming) {
    // Only flash if the shutter was actually accepted, so a rejected tap can't look like a shot.
    guard cameraManager.capturePhoto(framing: framing) else { return }

    shutterOpacity = 1
    Task {
      try? await Task.sleep(for: shutterHold)
      withAnimation(.easeOut(duration: shutterFade)) {
        shutterOpacity = 0
      }
    }
  }
}

#Preview {
  ContentView()
}
