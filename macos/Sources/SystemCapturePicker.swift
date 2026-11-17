import AppKit
import CoreImage
import ScreenCaptureKit

@available(macOS 14.0, *)
final class SystemCapturePicker: NSObject, SCContentSharingPickerObserver {
  private var selection: CheckedContinuation<SCContentFilter, Error>?

  @MainActor func capture(window: Bool) async throws -> (image: CGImage, filter: SCContentFilter) {
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = window ? .singleWindow : .singleDisplay
    let previous = picker.defaultConfiguration
    picker.defaultConfiguration = configuration
    picker.add(self)
    picker.isActive = true
    defer {
      picker.remove(self)
      picker.isActive = false
      picker.defaultConfiguration = previous
    }
    let filter = try await withCheckedThrowingContinuation { continuation in
      selection = continuation
      picker.present(using: window ? .window : .display)
    }
    let configurationForImage = SCStreamConfiguration()
    configurationForImage.width = max(
      1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
    configurationForImage.height = max(
      1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
    configurationForImage.showsCursor = false
    configurationForImage.capturesAudio = false
    configurationForImage.queueDepth = 3
    let image = try await FirstScreenFrame().read(filter, configurationForImage)
    return (image, filter)
  }

  @MainActor private func resolve(_ result: Result<SCContentFilter, Error>) {
    let pending = selection
    selection = nil
    pending?.resume(with: result)
  }
  func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    Task { @MainActor in resolve(.failure(CancellationError())) }
  }
  func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    Task { @MainActor in resolve(.success(filter)) }
  }
  func contentSharingPickerStartDidFailWithError(_ error: Error) {
    Task { @MainActor in resolve(.failure(error)) }
  }
}

@available(macOS 14.0, *)
private final class FirstScreenFrame: NSObject, SCStreamOutput, SCStreamDelegate {
  // Output callbacks and the continuation are serialized on the main queue.
  private var result: Result<CGImage, Error>?
  private var waiting: CheckedContinuation<CGImage, Error>?

  @MainActor func read(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws
    -> CGImage
  {
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
    defer { try? stream.removeStreamOutput(self, type: .screen) }
    try await stream.startCapture()
    let timeout = Task { @MainActor in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      finish(
        .failure(
          NSError(
            domain: "Glint.ScreenFrame", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("五秒内未收到完整画面，请重新选择屏幕或窗口。")])))
    }
    let frame: Result<CGImage, Error>
    do {
      if let result {
        frame = result
      } else {
        frame = .success(try await withCheckedThrowingContinuation { waiting = $0 })
      }
    } catch { frame = .failure(error) }
    timeout.cancel()
    try? await stream.stopCapture()
    return try frame.get()
  }

  private func finish(_ value: Result<CGImage, Error>) {
    guard result == nil else { return }
    result = value
    waiting?.resume(with: value)
    waiting = nil
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { self.finish(.failure(error)) }
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard result == nil, type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
      let buffer = sample.imageBuffer
    else { return }
    let frame = CIImage(cvPixelBuffer: buffer)
    guard let image = CIContext().createCGImage(frame, from: frame.extent) else { return }
    finish(.success(image))
  }
}
