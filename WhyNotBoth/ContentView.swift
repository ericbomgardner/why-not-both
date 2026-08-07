import AVFoundation
import SwiftUI

struct ContentView: View {
  @StateObject private var cameraManager = CameraManager()
  @Environment(\.scenePhase) private var scenePhase
  @State private var pipCorner: PiPCorner = .topTrailing
  @State private var dragTranslation: CGSize = .zero
  @State private var isDraggingPiP = false
  @State private var showingPreview = false
  @State private var showingError = false

  private let snapAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.ignoresSafeArea()

        if cameraManager.isSessionConfigured {
          if let backPreviewLayer = cameraManager.backPreviewLayer {
            CameraPreviewView(previewLayer: backPreviewLayer)
              .ignoresSafeArea()
          }

          if let frontPreviewLayer = cameraManager.frontPreviewLayer {
            pictureInPicture(frontPreviewLayer, in: geometry.size)
          }

          captureControls(framing: viewfinderFraming(in: geometry))
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
    .sheet(isPresented: $showingPreview) {
      PhotoPreviewView(cameraManager: cameraManager, isPresented: $showingPreview)
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
    .onChange(of: cameraManager.capturedImage) { _, newImage in
      if newImage != nil {
        showingPreview = true
      }
    }
    .onChange(of: cameraManager.error) { _, error in
      showingError = error != nil
    }
    .statusBarHidden()
  }

  private func pictureInPicture(
    _ previewLayer: AVCaptureVideoPreviewLayer, in container: CGSize
  ) -> some View {
    let pipSize = PiPLayout.size(inContainerOfWidth: container.width)
    let anchor = PiPLayout.center(for: pipCorner, in: container)
    let shape = RoundedRectangle(
      cornerRadius: PiPLayout.cornerRadius(forPiPWidth: pipSize.width), style: .continuous)

    return CameraPreviewView(previewLayer: previewLayer)
      .frame(width: pipSize.width, height: pipSize.height)
      .clipShape(shape)
      .overlay(
        shape.strokeBorder(
          Color.white, lineWidth: PiPLayout.borderWidth(forPiPWidth: pipSize.width))
      )
      .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
      .scaleEffect(isDraggingPiP ? 1.1 : 1)
      .animation(.easeInOut(duration: 0.2), value: isDraggingPiP)
      .position(
        x: anchor.x + dragTranslation.width,
        y: anchor.y + dragTranslation.height
      )
      .gesture(dragGesture(in: container))
  }

  private func dragGesture(in container: CGSize) -> some Gesture {
    // Global space: the view moves and scales mid-drag, which distorts translation in local space.
    DragGesture(coordinateSpace: .global)
      .onChanged { value in
        isDraggingPiP = true
        dragTranslation = value.translation
      }
      .onEnded { value in
        let anchor = PiPLayout.center(for: pipCorner, in: container)
        let dropped = CGPoint(
          x: anchor.x + value.translation.width,
          y: anchor.y + value.translation.height
        )

        isDraggingPiP = false
        withAnimation(snapAnimation) {
          pipCorner = PiPLayout.nearestCorner(to: dropped, in: container)
          dragTranslation = .zero
        }
      }
  }

  // The back preview ignores the safe area but the PiP doesn't, so shift it into full-screen space.
  private func viewfinderFraming(in geometry: GeometryProxy) -> ViewfinderFraming {
    let insets = geometry.safeAreaInsets
    let full = CGSize(
      width: geometry.size.width + insets.leading + insets.trailing,
      height: geometry.size.height + insets.top + insets.bottom
    )

    var pipRect = PiPLayout.rect(for: pipCorner, in: geometry.size)
    pipRect.origin.x += insets.leading
    pipRect.origin.y += insets.top

    return ViewfinderFraming(size: full, pipRect: pipRect)
  }

  private func captureControls(framing: ViewfinderFraming) -> some View {
    VStack {
      Spacer()

      Button {
        cameraManager.capturePhoto(framing: framing)
      } label: {
        ZStack {
          Circle()
            .stroke(Color.white, lineWidth: 4)
            .frame(width: 80, height: 80)

          Circle()
            .fill(cameraManager.isCapturing ? Color.red : Color.white)
            .frame(width: 68, height: 68)
            .scaleEffect(cameraManager.isCapturing ? 0.8 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: cameraManager.isCapturing)
        }
      }
      .disabled(cameraManager.isCapturing)
      .padding(.bottom, 24)
    }
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

}

#Preview {
  ContentView()
}
