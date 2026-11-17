import AppKit
import SwiftUI
import ScreenCaptureKit

enum SnipAction { case copy, pin, edit, save, preferred }
enum CropGeometry {
  // AppKit's selection uses a bottom-left origin; CGImage pixels start at top left.
  static func pixels(_ rect: CGRect, in bounds: CGRect, image: CGImage) -> CGRect {
    let r = rect.standardized.intersection(bounds)
    guard !r.isNull, bounds.width > 0, bounds.height > 0 else { return .zero }
    let sx = CGFloat(image.width) / bounds.width
    let sy = CGFloat(image.height) / bounds.height
    return CGRect(
      x: (r.minX - bounds.minX) * sx, y: (bounds.maxY - r.maxY) * sy, width: r.width * sx,
      height: r.height * sy
    ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
}
private final class AnnotationButton: NSButton {
  var hoverChanged: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); hoverChanged?(true) }
  override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hoverChanged?(false) }
}
private final class SelectionPanel: NSPanel { override var canBecomeKey: Bool { true } }
final class RegionSelection {
  private var escapeMonitor: Any?
  private var panels: [NSPanel] = []
  private(set) var editDraft: AnnotationDraft?
  private var previous: NSRunningApplication?
  private var end: ((CGImage?, SnipAction) -> Void)?
  @MainActor func begin(
    mode: CaptureMode = .region, _ completion: @escaping (CGImage?, SnipAction) -> Void
  ) async throws {
    previous = NSWorkspace.shared.frontmostApplication
    if #available(macOS 14, *), UserDefaults.standard.bool(forKey: "systemCapturePicker") {
      let capture = try await SystemCapturePicker().capture(window: mode == .window)
      guard mode == .region else {
        previous = nil
        completion(capture.image, .preferred)
        return
      }
      let filter = capture.filter
      var screen: NSScreen?
      if #available(macOS 15.2, *), let id = filter.includedDisplays.first?.displayID {
        screen = NSScreen.screens.first {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == id
        }
      }
      if screen == nil {
        screen =
          NSScreen.screens.first { candidate in
            guard
              let id = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
            else { return false }
            return CGDisplayBounds(id.uint32Value).equalTo(filter.contentRect)
          } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
      }
      guard let screen else { throw CocoaError(.fileReadUnknown) }
      showSelection(
        mode: mode, frozen: [(screen, capture.image)], targets: [], windowShot: nil, completion)
      return
    }
    guard Self.directCaptureAllowed() else {
      throw NSError(domain: SCStreamErrorDomain, code: -3801)
    }
    try await direct(mode: mode, completion)
  }
  static func directCaptureAllowed(preflight: () -> Bool = CGPreflightScreenCaptureAccess,
                                   request: () -> Bool = CGRequestScreenCaptureAccess) -> Bool {
    preflight() || request() || preflight()
  }
  static func accessDenied(_ error: Error) -> Bool {
    let e = error as NSError
    return e.domain == SCStreamErrorDomain && e.code == -3801
  }
  @MainActor private func direct(
    mode: CaptureMode, _ completion: @escaping (CGImage?, SnipAction) -> Void
  ) async throws {
    let screens = mode == .display ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
    var targets: [(id: CGWindowID, rect: CGRect)] = []
    var windowShot: ((CGWindowID) async throws -> CGImage)?
    var frozen: [(NSScreen, CGImage)] = []
    if #available(macOS 14.0, *) {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      let eligible = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen }
      let windows = Dictionary(uniqueKeysWithValues: eligible.map { ($0.windowID, $0) })
      let order =
        (CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
        ?? []
      targets = order.compactMap { entry in
        guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          let w = windows[id]
        else { return nil }
        return (id, w.frame)
      }
      windowShot = { id in
        guard let w = windows[id] else { throw CocoaError(.fileReadUnknown) }
        let f = SCContentFilter(desktopIndependentWindow: w)
        let c = SCStreamConfiguration()
        c.width = max(1, Int(f.contentRect.width * CGFloat(f.pointPixelScale)))
        c.height = max(1, Int(f.contentRect.height * CGFloat(f.pointPixelScale)))
        c.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: f, configuration: c)
      }
      for screen in screens {
        guard
          let id =
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value, let d = content.displays.first(where: { $0.displayID == id })
        else { continue }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
        cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
        cfg.showsCursor = false
        frozen.append(
          (
            screen,
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
          ))
      }
    } else {
      let info =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
      targets = info.compactMap { entry in
        guard entry[kCGWindowLayer as String] as? Int == 0,
          let id = entry[kCGWindowNumber as String] as? UInt32,
          let dict = entry[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return (id, r)
      }
      windowShot = { id in
        guard
          let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])
        else { throw CocoaError(.fileReadUnknown) }
        return cg
      }
      for screen in screens {
        if let id =
          (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value, let image = CGDisplayCreateImage(id)
        {
          frozen.append((screen, image))
        }
      }
    }
    guard !frozen.isEmpty else { throw CocoaError(.fileReadUnknown) }
    if mode == .display {
      previous = nil
      completion(frozen.first?.1, .preferred)
      return
    }
    showSelection(mode: mode, frozen: frozen, targets: targets, windowShot: windowShot, completion)
  }
  @MainActor private func showSelection(
    mode: CaptureMode, frozen: [(NSScreen, CGImage)],
    targets: [(id: CGWindowID, rect: CGRect)], windowShot: ((CGWindowID) async throws -> CGImage)?,
    _ completion: @escaping (CGImage?, SnipAction) -> Void
  ) {
    end = completion
    NSApp.activate(ignoringOtherApps: true)
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53, let self, self.panels.contains(where: { $0.isVisible }) else { return event }
      self.cancel()
      return nil
    }
    for (screen, image) in frozen {
      let p = SelectionPanel(
        contentRect: screen.frame, styleMask: [.borderless],
        backing: .buffered, defer: false)
      p.setFrame(screen.frame, display: false)
      p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
      p.isReleasedWhenClosed = false
      p.hidesOnDeactivate = false
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      p.hasShadow = false
      let view = SelectionCanvas(image: image)
      let top = NSScreen.screens.first?.frame.maxY ?? 0
      view.windows = targets.compactMap { target in
        let global = CGRect(
          x: target.rect.minX, y: top - target.rect.maxY, width: target.rect.width,
          height: target.rect.height)
        let local = global.intersection(screen.frame).offsetBy(
          dx: -screen.frame.minX, dy: -screen.frame.minY)
        return !local.isNull && local.width >= 8 && local.height >= 8 ? (target.id, local) : nil
      }
      view.windowMode = mode == .window
      if mode == .window {
        view.pickWindow = { [weak self] id in
          guard let self, let shot = windowShot, self.end != nil else { return }
          // Exclude the frozen overlay from the final window capture.
          self.panels.forEach { $0.orderOut(nil) }
          Task { @MainActor in
            do {
              let image = try await shot(id)
              self.finish(image, .preferred)
            } catch is CancellationError {
              self.finish(nil, .preferred)
            } catch {
              self.finish(nil, .preferred)
              NSAlert(error: error).runModal()
            }
          }
        }
      }
      p.acceptsMouseMovedEvents = true
      view.prepareEditor = { [weak self] draft in self?.editDraft = draft }
      view.done = { [weak self] cg, action in self?.finish(cg, action) }
      view.started = { [weak self, weak view] in
        self?.panels.compactMap { $0.contentView as? SelectionCanvas }.filter { $0 !== view }
          .forEach { $0.reset() }
      }
      p.contentView = view
      p.makeFirstResponder(view)
      panels.append(p)
      p.orderFrontRegardless()
      view.updatePointer(p.mouseLocationOutsideOfEventStream)
    }
    if let active = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first {
      active.makeKeyAndOrderFront(nil)
      active.makeFirstResponder(active.contentView)
    }
  }
  func pinActiveSelection() {
    panels.compactMap { $0.contentView as? SelectionCanvas }.first { $0.hasSelection }?
      .pinSelection()
  }

  func cancel() { finish(nil, .copy) }
  private func finish(_ image: CGImage?, _ action: SnipAction) {
    guard let callback = end else { return }
    end = nil
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    for p in panels {
      p.orderOut(nil)
      p.close()
    }
    panels = []
    if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previous.activate(options: [])
    }
    previous = nil
    callback(image, action)
    editDraft = nil
  }
}
final class SelectionCanvas: NSView, NSTextFieldDelegate {
  let frozen: CGImage
  var done: ((CGImage?, SnipAction) -> Void)?, started: (() -> Void)?
  private var start = CGPoint.zero, selection = CGRect.zero, dragging = false
  var windows: [(CGWindowID, CGRect)] = []
  var windowMode = false
  var pickWindow: ((CGWindowID) -> Void)?
  private var hovered: (CGWindowID, CGRect)?
  private var pointer: CGPoint?
  private var original = CGRect.zero
  private var grip: CGPoint?
  private var moving = false
  private var drew = false
  private var inkTool: MarkTool?
  private var marks: [Mark] = []
  var prepareEditor: ((AnnotationDraft) -> Void)?
  private var captionMove: CaptionMove?
  private var moves = CaptionMoves()
  private var pending: Mark?
  private var ink = NSColor.systemRed
  private var optionPanel: NSView?
  private var openOption: AnnotationOption?
  private var stroke = 4
  private var textField: NSTextField?
  private var anchor = CGPoint.zero
  private var editingCaption = false
  private weak var hoveredButton: AnnotationButton?
  private lazy var toolbar: NSStackView = {
    let bar = NSStackView()
    bar.appearance = NSAppearance(named: .darkAqua)
    bar.orientation = .horizontal
    bar.spacing = 2
    bar.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
    bar.wantsLayer = true
    bar.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.98).cgColor
    bar.layer?.cornerRadius = 9
    let commands =
      [("移动", "arrow.up.and.down.and.arrow.left.and.right")]
      + MarkTool.allCases.map { ($0.rawValue, $0.symbol) } + [
        ("线宽", "lineweight"), ("颜色", "circle.fill"), ("撤销", "arrow.uturn.backward"),
        ("复制", "doc.on.doc"), ("贴图", "pin"), ("保存", "square.and.arrow.down"),
        ("编辑", "slider.horizontal.3"),
      ]
    for (label, symbol) in commands {
      let b = AnnotationButton(
        image: NSImage(systemSymbolName: symbol, accessibilityDescription: L(label))
          ?? NSImage(size: NSSize(width: 14, height: 14)), target: self,
        action: #selector(toolbarPressed(_:)))
      b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
      b.identifier = NSUserInterfaceItemIdentifier(label)
      b.bezelStyle = .inline
      b.isBordered = false
      b.imagePosition = .imageOnly
      b.wantsLayer = true
      b.layer?.cornerRadius = 5
      b.widthAnchor.constraint(equalToConstant: 36).isActive = true
      b.heightAnchor.constraint(equalToConstant: 36).isActive = true
      let commands = [
        "移动": L("拖动选区调整位置（1）"), "颜色": L("选择常用色或自定义色盘"), "线宽": L("选择描边和马赛克颗粒"), "撤销": L("撤销上一次标注或移动（⌘Z）"),
        "复制": L("复制选区图像（⌘C）"), "贴图": L("将选区固定到桌面（⌘T）"), "保存": L("将选区导出为 PNG（⌘S）"), "编辑": L("在编辑器中打开选区（空格）"),
      ]
      b.toolTip = MarkTool(rawValue: label)?.hint(inSelection: true) ?? (L(label) + " · " + (commands[label] ?? ""))
      b.hoverChanged = { [weak self, weak b] inside in
        guard let self else { return }
        if inside { self.hoveredButton = b }
        else if self.hoveredButton === b { self.hoveredButton = nil }
        self.needsDisplay = true
      }
      b.setAccessibilityLabel(L(label))
      bar.addArrangedSubview(b)
    }
    return bar
  }()
  @objc private func toolbarPressed(_ b: NSButton) {
    commitCaption()
    guard let label = b.identifier?.rawValue else { return }
    if let option = AnnotationOption(rawValue: label) {
      let previous = openOption
      closeOptions()
      if previous != option { showOptions(option, at: b) }
      return
    }
    closeOptions()
    if let t = MarkTool(rawValue: label) {
      inkTool = t
    } else {
      switch label {
      case "移动": inkTool = nil
      case "撤销": undo()
      case "复制": accept(.copy)
      case "贴图": accept(.pin)
      case "保存": accept(.save)
      case "编辑": accept(.edit)
      default: break
      }
    }
    needsDisplay = true
    window?.makeFirstResponder(self)
  }
  private func closeOptions() {
    guard let panel = optionPanel else { return }
    panel.removeFromSuperview()
    optionPanel = nil
    openOption = nil
    window?.makeFirstResponder(self)
    needsDisplay = true
  }
  private func showOptions(_ option: AnnotationOption, at button: NSButton) {
    let view = NSHostingView(rootView: AnnotationOptions(option, width: stroke, current: ink) { [weak self] value in
      self?.stroke = value
      self?.closeOptions()
    } chooseColor: { [weak self] color in
      self?.ink = color
      self?.closeOptions()
    })
    let size = view.fittingSize
    let anchor = button.convert(button.bounds, to: self)
    let x = max(0, min(bounds.maxX - size.width, anchor.midX - size.width / 2))
    let y = toolbar.frame.minY >= size.height + 5 ? toolbar.frame.minY - size.height - 5 : min(bounds.maxY-size.height, toolbar.frame.maxY+5)
    view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    view.wantsLayer = true
    view.layer?.cornerRadius = 10
    view.layer?.masksToBounds = true
    optionPanel = view
    openOption = option
    addSubview(view)
    needsDisplay = true
  }
  private func beginCaption(at p: CGPoint) {
    commitCaption()
    anchor = normalized(p)
    let f = NSTextField(
      frame: CGRect(
        x: min(p.x, max(0, bounds.maxX - 180)), y: max(0, p.y - 24), width: min(180, bounds.width),
        height: 24))
    f.placeholderString = L("输入文字，回车确认")
    f.delegate = self
    addSubview(f)
    textField = f
    editingCaption = true
    window?.makeFirstResponder(f)
  }
  private func commitCaption(cancel: Bool = false) {
    guard editingCaption, let f = textField else { return }
    editingCaption = false
    textField = nil
    if !cancel, !f.stringValue.isEmpty {
      marks.append(
        Mark(
          tool: .text, color: ink.cgColor, points: [anchor], strokeFraction: strokeFraction,
          caption: f.stringValue))
    }
    f.removeFromSuperview()
    needsDisplay = true
  }
  func controlTextDidEndEditing(_ obj: Notification) { commitCaption() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
    if command == #selector(NSResponder.cancelOperation(_:))
      || command == #selector(NSResponder.insertNewline(_:))
    {
      commitCaption(cancel: command == #selector(NSResponder.cancelOperation(_:)))
      window?.makeFirstResponder(self)
      return true
    }
    return false
  }
  private var strokeFraction: CGFloat {
    let pixels = CropGeometry.pixels(selection, in: bounds, image: frozen)
    return CGFloat(stroke) / max(1, min(pixels.width, pixels.height))
  }
  var hasSelection: Bool { selection.width >= 2 && selection.height >= 2 }
  func pinSelection() { accept(.pin) }
  private lazy var bitmap = NSBitmapImageRep(cgImage: frozen)
  private var handles: [(CGPoint, CGPoint)] {
    [0.0, 0.5, 1.0].flatMap { x in
      [0.0, 0.5, 1.0].compactMap { y in
        guard x != 0.5 || y != 0.5 else { return nil }
        return (
          CGPoint(
            x: selection.minX + x * selection.width, y: selection.minY + y * selection.height),
          CGPoint(x: x, y: y)
        )
      }
    }
  }
  init(image: CGImage) {
    frozen = image
    super.init(frame: .zero)
    toolbar.isHidden = true
    addSubview(toolbar)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
  func reset() {
    closeOptions()
    commitCaption(cancel: true)
    selection = .zero
    marks = []; moves = CaptionMoves(); captionMove = nil
    pending = nil
    inkTool = nil
    dragging = false
    needsDisplay = true
  }
  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.draw(frozen, in: bounds)
    let shade = NSBezierPath(rect: bounds)
    shade.appendRect(selection.isEmpty ? hovered?.1 ?? .zero : selection)
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.44).setFill()
    shade.fill()
    let style: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    ]
    toolbar.isHidden = !hasSelection || dragging
    if selection.isEmpty, let hovered {
      NSColor(ScopeTheme.labelAccent).setStroke()
      NSBezierPath(rect: hovered.1).stroke()
    }
    if selection.width >= 2 && selection.height >= 2 {
      NSColor(ScopeTheme.labelAccent).setStroke()
      let outline = NSBezierPath(rect: selection)
      outline.lineWidth = 1.5
      outline.stroke()
      ctx.saveGState()
      ctx.clip(to: selection)
      ctx.translateBy(x: selection.minX, y: selection.maxY)
      ctx.scaleBy(x: 1, y: -1)
      for mark in marks { mark.draw(ctx, size: selection.size) }
      pending?.draw(ctx, size: selection.size)
      captionMove?.outline(ctx, marks: marks, size: selection.size)
      ctx.restoreGState()
      for (point, _) in handles where marks.isEmpty {
        NSColor.white.setFill()
        NSBezierPath(
          roundedRect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6), xRadius: 1,
          yRadius: 1
        ).fill()
      }
      let pixels = CropGeometry.pixels(selection, in: bounds, image: frozen)
      let title = "\(Int(pixels.width)) × \(Int(pixels.height)) px" as NSString
      let size = title.size(withAttributes: style)
      let top = NSRect(
        x: min(selection.minX, bounds.maxX - size.width - 17),
        y: min(bounds.maxY - 24, selection.maxY + 4), width: size.width + 14, height: 22)
      NSColor.black.withAlphaComponent(0.85).setFill()
      NSBezierPath(roundedRect: top, xRadius: 6, yRadius: 6).fill()
      title.draw(at: NSPoint(x: top.minX + 7, y: top.minY + 3), withAttributes: style)
      if !dragging {
        let width = toolbar.fittingSize.width
        let y =
          selection.minY > 48 ? selection.minY - 46 : min(bounds.maxY - 44, selection.maxY + 4)
        toolbar.frame = CGRect(
          x: max(2, min(selection.maxX - width, bounds.maxX - width - 2)), y: y, width: width,
          height: 42)
        if optionPanel == nil, let b = hoveredButton, let hint = b.toolTip {
          let text = hint as NSString
          let size = text.size(withAttributes: style)
          let mid = b.convert(b.bounds, to: self).midX
          let box = CGRect(x: max(3, min(bounds.maxX - size.width - 19, mid - size.width / 2 - 8)),
            y: y >= 32 ? y - 29 : toolbar.frame.maxY + 3, width: size.width + 16, height: 26)
          NSColor(white: 0.10, alpha: 0.98).setFill()
          NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
          text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 5), withAttributes: style)
        }
        for case let b as NSButton in toolbar.arrangedSubviews {
          let label = b.identifier?.rawValue
          let selected = label == (inkTool?.rawValue ?? "移动")
          b.layer?.backgroundColor = selected ? NSColor(white: 0.32, alpha: 1).cgColor : nil
          b.contentTintColor = label == "颜色" ? ink : .white
          if label == "撤销" { b.isEnabled = !marks.isEmpty }
          if label == "线宽" {
            b.toolTip = L("线宽 · ") + String(stroke) + L(" px（点击选择）")
            b.setAccessibilityValue(String(stroke) + " px")
          }
        }
      }
    } else {
      let label =
        (windowMode
        ? L("点击窗口截图     Esc 取消")
        : (windows.isEmpty
          ? L("拖动选区域   ·   C 复制颜色   ·   Esc 取消") : L("点击选窗口   ·   拖动选区域   ·   C 复制颜色   ·   Esc 取消")))
        as NSString
      let width = label.size(withAttributes: style).width + 28
      let box = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 77, width: width, height: 32)
      NSColor.black.withAlphaComponent(0.8).setFill()
      NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
      label.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 8), withAttributes: style)
    }
    if let pointer, selection.isEmpty || dragging && !moving && pending == nil {
      let sx = CGFloat(frozen.width) / max(1, bounds.width)
      let sy = CGFloat(frozen.height) / max(1, bounds.height)
      let pixel = CGPoint(x: floor(pointer.x * sx), y: floor((bounds.maxY - pointer.y) * sy))
      let rect = CGRect(
        x: max(4, min(pointer.x + 22, bounds.maxX - 92)),
        y: max(4, min(pointer.y + 22, bounds.maxY - 103)), width: 84, height: 84)
      let patch = CGRect(
        x: min(max(0, pixel.x - 7), CGFloat(frozen.width) - 15),
        y: min(max(0, pixel.y - 7), CGFloat(frozen.height) - 15), width: 15, height: 15)
      if let cg = frozen.cropping(to: patch) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: rect)
        ctx.restoreGState()
        NSColor.white.setStroke()
        NSBezierPath(rect: rect).stroke()
        let cell = rect.width / 15
        NSBezierPath(
          rect: CGRect(
            x: rect.minX + (pixel.x - patch.minX) * cell,
            y: rect.maxY - (pixel.y - patch.minY + 1) * cell, width: cell, height: cell)
        ).stroke()
        let strip = CGRect(x: rect.minX, y: rect.minY - 16, width: rect.width, height: 16)
        NSColor.black.setFill()
        strip.fill()
        (hex(at: pointer) as NSString).draw(at: strip.origin, withAttributes: style)
      }
    }
  }
  private func accept(_ action: SnipAction) {
    commitCaption()
    let r = CropGeometry.pixels(selection, in: bounds, image: frozen)
    if r.width >= 2, r.height >= 2, let cg = frozen.cropping(to: r) {
      if marks.isEmpty {
        done?(cg, action)
      } else if let drawn = try? ImageEditor.composite(cg, marks: marks) {
        if action == .edit {
          prepareEditor?(AnnotationDraft(image: cg, marks: marks, moves: moves))
        }
        done?(drawn, action)
      }
    } else {
      NSSound.beep()
    }
  }
  override func mouseDown(with e: NSEvent) {
    if optionPanel != nil { closeOptions(); return }
    window?.makeKey()
    window?.makeFirstResponder(self)
    let p = convert(e.locationInWindow, from: nil)
    if !windowMode, selection.contains(p), inkTool == .text || inkTool == nil,
      let move = CaptionMove(marks: marks, touch: normalized(p), size: selection.size)
    {
      captionMove = move; needsDisplay = true; return
    }
    if inkTool == .text, selection.contains(p) {
      beginCaption(at: p)
      return
    }
    if e.clickCount == 2 && selection.contains(p) {
      accept(.preferred)
      return
    }
    started?()
    pointer = p
    start = p
    original = selection
    drew = false
    dragging = true
    hovered = windows.first { $0.1.contains(p) }
    grip =
      !selection.isEmpty && marks.isEmpty
      ? handles.first { hypot($0.0.x - p.x, $0.0.y - p.y) < 7 }?.1 : nil
    moving = grip == nil && selection.contains(p) && inkTool == nil
    if let tool = inkTool, grip == nil, selection.contains(p) {
      pending = Mark(
        tool: tool, color: ink.cgColor, points: [normalized(p)], strokeFraction: strokeFraction)
      if tool == .mosaic {
        let r = CropGeometry.pixels(selection, in: bounds, image: frozen)
        if let crop = frozen.cropping(to: r) {
          pending?.texture = try? ImageEditor.mosaicTexture(
            crop, previous: marks, blockSize: stroke * 4)
        }
        if pending?.texture == nil {
          pending = nil
          dragging = false
          NSSound.beep()
        }
      }
    } else if !moving && grip == nil {
      selection = .zero
      marks = []; moves = CaptionMoves(); captionMove = nil
      inkTool = nil
    }
    needsDisplay = true
  }
  private func normalized(_ p: CGPoint) -> CGPoint {
    CGPoint(
      x: min(1, max(0, (p.x - selection.minX) / selection.width)),
      y: min(1, max(0, (selection.maxY - p.y) / selection.height)))
  }
  override func mouseMoved(with e: NSEvent) {
    updatePointer(convert(e.locationInWindow, from: nil))
  }
  func updatePointer(_ p: CGPoint) {
    pointer = bounds.contains(p) ? p : nil
    hovered = windows.first { $0.1.contains(p) }
    needsDisplay = true
  }
  private func hex(at p: CGPoint) -> String {
    let x = min(frozen.width - 1, max(0, Int(p.x / max(1, bounds.width) * CGFloat(frozen.width))))
    let y = min(
      frozen.height - 1,
      max(0, Int((bounds.maxY - p.y) / max(1, bounds.height) * CGFloat(frozen.height))))
    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "—" }
    return String(
      format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
  }
  override func mouseDragged(with e: NSEvent) {
    if let captionMove {
      captionMove.update(&marks, to: normalized(convert(e.locationInWindow, from: nil)));
      needsDisplay = true; return
    }
    guard dragging, !windowMode else { return }
    let point = convert(e.locationInWindow, from: nil)
    let p = CGPoint(x: min(bounds.maxX, max(0, point.x)), y: min(bounds.maxY, max(0, point.y)))
    pointer = p
    drew = drew || hypot(p.x - start.x, p.y - start.y) > 2
    if pending != nil {
      if inkTool == .pen {
        pending?.points.append(normalized(p))
      } else {
        pending?.points = [normalized(start), normalized(p)]
      }
    } else if moving {
      let x = max(0, min(bounds.width - original.width, original.minX + p.x - start.x))
      let y = max(0, min(bounds.height - original.height, original.minY + p.y - start.y))
      selection = CGRect(origin: CGPoint(x: x, y: y), size: original.size)
    } else if let grip {
      let x0 = grip.x == 0 ? min(p.x, original.maxX - 2) : original.minX
      let y0 = grip.y == 0 ? min(p.y, original.maxY - 2) : original.minY
      let x1 = grip.x == 1 ? max(p.x, original.minX + 2) : original.maxX
      let y1 = grip.y == 1 ? max(p.y, original.minY + 2) : original.maxY
      selection = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    } else {
      selection = CGRect(
        x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x),
        height: abs(start.y - p.y))
    }
    needsDisplay = true
  }
  private func refreshMosaics() {
    guard marks.contains(where: { $0.tool == .mosaic }),
      let crop = frozen.cropping(to: CropGeometry.pixels(selection, in: bounds, image: frozen))
    else { return }
    ImageEditor.refreshMosaics(&marks, source: crop)
  }
  private func undo() {
    captionMove = nil
    if moves.undo(&marks) { refreshMosaics() }
    needsDisplay = true
  }
  override func mouseUp(with e: NSEvent) {
    if let captionMove {
      captionMove.update(&marks, to: normalized(convert(e.locationInWindow, from: nil)))
      moves.finish(captionMove, in: marks); self.captionMove = nil; refreshMosaics();
      needsDisplay = true; return
    }
    guard dragging else { return }
    dragging = false
    if moving && selection != original { refreshMosaics() }
    if windowMode, let hovered {
      pickWindow?(hovered.0)
      return
    }
    if let pending {
      marks.append(pending)
      self.pending = nil
    } else if !drew && selection.isEmpty {
      selection = hovered?.1 ?? .zero
    }
    needsDisplay = true
  }
  override func rightMouseDown(with event: NSEvent) {
    if !selection.isEmpty { reset() } else { done?(nil, .copy) }
  }
  override func keyDown(with e: NSEvent) {
    if e.keyCode == 53 {
      done?(nil, .copy)
      return
    }
    if e.modifierFlags.contains(.command) {
      switch e.charactersIgnoringModifiers?.lowercased() {
      case "s":
        accept(.save)
        return
      case "z":
        undo()
        needsDisplay = true
        return
      case "t":
        accept(.pin)
        return
      case "c":
        accept(.copy)
        return
      case "a":
        started?()
        selection = bounds
        refreshMosaics()
        needsDisplay = true
        return
      default: break
      }
    }
    if e.charactersIgnoringModifiers?.lowercased() == "c", let p = pointer {
      let text = hex(at: p)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      done?(nil, .copy)
      return
    }
    if hasSelection, let key = e.charactersIgnoringModifiers.flatMap(Int.init),
      (1...9).contains(key)
    {
      inkTool =
        ([nil, .pen, .arrow, .box, .redact, .circle, .ellipse, .text, .mosaic] as [MarkTool?])[
          key - 1]
      needsDisplay = true
      return
    }
    switch e.keyCode {
    case 36, 76: accept(.copy)
    case 49: accept(.edit)
    case 123...126:
      let step: CGFloat =
        (e.modifierFlags.contains(.shift) ? 10 : 1) * bounds.width / CGFloat(frozen.width)
      let moved = selection.offsetBy(
        dx: e.keyCode == 123 ? -step : e.keyCode == 124 ? step : 0,
        dy: e.keyCode == 125 ? -step : e.keyCode == 126 ? step : 0)
      if bounds.contains(moved) {
        selection = moved
        refreshMosaics()
        needsDisplay = true
      }
    default: super.keyDown(with: e)
    }
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if optionPanel != nil || editingCaption { return super.performKeyEquivalent(with: event) }
    if event.modifierFlags.contains(.command),
      ["a", "t", "c", "s", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
    {
      keyDown(with: event)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
