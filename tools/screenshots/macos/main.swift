import AppKit
import SwiftUI

// Publish only demo sessions. Each run gets an isolated cache and isolated log roots.
final class ScreenshotDelegate: NSObject, NSApplicationDelegate {
  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let output = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ScreenshotDirectory") as! String)
  var window: NSWindow!
  var studio: Studio!
  var notes: TodoNotes!
  var status: NSStatusItem!
  let popover = NSPopover()
  lazy var statusAppearance = StatusAppearance(popover: popover)
  var sampleShot: Shot!
  var step = 0
  let scenes = ["usage", "dashboard", "annotation", "clipboard", "note", "panel", "network"]
  var dark = false
  let menuOwner = AppDelegate()

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
      let usage = UsageStore(folder: temporary)
      let counts = [19, 37, 28, 41, 55, 32, 66, 40, 58, 49, 25, 69, 39, 56]
      let rows = (0..<28).map { i -> UsageRow in
        let day = Calendar.current.date(byAdding: .day, value: i - 27, to: Calendar.current.startOfDay(for: Date()))!
        let n = counts[i % counts.count] * 1250
        return UsageRow(date: day, tool: "Codex", session: "sample-\(i)", model: "Example model", project: "perch",
                        amount: UsageAmount(input: n, cached: n/3, output: n/4, reasoning: n/12), title: "Example session")
      }
      usage.useSampleRows(rows)
      let clipFolder = temporary.appendingPathComponent("clipboard")
      let db = try ClipDatabase(folder: clipFolder)
      let clipTexts = ["bash macos/Scripts/build.sh", "Open the menu bar to see live network activity.",
                       "https://example.org/release-notes", "Review the release checklist"]
      for (i, text) in clipTexts.enumerated() {
        try db.add(ClipContent(parts: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]),
                   app: ["Terminal", "Notes", "Safari", "Notes"][i], limit: 100)
      }
      let clipboard = ClipboardHistory(folder: clipFolder, board: NSPasteboard(name: .init("org.perch.docs." + UUID().uuidString)))
      clipboard.start()
      studio = Studio(captures: Captures(folder: temporary.appendingPathComponent("shots")), usage: usage, todos: TodoStore(folder: temporary), clips: clipboard)
      studio.keys.previewDefaults()
      menuOwner.studio = studio
      studio.page = .usage
      studio.workspaceVisible = false
      NSApp.appearance = NSAppearance(named: .aqua)
      window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
      window.title = "Perch"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.contentView = NSHostingView(rootView: Workspace(studio: studio, captures: studio.captures)
        .environment(\.locale, Locale(identifier: "en_US")))
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      let titles = ["Review the capture toolbar", "Check the keyboard shortcuts", "Write the release notes"]
      for title in titles { _ = studio.todos.save(TodoItem(title: title, pinned: true)) }
      let sticker = studio.todos.pinnedStickers[0]
      _ = studio.todos.rename(sticker.id, to: "Release checklist")
      notes = TodoNotes(store: studio.todos)
      let apps = ["Safari", "Terminal", "Finder", "Perch"]
      ProcessMonitor.shared.useSampleProcesses(apps.enumerated().map { i, name in
        BusyProcess(id: Int32(900001+i), name: name, cpu: [5.2,2.7,1.2,0.4][i], memory: UInt64([348,112,92,32][i])*1024*1024)
      })
      let network = NetworkInfo.shared
      network.interface = "Wi-Fi"
      network.local = "192.0.2.25"
      network.processes = [TrafficProcess(id: 900001, name: "Safari", incoming: 1200000, outgoing: 80000),
                           TrafficProcess(id: 900002, name: "Terminal", incoming: 280000, outgoing: 100000)]
      var sensors = SBSensors()
      sensors.pTemp = 48; sensors.eTemp = 42; sensors.gpuTemp = 39
      sensors.pGHz = 3.2; sensors.gpuGHz = 0.8; sensors.fan0 = 1300; sensors.min0 = 800; sensors.max0 = 3500
      studio.monitor.useSampleReadings((0..<70).map { i in
        let wave = (1 + sin(Double(i) * 0.27)) / 2
        return Reading(date: Date().addingTimeInterval(Double(i-69)*2),
          values: [.cpu:16 + 28*wave, .memory:42, .upload:80000 + 300000*wave, .download:950000 + 1800000*wave],
          sensors: sensors, used: 7200000000, total: 17000000000)
      })
      status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      status.button?.image = StatusInk.draw("CPU", StatusInk.hardware(studio.monitor.current), width: 31)
      showScene()
    } catch { fail(error) }
  }

  func showScene() {
    let scene = scenes[step]
    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    var subject = window!
    switch scene {
    case "usage", "dashboard", "clipboard":
      studio.page = scene == "usage" ? .usage : scene == "clipboard" ? .clipboard : .overview
      window.contentView = NSHostingView(rootView: Workspace(studio: studio, captures: studio.captures)
        .environment(\.locale, Locale(identifier: "en_US")))
    case "annotation":
      guard let original = ImageEditor.original(sampleShot) else { fail(CocoaError(.fileReadCorruptFile)); return }
      let mark = Mark(tool: .arrow, color: NSColor.systemRed.cgColor,
                      points: [CGPoint(x: 0.57, y: 0.39), CGPoint(x: 0.42, y: 0.26)])
      let draft = AnnotationDraft(image: original, marks: [mark], moves: CaptionMoves())
      window.contentView = NSHostingView(rootView: EditorView(shot: sampleShot, captures: studio.captures, draft: draft, finish: { _ in })
        .environment(\.locale, Locale(identifier: "en_US")))
    case "note":
      notes.refresh()
      guard let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == studio.todos.pinnedStickers[0].id.uuidString })
      else { fail(CocoaError(.fileNoSuchFile)); return }
      panel.setContentSize(NSSize(width: 370, height: 246))
      subject = panel
    default:
      studio.navigation.tab = scene == "network" ? .network : .hardware
      let controller = NSHostingController(rootView: InstrumentPanel(studio: studio, monitor: studio.monitor, nav: studio.navigation)
        .environment(\.processTablesVisible, false))
      popover.contentViewController = controller
      popover.animates = false
      _ = statusAppearance
      guard let button = status.button else { fail(CocoaError(.featureUnsupported)); return }
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      guard let panel = controller.view.window else { fail(CocoaError(.featureUnsupported)); return }
      subject = panel
    }
    let target = subject
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [self] in
      do {
        let png = try imageData(target)
        let theme = dark ? "dark" : "light"
        let name = scene == "usage" ? "macos-" + theme : "macos-" + scene + "-" + theme
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        if scene == "dashboard" { sampleShot = try studio.captures.add(png) }
        if scene == "network" || scene == "panel" {
          if scene == "panel", !dark, let button = status.button,
             let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("macos-status.png"))
          }
          popover.close()
          if scene == "network" { captureMenu() }
        }
        step += 1
        if step == scenes.count {
          if dark { NSApp.terminate(nil); return }
          step = 0; dark = true
        }
        showScene()
      } catch { fail(error) }
    }
  }
  // Capture only a menu window owned by this documentation process.
  func captureMenu() {
    let menu = menuOwner.statusMenu()
    guard let anchor = status.button else { return }
    let before = Set(windowIDs())
    let filename = "macos-menu-" + (dark ? "dark" : "light") + ".png"
    let timer = Timer(timeInterval: 0.5, repeats: false) { [self] _ in
      for id in windowIDs() where !before.contains(id) {
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
              cg.width >= 150, cg.height >= 120,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
        try? data.write(to: output.appendingPathComponent(filename), options: .atomic)
        break
      }
      menu.cancelTracking()
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: anchor)
    timer.invalidate()
  }
  func windowIDs() -> [CGWindowID] {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { entry in
      guard entry[kCGWindowOwnerPID as String] as? Int32 == getpid(),
            let layer = entry[kCGWindowLayer as String] as? Int, layer >= Int(CGWindowLevelForKey(.popUpMenuWindow))
      else { return nil }
      return entry[kCGWindowNumber as String] as? CGWindowID
    }
  }
  func imageData(_ subject: NSWindow) throws -> Data {
    subject.displayIfNeeded()
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(subject.windowNumber),
        [.boundsIgnoreFraming, .bestResolution]),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileReadUnknown) }
    return png
  }
  func fail(_ error: Error) { NSLog("Perch screenshot failed: %@", error.localizedDescription); NSApp.terminate(nil) }
  func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: temporary) }
}
UserDefaults.standard.register(defaults: ["ui.language":"en", "AppleLocale":"en_US", "AppleLanguages":["en"], "usage.tool":"全部"])
UserDefaults.standard.set("en_US", forKey: "AppleLocale")
UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
let app = NSApplication.shared
let delegate = ScreenshotDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
