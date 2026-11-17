import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Shot: Identifiable, Equatable {
  var id: URL { url }
  let url: URL
  let date: Date
  let pixels: CGSize
  var title: String { L("截图 ") + date.formatted(date: .omitted, time: .standard) }
  func thumbnail(_ size: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: size,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    return cg
  }
}
enum CaptureMode: String, CaseIterable {
  case region, window, display
  var name: String {
    switch self {
    case .region: return L("区域截图")
    case .window: return L("窗口截图")
    case .display: return L("全屏截图")
    }
  }
  var symbol: String {
    switch self {
    case .region: return "viewfinder"
    case .window: return "macwindow"
    case .display: return "display"
    }
  }
  var flags: [String] {
    switch self {
    case .region: return ["-i", "-s"]
    case .window: return ["-i", "-w"]
    case .display: return ["-D", "1"]
    }
  }
}
final class Captures: ObservableObject {
  @Published var shots: [Shot] = []
  @Published var capturing = false
  @Published var notice: String?
  private let folder: URL
  init(folder: URL? = nil) {
    self.folder =
      folder
      ?? perchSupportFolder().appendingPathComponent("Captures", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
      let urls = try FileManager.default.contentsOfDirectory(
        at: self.folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
      shots = urls.filter { $0.pathExtension.lowercased() == "png" }.compactMap(Self.metadata)
        .sorted { $0.date > $1.date }
    } catch { notice = L("无法打开截图目录 · ") + error.localizedDescription }
  }
  static func metadata(_ url: URL) -> Shot? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    return Shot(url: url, date: date, pixels: CGSize(width: width, height: height))
  }
  @discardableResult func add(_ data: Data) throws -> Shot {
    let url = folder.appendingPathComponent(UUID().uuidString + ".png")
    try data.write(to: url, options: .atomic)
    guard let shot = Self.metadata(url) else {
      try? FileManager.default.removeItem(at: url)
      throw CocoaError(.fileReadCorruptFile)
    }
    shots.insert(shot, at: 0)
    return shot
  }
  func importImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    var count = 0
    var failed: [String] = []
    for url in panel.urls {
      do {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileReadCorruptFile) }
        try add(png)
        count += 1
      } catch { failed.append(url.lastPathComponent) }
    }
    notice = Lf("已导入 %@ 张图像", String(describing: count)) + (failed.isEmpty ? "" : L(" · 读取失败：") + failed.joined(separator: "、"))
  }
  func openFolder() { NSWorkspace.shared.open(folder) }
  func reveal(_ shot: Shot) {
    NSWorkspace.shared.activateFileViewerSelecting([shot.url])
  }
  func remove(_ shot: Shot) {
    do {
      try FileManager.default.removeItem(at: shot.url)
      shots.removeAll { $0.id == shot.id }
    } catch { notice = error.localizedDescription }
  }
  func copy(_ shot: Shot) {
    guard let image = NSImage(contentsOf: shot.url) else {
      notice = L("无法读取截图")
      return
    }
    NSPasteboard.general.clearContents()
    notice = NSPasteboard.general.writeObjects([image]) ? L("截图已复制") : L("写入剪贴板失败")
  }
  func export(_ shot: Shot) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = shot.title.replacingOccurrences(of: ":", with: "-") + ".png"
    if panel.runModal() == .OK, let url = panel.url {
      do {
        try Data(contentsOf: shot.url).write(to: url, options: .atomic)
        notice = L("已导出 PNG")
      } catch { notice = error.localizedDescription }
    }
  }

}
final class PinPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53
      || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w")
    {
      close()
      return
    }
    if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
      (contentView as? PinnedImage)?.copyImage()
      return
    }
    if (123...126).contains(event.keyCode) {
      let step = 1 / (screen?.backingScaleFactor ?? 1)
      setFrameOrigin(
        NSPoint(
          x: frame.minX + (event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0),
          y: frame.minY + (event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0)))
      return
    }
    super.keyDown(with: event)
  }
}
final class PinBoard: NSObject, NSWindowDelegate, ObservableObject {
  @Published private(set) var count = 0
  private var panels: [PinPanel] = []
  static func clipboardImage() -> NSImage? {
    if let image = NSImage(pasteboard: .general) { return image }
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
      return nil
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: String(text.prefix(12000)), attributes: attrs)
    let content = str.boundingRect(
      with: NSSize(width: 490, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).integral
    let size = NSSize(width: max(70, content.width + 28), height: content.height + 28)
    return NSImage(size: size, flipped: false) { box in
      NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.21, alpha: 1).setFill()
      box.fill()
      str.draw(
        with: box.insetBy(dx: 14, dy: 14), options: [.usesLineFragmentOrigin, .usesFontLeading])
      return true
    }
  }
  func toggleVisibility() {
    if panels.contains(where: { $0.isVisible }) {
      panels.forEach { $0.orderOut(nil) }
    } else {
      panels.forEach { $0.orderFrontRegardless() }
    }
  }
  func pin(_ image: NSImage) {
    let screen =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
    let scale = min(
      1,
      min(
        visible.width * 0.55 / max(image.size.width, 1),
        visible.height * 0.60 / max(image.size.height, 1)))
    let size = NSSize(
      width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    let panel = PinPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .resizable, .borderless], backing: .buffered, defer: false)
    panel.identifier = NSUserInterfaceItemIdentifier("scope.pin")
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.aspectRatio = size
    panel.minSize = NSSize(width: min(size.width, 64), height: min(size.height, 64))
    panel.delegate = self
    panel.hasShadow = true
    let view = PinnedImage(frame: NSRect(origin: .zero, size: size))
    view.image = image
    view.imageScaling = .scaleProportionallyUpOrDown
    panel.contentView = view
    let shift = CGFloat(panels.count % 5) * 18
    panel.setFrameOrigin(
      NSPoint(x: visible.midX - size.width / 2 + shift, y: visible.midY - size.height / 2 - shift))
    panels.append(panel)
    count = panels.count
    panel.makeKeyAndOrderFront(nil)
  }
  func closeAll() { for p in Array(panels) { p.close() } }
  func windowWillClose(_ notification: Notification) {
    panels.removeAll { $0 === notification.object as? NSWindow }
    count = panels.count
  }
}
private final class PinnedImage: NSImageView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.close() } else { window?.performDrag(with: event) }
  }
  override func scrollWheel(with event: NSEvent) {
    guard let w = window else { return }
    let f = w.frame
    let scale = exp(max(-0.15, min(0.15, event.scrollingDeltaY * 0.012)))
    let width = f.width * scale
    let height = f.height * scale
    guard min(width, height) > 28, max(width, height) < 5000 else { return }
    w.setFrame(
      NSRect(x: f.midX - width / 2, y: f.midY - height / 2, width: width, height: height),
      display: true)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let m = NSMenu()
    for (name, action) in [
      (L("复制图像"), #selector(copyImage)), (L("切换半透明"), #selector(toggleAlpha)),
      (L("关闭贴图"), #selector(closePin)),
    ] {
      m.addItem(withTitle: name, action: action, keyEquivalent: "").target = self
    }
    return m
  }
  @objc func copyImage() {
    if let image {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
  }
  @objc func toggleAlpha() { if let w = window { w.alphaValue = w.alphaValue < 0.99 ? 1 : 0.55 } }
  @objc func closePin() { window?.close() }
}
