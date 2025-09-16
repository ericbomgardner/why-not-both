@preconcurrency import AVFoundation
import Foundation
import Photos
import UIKit

@MainActor
class CameraManager: ObservableObject {
  // MARK: - Published Properties
  @Published var backPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published var frontPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published var capturedImage: UIImage?
  @Published var isCapturing = false
  @Published var error: CameraError?
  @Published var isSessionConfigured = false

  // MARK: - Private Properties
  private var multiCamSession: AVCaptureMultiCamSession?
  private var backCameraOutput: AVCapturePhotoOutput?
  private var frontCameraOutput: AVCapturePhotoOutput?
  private var backCameraInput: AVCaptureDeviceInput?
  private var frontCameraInput: AVCaptureDeviceInput?

  // For simultaneous capture
  private var capturedBackImage: UIImage?
  private var capturedFrontImage: UIImage?
  private var captureCount = 0
  
  // Delegate instances that need to stay alive during capture
  private var backCameraDelegate: BackCameraPhotoDelegate?
  private var frontCameraDelegate: FrontCameraPhotoDelegate?

  // MARK: - Setup Methods
  func setupCamera() async {
    guard await checkCameraPermissions() else {
      error = .permissionDenied
      return
    }

    guard AVCaptureMultiCamSession.isMultiCamSupported else {
      error = .multiCamNotSupported
      return
    }

    await configureSession()
  }

  private func checkCameraPermissions() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)

    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func configureSession() async {
    let session = AVCaptureMultiCamSession()

    session.beginConfiguration()

    // Configure back camera
    guard
      let backCamera = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .back),
      let backInput = try? AVCaptureDeviceInput(device: backCamera)
    else {
      error = .backCameraUnavailable
      session.commitConfiguration()
      return
    }

    if session.canAddInput(backInput) {
      session.addInput(backInput)
      backCameraInput = backInput
    }

    // Configure front camera
    guard
      let frontCamera = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .front),
      let frontInput = try? AVCaptureDeviceInput(device: frontCamera)
    else {
      error = .frontCameraUnavailable
      session.commitConfiguration()
      return
    }

    if session.canAddInput(frontInput) {
      session.addInput(frontInput)
      frontCameraInput = frontInput
    }

    // Configure photo outputs
    let backPhotoOutput = AVCapturePhotoOutput()
    let frontPhotoOutput = AVCapturePhotoOutput()

    if session.canAddOutput(backPhotoOutput) {
      session.addOutput(backPhotoOutput)
      backCameraOutput = backPhotoOutput
    }

    if session.canAddOutput(frontPhotoOutput) {
      session.addOutput(frontPhotoOutput)
      frontCameraOutput = frontPhotoOutput
    }

    // Explicitly connect inputs to photo outputs (required for multi-cam)
    if let backInput = backCameraInput,
      let backPort = backInput.ports.first(where: { port in
        port.mediaType == .video && port.sourceDeviceType == .builtInWideAngleCamera
          && port.sourceDevicePosition == .back
      })
    {
      let backOutputConnection = AVCaptureConnection(
        inputPorts: [backPort], output: backPhotoOutput)
      if session.canAddConnection(backOutputConnection) {
        session.addConnection(backOutputConnection)
      }
    }

    if let frontInput = frontCameraInput,
      let frontPort = frontInput.ports.first(where: { port in
        port.mediaType == .video && port.sourceDeviceType == .builtInWideAngleCamera
          && port.sourceDevicePosition == .front
      })
    {
      let frontOutputConnection = AVCaptureConnection(
        inputPorts: [frontPort], output: frontPhotoOutput)
      if session.canAddConnection(frontOutputConnection) {
        session.addConnection(frontOutputConnection)
      }
    }

    session.commitConfiguration()

    // Create preview layers with no automatic connection; we'll attach explicit connections
    let backPreview = AVCaptureVideoPreviewLayer()
    backPreview.videoGravity = .resizeAspectFill
    backPreview.setSessionWithNoConnection(session)

    let frontPreview = AVCaptureVideoPreviewLayer()
    frontPreview.videoGravity = .resizeAspectFill
    frontPreview.setSessionWithNoConnection(session)

    // Create explicit connections from input ports to the corresponding preview layers
    if let backPort = backInput.ports.first(where: { port in
      port.mediaType == .video && port.sourceDeviceType == .builtInWideAngleCamera
        && port.sourceDevicePosition == .back
    }) {
      let backConnection = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: backPreview)
      if session.canAddConnection(backConnection) {
        session.addConnection(backConnection)
      }
    }

    if let frontPort = frontInput.ports.first(where: { port in
      port.mediaType == .video && port.sourceDeviceType == .builtInWideAngleCamera
        && port.sourceDevicePosition == .front
    }) {
      let frontConnection = AVCaptureConnection(
        inputPort: frontPort, videoPreviewLayer: frontPreview)
      if session.canAddConnection(frontConnection) {
        session.addConnection(frontConnection)
      }
    }

    multiCamSession = session
    backPreviewLayer = backPreview
    frontPreviewLayer = frontPreview
    isSessionConfigured = true

    // Start the session
    DispatchQueue.global(qos: .userInitiated).async {
      session.startRunning()
    }
  }

  // MARK: - Capture Methods
  func capturePhoto() {
    guard !isCapturing,
      let backOutput = backCameraOutput,
      let frontOutput = frontCameraOutput
    else { return }

    isCapturing = true
    captureCount = 0
    capturedBackImage = nil
    capturedFrontImage = nil

    // Create and store delegate references to prevent deallocation
    backCameraDelegate = BackCameraPhotoDelegate(manager: self)
    frontCameraDelegate = FrontCameraPhotoDelegate(manager: self)

    let settings = AVCapturePhotoSettings()
    settings.flashMode = .off

    // Capture from both cameras simultaneously
    backOutput.capturePhoto(with: settings, delegate: backCameraDelegate!)
    frontOutput.capturePhoto(with: settings, delegate: frontCameraDelegate!)
  }

  func didCaptureBackPhoto(_ image: UIImage) {
    capturedBackImage = image
    captureCount += 1
    checkCaptureCompletion()
  }

  func didCaptureFrontPhoto(_ image: UIImage) {
    capturedFrontImage = image
    captureCount += 1
    checkCaptureCompletion()
  }

  private func checkCaptureCompletion() {
    guard captureCount == 2,
      let backImage = capturedBackImage,
      let frontImage = capturedFrontImage
    else { return }

    // Combine the images
    let combinedImage = combineImages(backImage: backImage, frontImage: frontImage)
    capturedImage = combinedImage
    isCapturing = false
    
    // Clean up delegate references after capture is complete
    backCameraDelegate = nil
    frontCameraDelegate = nil
  }

  private func combineImages(backImage: UIImage, frontImage: UIImage) -> UIImage? {
    let backSize = backImage.size

    UIGraphicsBeginImageContextWithOptions(backSize, false, backImage.scale)

    // Draw the back image (full screen)
    backImage.draw(in: CGRect(origin: .zero, size: backSize))

    // Calculate front image overlay position (top-right corner, 1/4 size)
    let overlaySize = CGSize(width: backSize.width * 0.25, height: backSize.height * 0.25)
    let overlayOrigin = CGPoint(
      x: backSize.width - overlaySize.width - 20,
      y: 20
    )
    let overlayRect = CGRect(origin: overlayOrigin, size: overlaySize)

    // Create rounded rect path
    let path = UIBezierPath(roundedRect: overlayRect, cornerRadius: 20)
    path.addClip()

    // Draw the front image (flipped horizontally to look like a mirror)
    UIGraphicsGetCurrentContext()?.translateBy(x: overlayRect.midX, y: overlayRect.midY)
    UIGraphicsGetCurrentContext()?.scaleBy(x: -1, y: 1)
    UIGraphicsGetCurrentContext()?.translateBy(x: -overlayRect.midX, y: -overlayRect.midY)

    frontImage.draw(in: overlayRect)

    let combinedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return combinedImage
  }

  // MARK: - Save Methods
  func saveImageToLibrary() async {
    guard let image = capturedImage else { return }

    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

    switch status {
    case .authorized, .limited:
      await saveImage(image)
    case .notDetermined:
      let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      if newStatus == .authorized || newStatus == .limited {
        await saveImage(image)
      } else {
        error = .photoLibraryPermissionDenied
      }
    case .denied, .restricted:
      error = .photoLibraryPermissionDenied
    @unknown default:
      error = .photoLibraryPermissionDenied
    }
  }

  private func saveImage(_ image: UIImage) async {
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.creationRequestForAsset(from: image)
      }
    } catch {
      self.error = .failedToSavePhoto
    }
  }

  // MARK: - Cleanup
  func stopSession() {
    multiCamSession?.stopRunning()
  }
}

// MARK: - Error Types
enum CameraError: LocalizedError {
  case permissionDenied
  case multiCamNotSupported
  case backCameraUnavailable
  case frontCameraUnavailable
  case photoLibraryPermissionDenied
  case failedToSavePhoto

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Camera permission denied. Please enable camera access in Settings."
    case .multiCamNotSupported:
      return "This device doesn't support multi-camera functionality."
    case .backCameraUnavailable:
      return "Back camera is not available."
    case .frontCameraUnavailable:
      return "Front camera is not available."
    case .photoLibraryPermissionDenied:
      return "Photo library permission denied. Please enable photo access in Settings."
    case .failedToSavePhoto:
      return "Failed to save photo to library."
    }
  }
}

// MARK: - Photo Capture Delegates
class BackCameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private weak var manager: CameraManager?

  init(manager: CameraManager) {
    self.manager = manager
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    if let error = error {
      print("Back camera capture error: \(error)")
      return
    }

    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      print("Failed to create image from back camera data")
      return
    }

    Task { @MainActor in
      manager?.didCaptureBackPhoto(image)
    }
  }
}

class FrontCameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private weak var manager: CameraManager?

  init(manager: CameraManager) {
    self.manager = manager
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    if let error = error {
      print("Front camera capture error: \(error)")
      return
    }

    guard let imageData = photo.fileDataRepresentation(),
      let image = UIImage(data: imageData)
    else {
      print("Failed to create image from front camera data")
      return
    }

    Task { @MainActor in
      manager?.didCaptureFrontPhoto(image)
    }
  }
}
