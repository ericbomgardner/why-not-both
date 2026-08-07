@preconcurrency import AVFoundation
import Foundation
import Photos
import UIKit

@MainActor
class CameraManager: ObservableObject {
  // MARK: - Published Properties
  @Published private(set) var backPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published private(set) var frontPreviewLayer: AVCaptureVideoPreviewLayer?
  @Published private(set) var viewfinderAspectRatio: CGFloat = 3.0 / 4.0
  @Published private(set) var isCapturing = false
  @Published var error: CameraError?
  @Published private(set) var isSessionConfigured = false

  // MARK: - Private Properties
  private nonisolated let sessionQueue = DispatchQueue(label: "com.toiptoip.WhyNotBoth.session")
  private var multiCamSession: AVCaptureMultiCamSession?
  private var backCameraOutput: AVCapturePhotoOutput?
  private var frontCameraOutput: AVCapturePhotoOutput?
  private var isConfiguring = false
  private var isForegrounded = true
  private var photoAspectRatio: CGFloat = 4.0 / 3.0
  private var captureOrientation: UIImage.Orientation = .up
  private var captureDelegates: [Int64: PhotoCaptureDelegate] = [:]
  private var pendingCaptures: [Int64: CheckedContinuation<UIImage?, Never>] = [:]
  private var rotationCoordinators: [AVCaptureDevice.RotationCoordinator] = []
  private var rotationObservations: [NSKeyValueObservation] = []

  // MARK: - Setup
  func setupCamera() async {
    guard !isSessionConfigured, !isConfiguring else { return }

    isConfiguring = true
    defer { isConfiguring = false }
    error = nil

    guard await checkCameraPermissions() else {
      error = .permissionDenied
      return
    }

    guard AVCaptureMultiCamSession.isMultiCamSupported else {
      error = .multiCamNotSupported
      return
    }

    let backPreview = AVCaptureVideoPreviewLayer()
    backPreview.videoGravity = .resizeAspectFill
    let frontPreview = AVCaptureVideoPreviewLayer()
    frontPreview.videoGravity = .resizeAspectFill

    do {
      let setup = try await buildSession(PreviewLayers(back: backPreview, front: frontPreview))

      multiCamSession = setup.session
      backCameraOutput = setup.backOutput
      frontCameraOutput = setup.frontOutput
      backPreviewLayer = backPreview
      frontPreviewLayer = frontPreview
      photoAspectRatio = setup.photoAspectRatio
      // The UI is locked to portrait, so the frame's shape is settled here rather than tracking
      // the device.
      viewfinderAspectRatio = 1 / setup.photoAspectRatio

      trackRotation(of: setup.backDevice, previewLayer: backPreview)

      isSessionConfigured = true
      if isForegrounded {
        startSession()
      }
    } catch let cameraError as CameraError {
      error = cameraError
    } catch {
      self.error = .sessionConfigurationFailed
    }
  }

  private func checkCameraPermissions() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
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

  private nonisolated func buildSession(_ previews: PreviewLayers) async throws -> SessionSetup {
    try await withCheckedThrowingContinuation { continuation in
      sessionQueue.async {
        do {
          continuation.resume(returning: try Self.configureSession(previews))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated static func configureSession(_ previews: PreviewLayers) throws -> SessionSetup
  {
    let backPreview = previews.back
    let frontPreview = previews.front
    guard
      let backDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .back)
    else { throw CameraError.backCameraUnavailable }

    guard
      let frontDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .front)
    else { throw CameraError.frontCameraUnavailable }

    let session = AVCaptureMultiCamSession()
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    let backOutput = AVCapturePhotoOutput()
    let frontOutput = AVCapturePhotoOutput()

    try attach(
      device: backDevice, output: backOutput, preview: backPreview, to: session,
      failure: .backCameraUnavailable)
    try attach(
      device: frontDevice, output: frontOutput, preview: frontPreview, to: session,
      failure: .frontCameraUnavailable)

    adoptWidestFormat(for: backDevice, in: session)
    useLargestStill(from: backDevice.activeFormat, for: backOutput)
    // The PiP is 3:4, so a 4:3 front source fills it without cropping the selfie.
    adoptWidestFormat(for: frontDevice, in: session)

    return SessionSetup(
      session: session,
      backDevice: backDevice,
      frontDevice: frontDevice,
      backOutput: backOutput,
      frontOutput: frontOutput,
      photoAspectRatio: aspectRatioOfPhoto(from: backOutput, device: backDevice)
    )
  }

  // A 16:9 multi-cam format is a crop of the sensor's 4:3 readout, so the default costs field of
  // view. Multi-cam budgets both cameras together, so anything that overruns is put back.
  private nonisolated static func adoptWidestFormat(
    for device: AVCaptureDevice, in session: AVCaptureMultiCamSession
  ) {
    let original = device.activeFormat
    let candidates =
      device.formats
      .filter(\.isMultiCamSupported)
      .filter { isFourThree(CMVideoFormatDescriptionGetDimensions($0.formatDescription)) }
      .sorted { pixelCount(of: $0) > pixelCount(of: $1) }

    guard !candidates.isEmpty, (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }

    // hardwareCost decides whether the session can run at all; systemPressureCost only says
    // whether it can run sustainably, and rises on a warm phone. Treating pressure as a veto
    // would hand a hot device back its 16:9 default, so it only breaks ties.
    var sustainable: AVCaptureDevice.Format?

    for candidate in candidates {
      device.activeFormat = candidate
      guard session.hardwareCost <= 1 else { continue }
      if session.systemPressureCost <= 1 {
        return
      }
      if sustainable == nil {
        sustainable = candidate
      }
    }

    device.activeFormat = sustainable ?? original
  }

  // maxPhotoDimensions defaults to the format's smallest still, which is a fraction of what the
  // same format will actually give.
  private nonisolated static func useLargestStill(
    from format: AVCaptureDevice.Format, for output: AVCapturePhotoOutput
  ) {
    let largest = format.supportedMaxPhotoDimensions.max {
      Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
    }
    guard let largest else { return }
    output.maxPhotoDimensions = largest
  }

  private nonisolated static func isFourThree(_ dimensions: CMVideoDimensions) -> Bool {
    guard dimensions.width > 0, dimensions.height > 0 else { return false }
    let aspect = CGFloat(dimensions.width) / CGFloat(dimensions.height)
    return abs(aspect - 4.0 / 3.0) < 0.01
  }

  private nonisolated static func pixelCount(of format: AVCaptureDevice.Format) -> Int {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    return Int(dimensions.width) * Int(dimensions.height)
  }

  // The still can differ in shape from the video format, and it's the still the mask describes.
  private nonisolated static func aspectRatioOfPhoto(
    from output: AVCapturePhotoOutput, device: AVCaptureDevice
  ) -> CGFloat {
    let photo = output.maxPhotoDimensions
    if photo.width > 0 && photo.height > 0 {
      return CGFloat(photo.width) / CGFloat(photo.height)
    }

    let video = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    guard video.width > 0 && video.height > 0 else { return 4.0 / 3.0 }
    return CGFloat(video.width) / CGFloat(video.height)
  }

  private nonisolated static func attach(
    device: AVCaptureDevice,
    output: AVCapturePhotoOutput,
    preview: AVCaptureVideoPreviewLayer,
    to session: AVCaptureMultiCamSession,
    failure: CameraError
  ) throws {
    guard let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else { throw failure }
    session.addInputWithNoConnections(input)

    guard
      let port = input.ports(
        for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position
      ).first
    else { throw failure }

    guard session.canAddOutput(output) else { throw failure }
    session.addOutputWithNoConnections(output)

    let outputConnection = AVCaptureConnection(inputPorts: [port], output: output)
    guard session.canAddConnection(outputConnection) else { throw failure }
    session.addConnection(outputConnection)

    preview.setSessionWithNoConnection(session)
    let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
    guard session.canAddConnection(previewConnection) else { throw failure }
    session.addConnection(previewConnection)

    for connection in [outputConnection, previewConnection]
    where connection.isVideoRotationAngleSupported(portraitRotationAngle) {
      connection.videoRotationAngle = portraitRotationAngle
    }

    // A mirrored preview is what makes a selfie framable, but mirroring is also what puts writing
    // backwards, so the still is explicitly left unmirrored — the way every phone camera does it.
    // Set rather than left to the guard above, which silently skips when it isn't supported.
    if device.position == .front {
      if previewConnection.isVideoMirroringSupported {
        previewConnection.automaticallyAdjustsVideoMirroring = false
        previewConnection.isVideoMirrored = true
      }
      if outputConnection.isVideoMirroringSupported {
        outputConnection.automaticallyAdjustsVideoMirroring = false
        outputConnection.isVideoMirrored = false
      }
    }
  }

  // AVFoundation calls portrait 90 degrees for these landscape-native sensors. The UI no longer
  // rotates, so both connections stay pinned here and the photo always matches the frame; the
  // device's real attitude only decides which way is up in the saved file.
  private nonisolated static let portraitRotationAngle: CGFloat = 90

  // MARK: - Rotation
  // Connections are pinned to portrait, so this only decides which way is up in the saved file.
  private func trackRotation(of device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
    let coordinator = AVCaptureDevice.RotationCoordinator(
      device: device, previewLayer: previewLayer)
    rotationCoordinators.append(coordinator)

    observeRotationAngle(\.videoRotationAngleForHorizonLevelCapture, of: coordinator) {
      [weak self] angle in
      self?.captureOrientation = Self.orientation(forHorizonLevelAngle: angle)
    }
  }

  private func observeRotationAngle(
    _ keyPath: KeyPath<AVCaptureDevice.RotationCoordinator, CGFloat>,
    of coordinator: AVCaptureDevice.RotationCoordinator,
    applying apply: @escaping @MainActor (CGFloat) -> Void
  ) {
    apply(coordinator[keyPath: keyPath])

    rotationObservations.append(
      coordinator.observe(keyPath, options: .new) { _, change in
        guard let angle = change.newValue else { return }
        Task { @MainActor in apply(angle) }
      })
  }

  // How far the phone is held from upright, as an orientation tag the photo library can apply
  // without touching a pixel.
  private static func orientation(forHorizonLevelAngle angle: CGFloat) -> UIImage.Orientation {
    let quarters = Int(((angle - portraitRotationAngle) / 90).rounded())
    let turns = ((quarters % 4) + 4) % 4

    // The tag says how to get back to upright, so it runs opposite to the way the phone turned.
    switch turns {
    case 1: return .right
    case 2: return .down
    case 3: return .left
    default: return .up
    }
  }

  // MARK: - Session Lifecycle
  func startSession() {
    isForegrounded = true
    guard let session = multiCamSession else { return }
    sessionQueue.async {
      guard !session.isRunning else { return }
      session.startRunning()
    }
  }

  func stopSession() {
    isForegrounded = false
    // Stopping the session can strand a capture's delegate callbacks, so resolve them first.
    cancelPendingCaptures()
    guard let session = multiCamSession else { return }
    sessionQueue.async {
      guard session.isRunning else { return }
      session.stopRunning()
    }
  }

  // MARK: - Capture
  func capturePhoto(framing: ViewfinderFraming) -> Bool {
    guard !isCapturing,
      let backOutput = backCameraOutput,
      let frontOutput = frontCameraOutput
    else { return false }

    isCapturing = true
    // Settled at the shutter, not after: the phone can turn while the capture is in flight, and
    // this tag is the only thing deciding which way is up.
    let orientation = captureOrientation

    Task {
      async let back = capture(from: backOutput)
      async let front = capture(from: frontOutput)
      let (backImage, frontImage) = await (back, front)

      isCapturing = false

      guard let backImage, let frontImage else {
        error = .captureFailed
        return
      }

      await save(
        composite(back: backImage, front: frontImage, framing: framing, orientation: orientation))
    }

    return true
  }

  private func capture(from output: AVCapturePhotoOutput) async -> UIImage? {
    let settings = AVCapturePhotoSettings()
    settings.flashMode = .off
    settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
    settings.maxPhotoDimensions = output.maxPhotoDimensions
    let id = settings.uniqueID

    let image = await withCheckedContinuation { continuation in
      pendingCaptures[id] = continuation
      let delegate = PhotoCaptureDelegate { [weak self] image in
        Task { @MainActor in self?.finishCapture(id: id, image: image) }
      }
      captureDelegates[id] = delegate
      output.capturePhoto(with: settings, delegate: delegate)
    }

    captureDelegates[id] = nil
    return image
  }

  // Resuming only via this lookup is what keeps a continuation from being resumed twice.
  private func finishCapture(id: Int64, image: UIImage?) {
    pendingCaptures.removeValue(forKey: id)?.resume(returning: image)
  }

  private func cancelPendingCaptures() {
    for id in pendingCaptures.keys {
      finishCapture(id: id, image: nil)
    }
  }

  private func composite(
    back: UIImage, front: UIImage, framing: ViewfinderFraming, orientation: UIImage.Orientation
  ) -> UIImage {
    // The preview aspect-fills, so crop away the bands the viewfinder never showed.
    let previewScale = max(
      framing.size.width / back.size.width,
      framing.size.height / back.size.height
    )
    let canvas = CGSize(
      width: min((framing.size.width / previewScale).rounded(), back.size.width),
      height: min((framing.size.height / previewScale).rounded(), back.size.height)
    )
    let crop = CGPoint(
      x: (back.size.width - canvas.width) / 2,
      y: (back.size.height - canvas.height) / 2
    )

    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = back.scale
    format.opaque = true

    let composited = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
      back.draw(in: CGRect(origin: CGPoint(x: -crop.x, y: -crop.y), size: back.size))

      let pipRect = framing.pipRect.applying(
        CGAffineTransform(scaleX: 1 / previewScale, y: 1 / previewScale))
      let radius = PiPLayout.cornerRadius(forPiP: pipRect.size)
      let lineWidth = PiPLayout.borderWidth(forPiP: pipRect.size)

      context.cgContext.saveGState()
      UIBezierPath(roundedRect: pipRect, cornerRadius: radius).addClip()
      front.drawAspectFill(in: pipRect)
      context.cgContext.restoreGState()

      let border = UIBezierPath(
        roundedRect: pipRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
        cornerRadius: radius - lineWidth / 2
      )
      border.lineWidth = lineWidth
      UIColor.white.setStroke()
      border.stroke()
    }

    // Tagging the orientation rotates the photo for anything that opens it without re-encoding a
    // single pixel, so the framing stays exactly as it was composed.
    guard orientation != .up, let pixels = composited.cgImage else { return composited }
    return UIImage(cgImage: pixels, scale: composited.scale, orientation: orientation)
  }

  // MARK: - Saving
  private func save(_ image: UIImage) async {
    var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .notDetermined {
      status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    guard status == .authorized || status == .limited else {
      error = .photoLibraryPermissionDenied
      return
    }

    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.creationRequestForAsset(from: image)
      }
    } catch {
      self.error = .failedToSavePhoto
    }
  }
}

// MARK: - Session Setup
// Safe to hand to the session queue only because the layers reach SwiftUI after configuration ends.
private struct PreviewLayers: @unchecked Sendable {
  let back: AVCaptureVideoPreviewLayer
  let front: AVCaptureVideoPreviewLayer
}

private struct SessionSetup {
  let session: AVCaptureMultiCamSession
  let backDevice: AVCaptureDevice
  let frontDevice: AVCaptureDevice
  let backOutput: AVCapturePhotoOutput
  let frontOutput: AVCapturePhotoOutput
  let photoAspectRatio: CGFloat
}

// MARK: - Error Types
enum CameraError: LocalizedError {
  case permissionDenied
  case multiCamNotSupported
  case backCameraUnavailable
  case frontCameraUnavailable
  case sessionConfigurationFailed
  case captureFailed
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
    case .sessionConfigurationFailed:
      return "Failed to set up the cameras."
    case .captureFailed:
      return "Failed to capture from both cameras. Please try again."
    case .photoLibraryPermissionDenied:
      return "Photo library permission denied. Please enable photo access in Settings."
    case .failedToSavePhoto:
      return "Failed to save photo to library."
    }
  }
}

// MARK: - Photo Capture Delegate
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let completion: @Sendable (UIImage?) -> Void
  private var image: UIImage?

  init(completion: @escaping @Sendable (UIImage?) -> Void) {
    self.completion = completion
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    guard error == nil, let data = photo.fileDataRepresentation() else { return }
    image = UIImage(data: data)
  }

  // Always called last, even when capture fails outright.
  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
  ) {
    completion(image)
  }
}

// MARK: - Drawing
extension UIImage {
  fileprivate func drawAspectFill(in rect: CGRect) {
    let scale = max(rect.width / size.width, rect.height / size.height)
    let filled = CGSize(width: size.width * scale, height: size.height * scale)
    draw(
      in: CGRect(
        x: rect.midX - filled.width / 2,
        y: rect.midY - filled.height / 2,
        width: filled.width,
        height: filled.height
      ))
  }
}
