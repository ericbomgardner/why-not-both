import SwiftUI

struct PhotoPreviewView: View {
  @ObservedObject var cameraManager: CameraManager
  @Binding var isPresented: Bool

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let image = cameraManager.capturedImage {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      VStack {
        HStack {
          Button("Discard") {
            discardPhoto()
          }
          .foregroundColor(.white)
          .padding()

          Spacer()

          Text("Preview")
            .foregroundColor(.white)
            .font(.headline)

          Spacer()

          Button("Save") {
            savePhoto()
          }
          .foregroundColor(.white)
          .padding()
        }
        .padding(.top)

        Spacer()

        HStack(spacing: 50) {
          Button(action: discardPhoto) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 60))
              .foregroundColor(.red)
              .background(Circle().fill(Color.white))
          }

          Button(action: savePhoto) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 60))
              .foregroundColor(.green)
              .background(Circle().fill(Color.white))
          }
        }
        .padding(.bottom, 50)
      }
    }
    .statusBarHidden()
  }

  private func discardPhoto() {
    cameraManager.capturedImage = nil
    isPresented = false
  }

  private func savePhoto() {
    Task {
      guard await cameraManager.saveImageToLibrary() else { return }
      cameraManager.capturedImage = nil
      isPresented = false
    }
  }
}
