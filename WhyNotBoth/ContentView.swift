import SwiftUI

struct ContentView: View {
  @StateObject private var cameraManager = CameraManager()
  @State private var frontCameraPosition = CGPoint(x: 300, y: 100)  // Default top-right
  @State private var showingPreview = false
  @State private var showingError = false

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Background (black when no camera)
        Color.black.ignoresSafeArea()

        if cameraManager.isSessionConfigured {
          // Back camera preview (fullscreen)
          if let backPreviewLayer = cameraManager.backPreviewLayer {
            BackCameraPreviewView(previewLayer: backPreviewLayer)
              .ignoresSafeArea()
          }

          // Front camera preview (draggable overlay)
          if let frontPreviewLayer = cameraManager.frontPreviewLayer {
            let overlaySize = CGSize(
              width: geometry.size.width * 0.25,
              height: geometry.size.height * 0.25
            )

            FrontCameraPreviewView(
              previewLayer: frontPreviewLayer,
              position: $frontCameraPosition,
              size: overlaySize
            )
            .frame(width: overlaySize.width, height: overlaySize.height)
            .position(frontCameraPosition)
          }

          // Camera controls overlay
          VStack {
            Spacer()

            HStack {
              Spacer()

              // Capture button
              Button(action: capturePhoto) {
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

              Spacer()
            }
            .padding(.bottom, 50)
          }
        } else {
          // Loading or error state
          VStack {
            if cameraManager.error != nil {
              Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.white)

              Text("Camera Error")
                .font(.title)
                .foregroundColor(.white)
                .padding()

              if let error = cameraManager.error {
                Text(error.localizedDescription)
                  .foregroundColor(.gray)
                  .multilineTextAlignment(.center)
                  .padding()
              }

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
      }
    }
    .onAppear {
      setupCamera()
      setDefaultFrontCameraPosition()
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

  private func setupCamera() {
    Task {
      await cameraManager.setupCamera()
    }
  }

  private func capturePhoto() {
    cameraManager.capturePhoto()
  }

  private func setDefaultFrontCameraPosition() {
    // Set initial position to top-right corner
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let screenWidth = UIScreen.main.bounds.width
      let screenHeight = UIScreen.main.bounds.height
      let overlaySize = CGSize(
        width: screenWidth * 0.25,
        height: screenHeight * 0.25
      )

      frontCameraPosition = CGPoint(
        x: screenWidth - overlaySize.width / 2 - 20,
        y: overlaySize.height / 2 + 60  // Account for safe area
      )
    }
  }
}

#Preview {
  ContentView()
}
