import Carbon
import Combine
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
  case overview = "工作台"
  case monitor = "系统监控"
  case usage = "AI 用量"
  case gallery = "截图库"
  case todos = "待办"
  case clipboard = "剪贴板"
  case settings = "偏好设置"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .overview: return "square.grid.2x2"
    case .monitor: return "waveform.path.ecg"
    case .usage: return "chart.bar.xaxis"
    case .gallery: return "photo.stack"
    case .todos: return "checklist"
    case .clipboard: return "list.clipboard"
    case .settings: return "slider.horizontal.3"
    }
  }
}
final class Studio: ObservableObject {
  let monitor = Monitor()
  let usage: UsageStore
  let captures: Captures
  let awake = AwakeSession()
  let todos: TodoStore
  let clips: ClipboardHistory
  lazy var clipChooser = ClipChooser(store:clips)
  var requestReminderAccess: () -> Void = {}
  let pins = PinBoard()
  let keys = HotKeys()
  let navigation = PanelNavigation()
  private let selector = RegionSelection()
  var detailedMetric: Metric?
  @Published var workspaceVisible = true
  @Published var page = Page.overview
  var editDraft: AnnotationDraft?
  @Published var edit: Shot?
  @Published var inspected: Shot?
  var open: () -> Void = {}
  var dismissQuick: () -> Void = {}
  var updateMenuPreferences: () -> Void = {}
  private var sampler: NSColorSampler?
  init(captures: Captures = Captures(), usage: UsageStore = UsageStore(), todos: TodoStore = TodoStore(),
       clips: ClipboardHistory = ClipboardHistory()) {
    self.clips = clips
    self.todos = todos
    self.captures = captures
    self.usage = usage
  }
  func take(_ mode: CaptureMode) {
    dismissQuick()
    guard !captures.capturing else { return }
    captures.notice = nil
    captures.capturing = true
    Task { @MainActor in
      do {
        try await selector.begin(mode: mode) { [weak self] cg, action in
          guard let self else { return }
          self.captures.capturing = false
          guard let cg else { return }
          do {
            guard
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            self.accept(try self.captures.add(png), action)
          } catch {
            self.captures.notice = error.localizedDescription
            self.open()
          }
        }
      } catch is CancellationError {
        captures.capturing = false
      } catch {
        captures.capturing = false
        if RegionSelection.accessDenied(error) {
          page = .settings
          captures.notice = L("直接截图需要屏幕录制权限。请允许「Perch」访问屏幕，按系统提示重新打开。")
        } else {
          captures.notice = L("未能完成截图 · ") + error.localizedDescription
        }
        open()
      }
    }
  }
  private func accept(_ shot: Shot, _ action: SnipAction) {
    switch action {
    case .copy: captures.copy(shot)
    case .pin: pin(shot)
    case .save: captures.export(shot)
    case .edit:
      open()
      editDraft = selector.editDraft
      edit = shot
    case .preferred:
      switch UserDefaults.standard.string(forKey: "afterCapture") {
      case "copy": self.captures.copy(shot)
      case "pin": self.pin(shot)
      default:
        self.open()
        self.inspected = shot
      }
    }
  }
  func pin(_ shot: Shot) {
    guard let image = NSImage(contentsOf: shot.url) else {
      captures.notice = L("无法打开图像")
      return
    }
    pins.pin(image)
    captures.notice = L("已贴到桌面")
  }
  func captureShortcut() {
    if captures.capturing { selector.cancel() } else { take(.region) }
  }
  func pasteShortcut() {
    if captures.capturing { selector.pinActiveSelection() } else { pinClipboard() }
  }
  func pinClipboard() {
    dismissQuick()
    guard let image = PinBoard.clipboardImage() else {
      open()
      captures.notice = L("剪贴板中没有可贴出的图像或文字")
      return
    }
    pins.pin(image)
  }
  func pickColor() {
    dismissQuick()
    sampler = NSColorSampler()
    sampler?.show { [weak self] color in
      defer { self?.sampler = nil }
      guard let c = color?.usingColorSpace(.sRGB) else { return }
      let value = String(
        format: "#%02X%02X%02X", Int((255 * c.redComponent).rounded()),
        Int((255 * c.greenComponent).rounded()), Int((255 * c.blueComponent).rounded()))
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
      self?.captures.notice = L("已复制颜色 ") + value
    }
  }
}
private struct StatusPreferences: Equatable {
  let layout = UserDefaults.standard.string(forKey: "menuLayout") ?? "dual"
  let usage = UserDefaults.standard.bool(forKey: "menuUsage")
  let hover = UserDefaults.standard.bool(forKey: "hoverPreview")
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
  var studio: Studio!
  private let popover = NSPopover()
  private lazy var statusAppearance = StatusAppearance(popover: popover)
  private var networkItem: NSStatusItem!, pinSubscription: AnyCancellable?
  private var anchor: InstrumentTab?
  private var usageItem: NSStatusItem!
  private var usageSubscription: AnyCancellable?
  private var awakeItem: NSStatusItem!
  private var awakeSubscription: AnyCancellable?
  private var tracking: [(NSView, NSTrackingArea)] = []
  private var hoverTimer: Timer?
  private var peeking = false
  private var window: NSWindow!, item: NSStatusItem!, subscription: AnyCancellable?
  private var notes: TodoNotes!
  private var reminders: TodoReminders!
  private var showingStatusMenu = false
  private var activationObserver: NSObjectProtocol?
  private var appliedPreferences: StatusPreferences?
  func applicationDidFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.register(defaults: [
      "interval": 2.0, "hoverPreview": true, "afterCapture": "preview",
    ])
    studio = Studio()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 690),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.identifier = NSUserInterfaceItemIdentifier("scope.workspace")
    window.title = L("Perch")
    window.backgroundColor = NSColor(ScopeTheme.canvas)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.minSize = NSSize(width: 820, height: 590)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("ScopeBarWorkspace")
    studio.open = { [weak self] in self?.show() }
    studio.dismissQuick = { [weak self] in self?.popover.performClose(nil) }
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    networkItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    usageItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    awakeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    awakeItem.button?.target = self
    awakeItem.button?.action = #selector(awakeClicked(_:))
    awakeItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    awakeSubscription = studio.awake.$active.combineLatest(studio.awake.$endsAt).sink { [weak self] active, end in
      let title = Self.awakeTitle(active, end)
      let button = self?.awakeItem.button
      button?.image = NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                              accessibilityDescription: title)
      button?.toolTip = title
      button?.setAccessibilityLabel(title)
    }
    usageItem.button?.target = self
    usageItem.button?.toolTip = L("Perch · 今日 Token 用量")
    usageSubscription = studio.usage.$rows.combineLatest(studio.usage.$tool).sink {
      [weak self] rows, tool in
      let count = tool.filter(rows).filter { Calendar.current.isDateInToday($0.date) }.reduce(0) {
        $0 + $1.total
      }
      self?.usageItem.button?.toolTip = L("Perch · ") + L(tool.rawValue) + L(" · 今日 Token")
      self?.usageItem.button?.image = StatusInk.draw(tool.menuLabel, shortTokens(count), width: 45)
    }
    for (status, tip) in [
      (item!, L("Perch · 硬件")),
      (networkItem!, L("Perch · 网络")),
    ] {
      status.button?.target = self
      status.button?.toolTip = tip
      status.button?.setAccessibilityLabel(tip)
    }
    _ = statusAppearance
    popover.animates = false
    popover.behavior = .transient
    popover.delegate = self
    pinSubscription = studio.navigation.$pinned.sink { [weak self] pinned in
      self?.popover.behavior = pinned ? .applicationDefined : .transient
    }
    subscription = studio.monitor.$samples.sink { [weak self] samples in
      self?.refreshItem(samples.last)
    }
    studio.updateMenuPreferences = { [weak self] in self?.applyMenuPreferences() }
    applyMenuPreferences()
    notes = TodoNotes(store:studio.todos)
    reminders = TodoReminders(store:studio.todos)
    notes.requestReminderAccess = { [weak self] in self?.reminders.update(requestAccess:true) }
    reminders.show = { [weak self] id in
      self?.showTodos()
      if let id, let task = self?.studio.todos.items.first(where:{ $0.id == id }) { self?.studio.todos.editing = task }
    }
    studio.todos.didChange = { [weak self] in
      self?.notes.refresh()
      self?.reminders.update()
    }
    studio.requestReminderAccess = { [weak self] in self?.reminders.update(requestAccess:true) }
    notes.refresh()
    reminders.update()
    activationObserver = NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:NSApp,queue:.main) { [weak self] _ in
      Task { @MainActor in if self?.studio.todos.notificationBlocked == true { self?.reminders.update() } }
    }
    studio.clips.start()
    studio.clipChooser.manage = { [weak self] in self?.studio.page = .clipboard; self?.show() }
    for status in [item,networkItem,usageItem] {
      status?.button?.action = #selector(statusClicked(_:))
      status?.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
    }
    studio.keys.action = { [weak self] a in
      switch a {
      case .capture: self?.studio.captureShortcut()
      case .paste: self?.studio.pasteShortcut()
      case .togglePins: self?.studio.pins.toggleVisibility()
      case .clipboard: self?.showClipboard()
      }
    }
    studio.keys.install()
    setupMenu()
    studio.monitor.start()
    show()
  }
  private func applyMenuPreferences() {
    let settings = StatusPreferences()
    guard appliedPreferences != settings else { return }
    // Cache first. Setting NSStatusItem.isVisible can synchronously write AppKit defaults.
    if settings.usage != (appliedPreferences?.usage ?? false) {
      if settings.usage { studio.usage.start() } else { studio.usage.stop() }
    }
    appliedPreferences = settings
    let showsNetwork = settings.layout == "dual" || settings.layout == "network"
    let showsHardware = settings.layout != "network"
    if item.isVisible != showsHardware { item.isVisible = showsHardware }
    if networkItem.isVisible != showsNetwork { networkItem.isVisible = showsNetwork }
    if usageItem.isVisible != settings.usage { usageItem.isVisible = settings.usage }
    configureHover()
    refreshItem(studio.monitor.current)
  }
  func refreshItem(_ r: Reading?) {
    let pref = UserDefaults.standard.string(forKey: "menuLayout") ?? "dual"
    let cpu = StatusInk.hardware(r)
    let up = rateNumber(r?.values[.upload])
    let down = rateNumber(r?.values[.download])
    if pref == "icon" {
      item.button?.image = NSImage(
        systemSymbolName: "waveform.path.ecg", accessibilityDescription: L("系统监控"))
    } else {
      item.button?.image = StatusInk.draw("CPU", cpu, width: 31)
    }
    networkItem.button?.image = StatusInk.draw(
      "↑ " + up.0 + " " + up.1, "↓ " + down.0 + " " + down.1, width: 61)
    item.button?.setAccessibilityLabel(L("Perch硬件 CPU ") + cpu)
    networkItem.button?.setAccessibilityLabel(L("Perch网络 上传 ") + up.0 + up.1 + L(" 下载 ") + down.0 + down.1)
  }
  func show() {
    popover.performClose(nil)
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    NSApp.activate(ignoringOtherApps: true)
    if !(window.contentView is NSHostingView<Workspace>) {
      window.contentView = NSHostingView(rootView: Workspace(studio: studio, captures: studio.captures))
    }
    window.makeKeyAndOrderFront(nil)
  }
  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let w = notification.object as? NSWindow, w === window else { return }
    let visible = w.occlusionState.contains(.visible)
    if studio.workspaceVisible != visible { studio.workspaceVisible = visible }
  }
  func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === window else { return }
    window.contentView = nil
    studio.workspaceVisible = false
    NSApp.setActivationPolicy(.accessory)
  }
  func popoverDidClose(_ notification: Notification) {
    if !popover.isShown { popover.contentViewController = nil }
  }
  private var hoverCandidate: InstrumentTab?
  private var candidateSince = 0.0
  private var lastInside = 0.0
  private var suppressed: InstrumentTab?
  private func configureHover() {
    for (view, area) in tracking { view.removeTrackingArea(area) }
    tracking.removeAll()
    hoverCandidate = nil
    suppressed = nil
    guard appliedPreferences?.hover == true else {
      hoverTimer?.invalidate()
      hoverTimer = nil
      if peeking && !studio.navigation.pinned { popover.performClose(nil) }
      peeking = false
      return
    }
    for status in [item, networkItem, usageItem] {
      guard let status, status.isVisible, let button = status.button else { continue }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
      button.addTrackingArea(area)
      tracking.append((button, area))
    }
    // Menu-bar windows are hosted by macOS. An entry event can be missed after a
    // Space or layout change. Keep sampling independent of tracking-area delivery.
    guard hoverTimer == nil else { return }
    let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in self?.pollPointer() }
    timer.tolerance = 0.035
    RunLoop.main.add(timer, forMode: .common)
    hoverTimer = timer
  }
  @objc func mouseEntered(with event: NSEvent) { pollPointer() }
  @objc func mouseExited(with event: NSEvent) { pollPointer() }
  private func pollPointer() {
    guard appliedPreferences?.hover == true, !studio.captures.capturing, !showingStatusMenu,
          !(studio.navigation.pinned && popover.isShown) else { return }
    let pointer = NSEvent.mouseLocation
    let now = ProcessInfo.processInfo.systemUptime
    let hit = [(item, InstrumentTab.hardware), (networkItem, .network), (usageItem, .usage)].first {
      pair in
      guard let item = pair.0, item.isVisible, let b = item.button, let w = b.window,
        !b.bounds.isEmpty
      else { return false }
      var frame = w.convertToScreen(b.convert(b.bounds, to: nil))
      frame.size.height += 1 // Include the topmost screen edge.
      return frame.contains(pointer)
    }?.1
    if hit != hoverCandidate {
      hoverCandidate = hit
      candidateSince = now
      if suppressed != hit { suppressed = nil }
    }
    if let hit {
      lastInside = now
      if hit != suppressed, now - candidateSince >= 0.30,
        !popover.isShown || (peeking && anchor != hit)
      {
        togglePanel(hit, peek: true)
        if popover.isShown { suppressed = hit }
      }
    } else if popover.isShown && peeking {
      if popover.contentViewController?.view.window?.frame.insetBy(dx: -5, dy: -6).contains(pointer)
        == true
      {
        lastInside = now
      } else if now - lastInside > 0.45 {
        popover.performClose(nil)
        peeking = false
      }
    }
  }
  @objc private func showTodos() { studio.page = .todos; show() }
  @objc func newTodo() { showTodos(); studio.todos.editing = TodoItem() }
  @objc func showClipboard() {
    guard !studio.captures.capturing else { return }
    popover.performClose(nil)
    studio.clipChooser.open()
  }
  @objc func settings() { studio.page = .settings; show() }
  func applicationWillTerminate(_ notification: Notification) {
    hoverTimer?.invalidate()
    studio?.awake.stop()
    notes?.terminate()
  }
  func statusMenu() -> NSMenu {
    let menu = NSMenu()
    func add(_ title:String,_ selector:Selector,_ shortcut:String="") {
      menu.addItem(withTitle:title, action:selector, keyEquivalent:shortcut).target = self
    }
    add(L("打开工作台"),#selector(goOverview));add(L("新建待办…"),#selector(newTodo));add(L("剪贴板历史"),#selector(showClipboard))
    menu.addItem(.separator())
    let entry = menu.addItem(withTitle: Self.awakeTitle(studio.awake.active, studio.awake.endsAt),
                             action: nil, keyEquivalent: "")
    entry.submenu = awakeMenu()
    menu.addItem(.separator());add(L("偏好设置…"),#selector(settings),",")
    menu.addItem(.separator())
    menu.addItem(withTitle:L("退出Perch"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q").target = NSApp
    statusAppearance.prepare(menu)
    return menu
  }
  private static func awakeTitle(_ active: Bool, _ end: Date?) -> String {
    if let end { return L("保持唤醒至 ") + end.formatted(date: .omitted, time: .shortened) }
    return active ? L("保持唤醒 · 直到手动结束") : L("保持唤醒")
  }
  private func awakeMenu() -> NSMenu {
    let choices = NSMenu()
    if studio.awake.active {
      choices.addItem(withTitle: Self.awakeTitle(true, studio.awake.endsAt), action: nil, keyEquivalent: "")
      choices.addItem(withTitle: L("立即结束"), action: #selector(stopAwake), keyEquivalent: "").target = self
      choices.addItem(.separator())
    }
    for minutes in AwakeSession.minutes {
      let option = choices.addItem(withTitle: AwakeSession.label(minutes), action: #selector(startAwake(_:)), keyEquivalent: "")
      option.tag = minutes
      option.target = self
    }
    choices.addItem(withTitle: L("自定义时长…"), action: #selector(customAwake), keyEquivalent: "").target = self
    let indefinite = choices.addItem(withTitle: L("直到手动结束"), action: #selector(indefiniteAwake), keyEquivalent: "")
    indefinite.target = self
    indefinite.state = studio.awake.active && studio.awake.endsAt == nil ? .on : .off
    return choices
  }
  @objc private func awakeClicked(_ sender: NSStatusBarButton) {
    showingStatusMenu = true
    defer { showingStatusMenu = false }
    popover.performClose(nil)
    let menu = awakeMenu()
    statusAppearance.prepare(menu)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
  }
  @objc private func customAwake() { studio.awake.chooseDuration() }
  @objc private func indefiniteAwake() {
    if !studio.awake.start(seconds: nil) { goOverview() }
  }
  @objc private func startAwake(_ sender: NSMenuItem) {
    if !studio.awake.start(seconds: TimeInterval(sender.tag * 60)) { goOverview() }
  }
  @objc private func stopAwake() { studio.awake.stop() }
  @objc func goOverview(){studio.page = .overview;show()}
  @objc func statusClicked(_ sender:NSStatusBarButton) {
    let tab:InstrumentTab = sender === usageItem.button ? .usage : sender === networkItem.button ? .network : .hardware
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      showingStatusMenu = true
      popover.performClose(nil)
      peeking = false
      statusMenu().popUp(positioning:nil, at:NSPoint(x:0,y:sender.bounds.minY-3), in:sender)
      showingStatusMenu = false
      suppressed = tab
    } else if let flags=event?.modifierFlags, flags.contains(.option) {
      if flags.contains(.shift) {studio.clips.skipOnce.toggle()} else {studio.clips.paused.toggle()}
      popover.performClose(nil)
      suppressed=tab
    } else { togglePanel(tab) }
  }
  @objc func hardwarePanel() { togglePanel(.hardware) }
  @objc func usagePanel() { togglePanel(.usage) }
  @objc func networkPanel() { togglePanel(.network) }
  func togglePanel(_ tab: InstrumentTab, peek: Bool = false) {
    let same = anchor == tab && studio.navigation.tab == tab
    if popover.isShown && same && peeking && !peek {
      peeking = false
      return
    }
    if popover.isShown {
      if !same {
        studio.navigation.tab = tab
        anchor = tab
        peeking = peek
        return
      }
      popover.performClose(nil)
      suppressed = tab
      return
    }
    peeking = peek
    studio.navigation.tab = tab
    anchor = tab
    let primary = tab == .usage ? usageItem : tab == .network ? networkItem : item
    let visible = primary?.isVisible == true ? primary : (item.isVisible ? item : networkItem)
    if let button = visible?.button {
      if popover.contentViewController == nil {
        popover.contentViewController = NSHostingController(rootView: InstrumentPanel(studio: studio, monitor: studio.monitor, nav: studio.navigation))
      }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      lastInside = ProcessInfo.processInfo.systemUptime
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    show()
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  @objc func openStudio() { show() }
  func setupMenu() {
    let main = NSMenu()
    let app = NSMenu()
    let edit = NSMenu()
    let a = main.addItem(withTitle: L("Perch"), action: nil, keyEquivalent: "")
    a.submenu = app
    app.addItem(withTitle: L("打开工作台"), action: #selector(openStudio), keyEquivalent: "0").target = self
    app.addItem(withTitle: L("硬件面板"), action: #selector(hardwarePanel), keyEquivalent: "1").target =
      self
    app.addItem(withTitle: L("网络面板"), action: #selector(networkPanel), keyEquivalent: "2").target =
      self
    app.addItem(withTitle:L("剪贴板历史"),action:#selector(showClipboard),keyEquivalent:"").target=self
    app.addItem(withTitle:L("新建待办…"),action:#selector(newTodo),keyEquivalent:"").target=self
    app.addItem(withTitle:L("偏好设置…"),action:#selector(settings),keyEquivalent:",").target=self
    app.addItem(.separator())
    app.addItem(
      withTitle: L("退出Perch"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let e = main.addItem(withTitle: L("编辑"), action: nil, keyEquivalent: "")
    e.submenu = edit
    for (title, selector, key) in [
      (L("拷贝"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a"),
    ] { edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key) }
    let windowMenu = NSMenu(title: L("窗口"))
    main.addItem(withTitle: windowMenu.title, action: nil, keyEquivalent: "").submenu = windowMenu
    windowMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    NSApp.mainMenu = main
  }
}
