import UserNotifications
import AppKit
import ImageIO
import ScreenCaptureKit

// Checks the same storage, rendering and kernel readers used by the app.
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  guard ok() else { fatalError(message) }
  print("PASS " + message)
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("scopebar-check-" + UUID().uuidString)
defer { try? fm.removeItem(at: root) }
let migrationParent = fm.temporaryDirectory.appendingPathComponent("perch-migration-" + UUID().uuidString)
defer { try? fm.removeItem(at: migrationParent) }
let legacy = migrationParent.appendingPathComponent("ScopeBar")
let destination = migrationParent.appendingPathComponent("perch")
try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
try Data("example".utf8).write(to: legacy.appendingPathComponent("Todos.json"))
try migratePerchStorage(to: destination)
try migratePerchStorage(to: destination)
let restoredBytes = try Data(contentsOf: destination.appendingPathComponent("Todos.json"))
check(restoredBytes == Data("example".utf8) && !fm.fileExists(atPath: legacy.path), "Perch migration survives repeated launches")
try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
try Data("other".utf8).write(to: legacy.appendingPathComponent("Todos.json"))
try migratePerchStorage(to: destination)
let unchangedBytes = try Data(contentsOf: destination.appendingPathComponent("Todos.json"))
check(unchangedBytes == restoredBytes && fm.fileExists(atPath: legacy.path), "existing Perch data takes precedence")
let store = Captures(folder: root)
let ctx = CGContext(
  data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
let original = try store.add(data)
check(original.pixels == CGSize(width: 200, height: 100), "original pixel dimensions")
let mark = Mark(
  tool: .redact, color: CGColor(gray: 0, alpha: 1),
  points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.4)])
let marked = try store.add(ImageEditor.render(original, marks: [mark]))
check(
  marked.url != original.url && marked.pixels == original.pixels,
  "lossless copy dimensions and independent file")
let rep = NSBitmapImageRep(data: try Data(contentsOf: marked.url))!
func light(_ x: Int, _ y: Int) -> Double {
  Double(rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent)
}
check(light(50, 20) < 0.35 && light(50, 80) > 0.9, "redaction matches top-left editor coordinates")
let savedOriginal = try Data(contentsOf: original.url)
check(savedOriginal == data, "unchanged original pixels")
let reloaded = Captures(folder: root)
check(
  reloaded.shots.count == 2 && original.thumbnail(80)!.width == 80,
  "persistent history and thumbnail scaling")
reloaded.remove(marked)
check(Captures(folder: root).shots.count == 1, "delete survives reload")
do {
  _ = try store.add(Data([1, 2, 3]))
  fatalError("invalid image accepted")
} catch {}
let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
check(files.count == 1, "invalid image leaves no partial file")
let first = sb_sample()
Thread.sleep(forTimeInterval: 0.55)
let next = sb_sample()
check(
  first.cpu < 0 && (0...100).contains(next.cpu) && next.cores > 0,
  "CPU baseline and per-core sampling")
check(next.memoryUsed > 0 && next.memoryTotal >= next.memoryUsed, "physical memory reading")
check(next.diskFree >= 0 && next.diskTotal >= next.diskFree, "startup volume capacity")

let fixture = ctx.makeImage()!
let retina = CropGeometry.pixels(
  CGRect(x: 10, y: 5, width: 20, height: 15), in: CGRect(x: 0, y: 0, width: 100, height: 50),
  image: fixture)
check(retina == CGRect(x: 20, y: 60, width: 40, height: 30), "retina selection pixel coordinates")
let clipped = CropGeometry.pixels(
  CGRect(x: -5, y: 40, width: 15, height: 15), in: CGRect(x: 0, y: 0, width: 100, height: 50),
  image: fixture)
check(clipped == CGRect(x: 0, y: 0, width: 20, height: 20), "selection clipped to active display")
check(
  ShortcutAction.capture.standard.label == "F1" && ShortcutAction.paste.standard.label == "F3"
    && ShortcutAction.togglePins.standard.label == "⇧F3", "default keyboard bindings")
let baseline = TrafficCSV.snapshot(
  ",bytes_in,bytes_out,\n23:59:59.000000,Demo.42,4096,3000,\nIdle.45,99,10,")
let current = TrafficCSV.snapshot(
  "time,,bytes_in,bytes_out,\n00:00:01.000000,Demo.42,6144,4000,\nIdle.45,99,10,")
let traffic = TrafficCSV.rates(previous: baseline, current: current, elapsed: 2)
check(
  traffic.first { $0.id == 42 }?.incoming == 1024 && traffic.first { $0.id == 42 }?.outgoing == 500,
  "per-PID byte deltas across midnight and differing CSV headers")
check(traffic.first { $0.id == 45 }?.outgoing == 0, "idle processes and rows without a clock")
let changed = TrafficCSV.snapshot("Demo.42,10,5,\nNewApp.45,10000,1000,")
check(
  TrafficCSV.rates(previous: baseline, current: changed, elapsed: 2).isEmpty,
  "reject reset counters and reused PID")
check(
  TrafficCSV.rates(previous: baseline, current: current, elapsed: 0).isEmpty, "reject zero interval"
)

let canvas = SelectionCanvas(image: fixture)
canvas.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
var chosen: SnipAction?
var resultImage: CGImage?
canvas.done = { image, action in
  resultImage = image
  chosen = action
}
func selectionKey(_ chars: String, _ keyCode: UInt16, command: Bool = false) {
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
    timestamp: 0, windowNumber: 0, context: nil, characters: chars,
    charactersIgnoringModifiers: chars,
    isARepeat: false, keyCode: keyCode)!
  if command { _ = canvas.performKeyEquivalent(with: event) } else { canvas.keyDown(with: event) }
}
selectionKey("a", 0, command: true)
selectionKey("t", 17, command: true)
check(
  chosen == .pin && resultImage?.width == 200, "Command-A then Command-T pins the selected pixels")
selectionKey("\r", 36)
check(chosen == .copy && resultImage?.height == 100, "Return copies the selected pixels")
selectionKey(" ", 49)
check(chosen == .edit && resultImage != nil, "Space opens the selection for editing")
selectionKey("", 53)
check(resultImage == nil, "Escape cancels the selection without saving")

let processes = [
  LedgerEntry(id: 9, name: "pending", first: nil, second: 90),
  LedgerEntry(id: 8, name: "busy", first: 100, second: 10),
  LedgerEntry(id: 1, name: "idle", first: 1, second: 20),
  LedgerEntry(id: 5, name: "busy2", first: 100, second: 30),
]
func rankedIDs(_ column: Int, _ descending: Bool) -> [Int32] {
  processes.sorted { LedgerEntry.precedes($0, $1, column: column, descending: descending) }.map(
    \.id)
}
check(
  rankedIDs(0, true) == [5, 8, 1, 9], "CPU descending with stable ties and missing sample last")
check(rankedIDs(0, false) == [1, 5, 8, 9], "CPU ascending keeps missing samples last")
check(
  rankedIDs(1, true) == [9, 5, 1, 8] && rankedIDs(1, false) == [8, 1, 5, 9],
  "memory rank uses bytes in both directions")

let log = root.appendingPathComponent("fixture.jsonl")
let stamp = "2026-11-16T04:20:00Z"
func codexLine(_ input: Int, _ output: Int, _ hits: Int) throws -> Data {
  let totals = ["input_tokens": input, "output_tokens": output, "cached_input_tokens": hits]
  let payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": totals]]
  return try JSONSerialization.data(withJSONObject: [
    "timestamp": stamp, "type": "event_msg", "payload": payload,
  ]) + Data([10])
}
let a = try codexLine(100, 10, 50)
let b = try codexLine(160, 25, 80)
var usageFile = UsageFile()
try (a + a + b.prefix(10)).write(to: log)
try usageFile.update(url: log, tool: "Codex", size: UInt64(a.count * 2 + 10), node: 1)
check(
  usageFile.offset == UInt64(2 * a.count)
    && usageFile.rows(tool: "Codex", path: "s")[0].total == 110,
  "duplicate totals and incomplete JSONL line")
try (a + a + b).write(to: log)
var restoredState = try JSONDecoder().decode(UsageFile.self, from: JSONEncoder().encode(usageFile))
try restoredState.update(url: log, tool: "Codex", size: UInt64(a.count * 2 + b.count), node: 1)
check(
  restoredState.rows(tool: "Codex", path: "s")[0].amount
    == UsageAmount(input: 160, cached: 80, output: 25),
  "resume from cache and count cumulative Codex deltas")
var claude = UsageFile()
for output in [1, 5, 5] {
  let message: [String: Any] = [
    "id": "r", "model": "model",
    "usage": [
      "input_tokens": 10, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 3,
      "output_tokens": output,
    ],
  ]
  let line = try JSONSerialization.data(withJSONObject: [
    "timestamp": stamp, "type": "assistant", "message": message,
  ])
  claude.consume(line, tool: "Claude Code")
}
check(
  claude.rows(tool: "Claude Code", path: "s")[0].amount
    == UsageAmount(input: 33, cached: 20, output: 5, cacheWrite: 3),
  "Claude streaming updates replace earlier message usage")
var claw = UsageFile()
let clawMessage: [String: Any] = [
  "role": "assistant", "model": "local",
  "usage": ["input": 10, "cacheRead": 30, "cacheWrite": 2, "output": 5],
]
let clawLine = try JSONSerialization.data(withJSONObject: [
  "id": "c", "timestamp": stamp, "type": "message", "message": clawMessage,
])
claw.consume(clawLine, tool: "OpenClaw")
claw.consume(clawLine, tool: "OpenClaw")
check(
  claw.rows(tool: "OpenClaw", path: "s")[0].amount
    == UsageAmount(input: 42, cached: 30, output: 5, cacheWrite: 2),
  "OpenClaw JSONL cache accounting and deduplication")

let region = SelectionCanvas(image: fixture)
region.frame = NSRect(x: 0, y: 0, width: 100, height: 50)
let upperDisplay = CGRect(x: -900, y: -600, width: 900, height: 600)
let spanningWindow = CGRect(x: -100, y: -150, width: 400, height: 240)
check(CropGeometry.localWindow(spanningWindow, on: upperDisplay, in: upperDisplay.size) ==
      CGRect(x: 800, y: 0, width: 100, height: 150), "upper-left display clips spanning candidates in display-local points")
let lowerDisplay = CGRect(x: 0, y: 0, width: 1600, height: 900)
check(CropGeometry.localWindow(spanningWindow, on: lowerDisplay, in: lowerDisplay.size) ==
      CGRect(x: 0, y: 810, width: 300, height: 90), "same window maps to the other display independently of backing pixels")
region.updateTrackingAreas()
check(region.trackingAreas.contains { $0.options.contains([.activeAlways, .mouseMoved, .mouseEnteredAndExited]) },
      "non-key capture panels track hover and screen crossings")
region.windows = [(7, region.bounds), (8, region.bounds)]
region.updatePointer(CGPoint(x: 20, y: 20))
check(region.hovered?.0 == 7, "frontmost visible candidate under the pointer wins")
region.updatePointer(nil)
check(region.hovered == nil, "leaving a capture display clears its previous candidate")
region.windows = []
var captured: CGImage?
var regionAction: SnipAction?
region.done = {
  captured = $0
  regionAction = $1
}
func dragSelection(_ start: CGPoint, _ end: CGPoint) {
  for (kind, point) in [
    (NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end),
  ] {
    let event = NSEvent.mouseEvent(
      with: kind, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 1)!
    switch kind {
    case .leftMouseDown: region.mouseDown(with: event)
    case .leftMouseDragged: region.mouseDragged(with: event)
    default: region.mouseUp(with: event)
    }
  }
}
func regionKey(_ text: String, _ code: UInt16, command: Bool = false) {
  let e = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
    isARepeat: false, keyCode: code)!
  region.keyDown(with: e)
}
dragSelection(CGPoint(x: 5, y: 5), CGPoint(x: 45, y: 35))
region.pinSelection()
check(
  regionAction == .pin && captured?.width == 80 && captured?.height == 60,
  "drag and directly pin Retina selection")
dragSelection(CGPoint(x: 45, y: 35), CGPoint(x: 60, y: 40))
regionKey("\r", 36)
check(captured?.width == 110 && captured?.height == 70, "corner drag resizes the active region")
dragSelection(CGPoint(x: 25, y: 20), CGPoint(x: 32, y: 21))
region.pinSelection()
check(captured?.width == 110 && captured?.height == 70, "moving region preserves size")
regionKey("5", 23)
dragSelection(CGPoint(x: 25, y: 15), CGPoint(x: 44, y: 26))
region.pinSelection()
func centerRed(_ image: CGImage?) -> CGFloat? {
  guard let image else { return nil }
  let bitmap = NSBitmapImageRep(cgImage: image)
  return bitmap.colorAt(x: 44, y: 38)?.usingColorSpace(.sRGB)?.redComponent
}
check((centerRed(captured) ?? 1) < 0.3, "inline redaction is present in pinned output")
regionKey("z", 6, command: true)
region.pinSelection()
check((centerRed(captured) ?? 0) > 0.9, "inline undo restores original pixels")

let usageFixture = ["Codex", "Claude Code"].enumerated().map { index, name in
  UsageRow(
    date: Date(), tool: name, session: "session", model: "shared", project: "project",
    amount: UsageAmount(input: 100 * (index + 1), cached: 30, output: 5))
}
check(
  UsageTool.claude.filter(usageFixture).map(\.total) == [205],
  "tool scope excludes other tools even with identical project and model")
check(
  UsageTool.all.filter(usageFixture).count == 2 && UsageTool.openClaw.filter(usageFixture).isEmpty,
  "all tools and empty tool scope")
check(
  UsageTool.codex.showsCodexQuota && !UsageTool.claude.showsCodexQuota
    && !UsageTool.openClaw.showsCodexQuota, "quota follows the selected tool")
check(
  RegionSelection.accessDenied(NSError(domain: SCStreamErrorDomain, code: -3801))
    && !RegionSelection.accessDenied(NSError(domain: NSCocoaErrorDomain, code: -3801)),
  "recognize ScreenCaptureKit permission errors")

let blackInk = CGColor(gray: 0, alpha: 1)
let corners = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.7, y: 0.7)]
func bitmap(_ mark: Mark) throws -> NSBitmapImageRep {
  NSBitmapImageRep(cgImage: try ImageEditor.composite(fixture, marks: [mark]))
}
func red(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
  image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent
}
var outline = Mark(tool: .circle, color: blackInk, points: corners, strokeFraction: 0.04)
let roundImage = try bitmap(outline)
let ovalImage = try bitmap(
  Mark(tool: .ellipse, color: blackInk, points: corners, strokeFraction: 0.04))
check(
  red(roundImage, 80, 40) < 0.2 && red(roundImage, 140, 40) > 0.9 && red(roundImage, 50, 40) > 0.9,
  "circle remains round on a rectangular drag")
check(
  red(ovalImage, 140, 40) < 0.2 && red(ovalImage, 80, 40) > 0.9,
  "ellipse spans both drag axes with empty center")
outline.strokeFraction = 0.12
let thick = try bitmap(outline)
check(
  red(thick, 84, 40) < 0.2 && red(roundImage, 84, 40) > 0.9, "stroke width affects exported pixels")
let captionBitmap = try bitmap(
  Mark(tool: .text, color: blackInk, points: [corners[0]], strokeFraction: 0.04, caption: "标注 A"))
let captionPixels = (10..<40).flatMap { y in (20..<110).map { x in red(captionBitmap, x, y) } }
check(
  captionPixels.filter { $0 < 0.5 }.count > 50 && red(captionBitmap, 5, 5) > 0.9,
  "Chinese and Latin text render at the chosen anchor")
ctx.setFillColor(blackInk)
for x in stride(from: 0, to: 200, by: 2) { ctx.fill(CGRect(x: x, y: 0, width: 1, height: 100)) }
let stripes = ctx.makeImage()!
let tile = try ImageEditor.mosaicTexture(stripes, previous: [], blockSize: 10)
let covered = try ImageEditor.composite(
  stripes, marks: [Mark(tool: .mosaic, color: blackInk, points: corners, texture: tile)])
let pixels = NSBitmapImageRep(cgImage: covered)
check(
  abs(red(pixels, 44, 24) - red(pixels, 45, 24)) < 0.03
    && abs(red(pixels, 10, 24) - red(pixels, 11, 24)) > 0.8,
  "mosaic flattens detail only inside the marked rectangle")
check(
  MarkTool.allCases.allSatisfy {
    NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil
  } && NSImage(systemSymbolName: "lineweight", accessibilityDescription: nil) != nil,
  "all screenshot toolbar symbols exist on this OS")

let cal = Calendar.current
let day = cal.startOfDay(for: Date())
let monthInterval = cal.dateInterval(of: .month, for: day)!
let daily = DayUsage.grouped(usageFixture + [usageFixture[0]], in: monthInterval)[day]!
check(
  daily.amount.total == 415 && daily.sessions.count == 2 && daily.models.count == 1,
  "rings sum usage and deduplicate sessions across model rows by tool")
let gaps = [0, 1, 2, 4, 5].map { cal.date(byAdding: .day, value: $0, to: day)! }
check(
  DayUsage.longestRun(gaps.reversed()) == 3 && DayUsage.longestRun([]) == 0,
  "calendar streak respects inactive days and empty months")
var reasoningLog = UsageFile()
for (input, output, reasoning) in [(100, 10, 6), (180, 20, 11)] {
  let totals = [
    "input_tokens": input, "output_tokens": output, "reasoning_output_tokens": reasoning,
  ]
  let record: [String: Any] = [
    "timestamp": stamp, "type": "event_msg",
    "payload": ["type": "token_count", "info": ["total_token_usage": totals]],
  ]
  reasoningLog.consume(try JSONSerialization.data(withJSONObject: record), tool: "Codex")
}
let parsed = reasoningLog.rows(tool: "Codex", path: "sample")[0].amount
check(
  parsed.reasoning == 11 && parsed.total == 200 && parsed.cacheWrite == nil,
  "reasoning is a subset of output with missing cache writes preserved")

let binEnd = Date()
func coreSample(_ age: Double, _ cores: [Double]) -> Reading {
  var r = Reading(date: binEnd.addingTimeInterval(-age))
  r.cores = cores
  return r
}
let coreHistory = CoreBins.history([coreSample(120,[99,99]),coreSample(7,[50,12]),coreSample(3,[30,-1]),coreSample(0,[10,41])])
check(coreHistory.count == 2 && coreHistory[0][29] == 30 && coreHistory[1][29] == 41, "per-core heatmap aggregates real peaks and skips missing readings")
check(coreHistory[0][28] == 50 && coreHistory[0][0] == nil && CoreBins.history([]).isEmpty, "heatmap preserves unsampled intervals and clips the time window")

check(AnnotationOption.colors.count == 16 && AnnotationOption.colors.allSatisfy { p in
  AnnotationOption.decode(p.1).map(AnnotationOption.hex) == p.1
}, "all annotation presets round-trip to exact sRGB")
check(AnnotationOption.decode(" #aB1198 ").map(AnnotationOption.hex) == "AB1198" && AnnotationOption.decode("-00456") == nil && AnnotationOption.decode("GG1122") == nil, "custom HEX accepts RGB and rejects invalid input")
let byTool = TokenHistoryData(rows: usageFixture, days: 7, split: .tool)
let byModel = TokenHistoryData(rows: usageFixture, days: 7, split: .model)
check(byTool.names.count == 2 && byTool.values.last?.reduce(0,+) == 310 && byModel.names == ["shared"] && byModel.values.last == [310], "daily stacks conserve tokens when switching dimensions")
check(byTool.values.dropLast().allSatisfy { $0.allSatisfy { $0 == 0 } }, "empty calendar days stay in the trend")
let manyModels = (1...7).map { value in UsageRow(date:Date(), tool:"Codex", session:"s", model:"M" + String(value), project:"", amount:UsageAmount(input:value)) }
let tails = TokenHistoryData(rows: manyModels, days: 1, split: .model)
check(tails.values == [[7,6,5,4,6]], "lower-volume models form one conserved series")

let taskFolder = root.appendingPathComponent("Tasks")
let tasks = TodoStore(folder: taskFolder)
let now = Date(timeIntervalSince1970: 1_900_000_000)
var task = TodoItem(title:"  发布检查  ", detail:"检查签名", due:now.addingTimeInterval(7200), remind:now.addingTimeInterval(3600), pinned:true)
check(tasks.save(task) && tasks.items[0].title == "发布检查", "persist a titled desktop todo")
let restoredTask = TodoStore(folder:taskFolder).items.first
check(restoredTask?.pinned == true && restoredTask?.due == task.due && restoredTask?.remind == task.remind, "restore pinned todo with separate deadline and reminder")
let firstAlarm = TodoReminders.request(for:task,now:now)!
task.remind = now.addingTimeInterval(5400)
let revisedAlarm = TodoReminders.request(for:task,now:now)!
let trigger = revisedAlarm.trigger as? UNCalendarNotificationTrigger
check(firstAlarm.identifier == revisedAlarm.identifier && trigger?.dateComponents.date == task.remind && revisedAlarm.content.userInfo["todo"] as? String == task.id.uuidString, "replace the same notification at the edited absolute time")
check(TodoReminders.request(for:task,now:now.addingTimeInterval(6000)) == nil, "expired reminder is not scheduled again")
tasks.toggle(task.id)
check(tasks.items[0].completed && !tasks.items[0].pinned && TodoReminders.request(for:tasks.items[0],now:now) == nil, "completing a todo removes its pin and scheduled reminder")
tasks.remove(task.id)
check(TodoStore(folder:taskFolder).items.isEmpty, "delete todo survives restart")

let historyFolder = root.appendingPathComponent("Clips")
let history = try ClipDatabase(folder:historyFolder)
func clipText(_ value:String)->ClipContent { ClipContent(parts:[[NSPasteboard.PasteboardType.string.rawValue:Data(value.utf8)]]) }
let textClip=clipText("macOS clipboard"), laterClip=clipText("second"), lastClip=clipText("third")
try history.add(textClip,app:"source",limit:1,date:now)
let initialClip = try history.list()[0]
try history.pin(initialClip)
try history.add(laterClip,app:"second",limit:1,date:now.addingTimeInterval(2))
try history.add(lastClip,app:"third",limit:1,date:now.addingTimeInterval(3))
try history.add(textClip,app:"other",limit:1,date:now.addingTimeInterval(4))
let survivors = try ClipDatabase(folder:historyFolder).list()
check(survivors.count == 2 && survivors[0].id == textClip.fingerprint && survivors[0].pin == "b" && survivors[0].app == "other" && survivors[1].label == "third","SQLite deduplication, stable pin and eviction survive restart")
check(ClipSearch.contains.filter(survivors,query:"OTHER").count == 1 && ClipSearch.fuzzy.filter(survivors,query:"mcb").count == 1 && ClipSearch.regex.filter(survivors,query:"^thi").count == 1, "search by source, fuzzy characters or regular expression")
try history.clear(all:false)
let keepPinned = try history.list()
check(keepPinned.map(\.id) == [textClip.fingerprint],"clear unpinned keeps pinned records")
try history.clear(all:true)
let clearResult=try history.list()
check(clearResult.isEmpty, "clear all removes pinned records too")
let rich = ClipContent(parts:[[NSPasteboard.PasteboardType.html.rawValue:Data("<html><body><p>A &amp; B</p><p>C</p></body></html>".utf8)]])
check(rich.plain?.contains("A & B\nC") == true, "HTML-only clipboard content exports readable plain text")
let ftype=NSPasteboard.PasteboardType.fileURL.rawValue
let fileClip = ClipContent(parts:[[ftype:Data("file:///tmp/a".utf8)],[ftype:Data("file:///tmp/b".utf8)]])
try history.add(fileClip,app:"Finder",limit:25)
let restoredFiles=try history.content(fileClip.fingerprint)
check(restoredFiles?.parts == fileClip.parts && fileClip.label == "/tmp/a\n/tmp/b", "file references round-trip with original order")
let board=NSPasteboard.withUniqueName()
if textClip.write(board,plainOnly:false) {
  defer { board.releaseGlobally() }
  check(ClipContent.read(board)?.parts == textClip.parts, "private macOS pasteboard captures text without touching the user's clipboard")
  check(fileClip.write(board,plainOnly:false) && ClipContent.read(board)?.parts == fileClip.parts, "private pasteboard restores a multi-file selection")
  check(rich.write(board,plainOnly:true) && board.string(forType:.string) == rich.plain, "pure-text paste drops rich representations")
  let concealed=NSPasteboardItem()
  concealed.setString("private fixture",forType:.string)
  concealed.setString("1",forType:.init("org.nspasteboard.ConcealedType"))
  board.clearContents()
  check(board.writeObjects([concealed]) && ClipContent.read(board) == nil, "concealed copies never enter clipboard history")
  let extra=NSPasteboardItem()
  extra.setString("fixture",forType:.string)
  extra.setString("1",forType:.init("glint.fixture.exclude"))
  board.clearContents()
  check(board.writeObjects([extra]) && ClipContent.read(board,ignored:["glint.fixture.exclude"]) == nil,"custom ignored type suppresses the entire copy")
} else { print("SKIP private pasteboard server unavailable") }

let mergedTypes = TokenHistoryData(rows: usageFixture, days: 7, split: .category)
check(
  mergedTypes.values.last == [240, 60, 10]
    && mergedTypes.values.map { $0.reduce(0, +) } == byModel.values.map { $0.reduce(0, +) },
  "one daily graph conserves tokens across type, tool and model")
let titleFolder = root.appendingPathComponent("codex-titles")
try fm.createDirectory(at: titleFolder, withIntermediateDirectories: true)
let titleIndex = titleFolder.appendingPathComponent("session_index.jsonl")
try Data(
  "{\"id\":\"sid\",\"thread_name\":\"Original\"}\n{\"id\":\"sid\",\"thread_name\":\"Renamed\"}\n"
    .utf8
).write(to: titleIndex)
let names = SessionNames.loadCodex(root: titleFolder, database: nil)
check(names["sid"] == "Renamed", "latest Codex rename wins without modifying its index")
func event(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
var namedClaude = UsageFile()
namedClaude.consume(
  event(["type": "user", "message": ["content": [["type": "text", "text": "整理图表"]]]]),
  tool: "Claude Code")
namedClaude.consume(
  event([
    "type": "assistant", "timestamp": stamp,
    "message": ["id": "m", "model": "sonnet", "usage": ["output_tokens": 30]],
  ]), tool: "Claude Code")
check(
  namedClaude.rows(tool: "Claude Code", path: "abc")[0].title == "整理图表",
  "untitled Claude transcript uses its first readable user prompt")
for (key, value) in [("custom-title", "自定义名称"), ("ai-title", "自动标题")] {
  namedClaude.consume(
    event(["type": key, key == "custom-title" ? "customTitle" : "aiTitle": value]),
    tool: "Claude Code")
}
check(
  namedClaude.rows(tool: "Claude Code", path: "abc")[0].title == "自定义名称",
  "manual Claude names take precedence over generated titles")
check(
  namedClaude.rows(tool: "Claude Code", path: "abc")[0].session == "abc",
  "presentation names preserve independent session identities")
let quotaNow = Date()
let futureReset = quotaNow.addingTimeInterval(3000).timeIntervalSince1970
let statusData = event([
  "model": ["id": "claude-sonnet-4"],
  "rate_limits": [
    "five_hour": ["used_percentage": 24.0, "resets_at": futureReset],
    "seven_day": ["used_percentage": 100.0, "resets_at": futureReset],
  ]
])
let quotaFile = root.appendingPathComponent("fixture-quota.json")
let line = try ClaudeQuota.statusLine(statusData, file: quotaFile, now: quotaNow, route: .direct)
let snapshot = try JSONDecoder().decode(QuotaSample.self, from: Data(contentsOf: quotaFile))
check(
  snapshot.windows.map(\.remaining) == [76, 0] && line.contains("76%") && snapshot.date == quotaNow,
  "Claude status line persists actual remaining values and observation time")
let sdkWindows = ClaudeQuota.windows([
  "rate_limit_info": [
    "unifiedWindows": ["five_hour": ["utilization": 0.5, "resetsAt": futureReset]]
  ]
])
check(sdkWindows.first?.remaining == 50, "SDK rate limit fractions use the correct percentage unit")
check(
  ClaudeQuota.windows([
    "rate_limits": ["five_hour": ["used_percentage": 120, "resets_at": futureReset]]
  ]).isEmpty && ClaudeQuota.windows(["context_window": ["used_percentage": 20]]).isEmpty,
  "missing account quota and invalid percentages stay unavailable")
let codexEvent = event([
  "type": "event_msg", "timestamp": stamp,
  "payload": [
    "type": "token_count",
    "rate_limits": [
      "primary": ["used_percent": 12, "window_minutes": 300, "resets_at": futureReset]
    ],
  ],
])
var quotaLog = UsageFile()
quotaLog.consume(codexEvent, tool: "Codex")
check(
  quotaLog.quota?.windows.first?.remaining == 88,
  "Codex quota is captured even without token totals")

let drawSize = CGSize(width: 200, height: 100)
let initialAnchor = CGPoint(x: 0.06, y: 0.15)
let firstText = Mark(
  tool: .text, color: blackInk, points: [initialAnchor], strokeFraction: 0.015, caption: "拖动 A")
var editableMarks = [firstText, firstText]
let touch = CGPoint(x: 0.09, y: 0.18)
let picked = CaptionMove(marks: editableMarks, touch: touch, size: drawSize)!
check(
  picked.index == 1
    && CaptionMove(marks: editableMarks, touch: CGPoint(x: 0.9, y: 0.9), size: drawSize) == nil,
  "text hit testing selects the top caption and ignores empty pixels")
var movements = CaptionMoves()
picked.update(&editableMarks, to: CGPoint(x: touch.x + 0.35, y: touch.y + 0.2))
movements.finish(picked, in: editableMarks)
let anchorAfter = editableMarks[1].points[0]
check(
  abs(anchorAfter.x - 0.41) < 0.00001 && abs(anchorAfter.y - 0.35) < 0.00001
    && editableMarks[0].points[0] == initialAnchor,
  "drag preserves pointer offset in scaled image coordinates")
check(
  movements.undo(&editableMarks) && editableMarks.count == 2
    && editableMarks[1].points[0] == initialAnchor,
  "undoing a move restores the location without deleting the text")
picked.update(&editableMarks, to: CGPoint(x: 2, y: 2))
let edge = editableMarks[1].captionBounds(drawSize)!
check(
  edge.maxX <= drawSize.width + 0.01 && edge.maxY <= drawSize.height + 0.01,
  "dragging beyond the image keeps the caption in frame")

region.reset()
regionKey("a", 0, command: true)
regionKey("8", 28)
dragSelection(CGPoint(x: 8, y: 42), CGPoint(x: 8, y: 42))
let field = region.subviews.compactMap { $0 as? NSTextField }.first!
field.stringValue = "拖动"
region.controlTextDidEndEditing(
  Notification(name: NSControl.textDidEndEditingNotification, object: field))
func inkCenter(_ cg: CGImage?) -> CGPoint? {
  guard let cg else { return nil }
  let bitmap = NSBitmapImageRep(cgImage: cg)
  var xSum = 0, ySum = 0, count = 0
  for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
      if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.greenComponent < 0.8 {
        count += 1; xSum += x; ySum += y
      }
    }
  }
  return count == 0
    ? nil : CGPoint(x: Double(xSum) / Double(count), y: Double(ySum) / Double(count))
}
region.pinSelection()
let oldCenter = inkCenter(captured)!
dragSelection(CGPoint(x: 11, y: 38), CGPoint(x: 41, y: 28))
region.pinSelection()
let newCenter = inkCenter(captured)!
check(
  abs(newCenter.x - oldCenter.x - 60) < 2 && abs(newCenter.y - oldCenter.y - 20) < 2,
  "Retina selection drag moves exported glyphs by the scaled pointer delta")
var forwardedDraft: AnnotationDraft?
region.prepareEditor = { forwardedDraft = $0 }
regionKey(" ", 49)
check(
  regionAction == .edit && forwardedDraft?.marks.count == 1
    && inkCenter(forwardedDraft?.image) == nil,
  "editor handoff preserves editable layers and clean in-memory image")
regionKey("z", 6, command: true)
region.pinSelection()
check(inkCenter(captured) == oldCenter, "undo restores the rendered caption at its former position")

let clawIndex = root.appendingPathComponent("sessions.json")
try event(["agent:main": ["sessionId":"fixture-id", "label":"家庭网关调试"]]).write(to:clawIndex)
check(SessionNames.loadOpenClaw(indices:[clawIndex])["fixture-id"] == "家庭网关调试", "OpenClaw uses the readable name from its local session index")

let legacyFolder = root.appendingPathComponent("LegacyUsage")
try fm.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
let legacyFile = legacyFolder.appendingPathComponent("Usage-v2.json")
let laterFile = legacyFolder.appendingPathComponent("Usage-v3.json")
try JSONEncoder().encode(["old.jsonl": namedClaude, "common.jsonl": namedClaude]).write(
  to: legacyFile)
try JSONEncoder().encode(["today.jsonl": quotaLog, "common.jsonl": quotaLog]).write(to: laterFile)
let migrated = UsageStore.restore(folder: legacyFolder)
check(
  Set(migrated.keys) == ["old.jsonl", "common.jsonl", "today.jsonl"]
    && migrated["common.jsonl"]?.quota != nil,
  "cache migration imports older history and prefers the latest index for duplicate files")
let config = root.appendingPathComponent("ClaudeConfig")
try fm.createDirectory(at: config, withIntermediateDirectories: true)
try event(["env": ["ANTHROPIC_BASE_URL": "http://localhost:3456"]]).write(
  to: config.appendingPathComponent("settings.json"))
check(
  ClaudeRoute.detect(environment: [:], config: config) == .external,
  "read the Claude custom endpoint even when the GUI has no shell environment")
let customLine = try ClaudeQuota.statusLine(statusData, file: quotaFile, route: .external)
let suppressed = try JSONDecoder().decode(QuotaSample.self, from: Data(contentsOf: quotaFile))
check(
  !customLine.contains("%") && suppressed.windows.isEmpty
    && snapshot.verifiedClaude(for: .external) == nil,
  "custom provider rejects stored and incoming subscription values")
let unverified = QuotaSample(date: Date(), windows: snapshot.windows)
check(
  unverified.verifiedClaude(for: .direct) == nil && snapshot.verifiedClaude(for: .direct) != nil,
  "only attributed official status-line snapshots can display Claude subscription quota")
let noModel = try ClaudeQuota.statusLine(
  event(["rate_limits": ["five_hour": ["used_percentage": 1, "resets_at": futureReset]]]),
  file: quotaFile, route: .direct)
check(!noModel.contains("%"), "missing model identity blocks a quota claim")
check(
  ShortcutAction.capture.candidates(preferred: ShortcutAction.capture.standard).count >= 4
    && ShortcutAction.clipboard.candidates(preferred: ShortcutAction.clipboard.standard).count >= 4,
  "capture and history both offer default and multiple fallback shortcuts")

let legacyTodosFolder=root.appendingPathComponent("legacy-stickers")
try fm.createDirectory(at:legacyTodosFolder,withIntermediateDirectories:true)
let legacyTask=TodoItem(title:"旧便签",detail:"原备注",due:futureResetDate(),remind:futureResetDate(),pinned:true)
func futureResetDate()->Date {Date(timeIntervalSince1970:2_100_000_000)}
let otherLegacy=TodoItem(title:"另一张旧便签",pinned:true)
try JSONEncoder().encode([legacyTask,otherLegacy]).write(to:legacyTodosFolder.appendingPathComponent("Todos.json"))
let groupedTodos=TodoStore(folder:legacyTodosFolder)
check(groupedTodos.pinnedStickers.map(\.id)==[legacyTask.id,otherLegacy.id],"legacy stickers retain their frame autosave identifiers")
let newTaskID=groupedTodos.add("第二项",to:legacyTask.id)!
check(groupedTodos.pinnedStickers.count==2 && groupedTodos.members(of:legacyTask.id).map(\.id)==[legacyTask.id,newTaskID],"adding to an existing sticker keeps the same desktop panel")
check(groupedTodos.rename(legacyTask.id,to:"发布准备") && groupedTodos.updateText(legacyTask.id,title:"更新标题",detail:"更新备注"),"rename sticker and edit its task inline")
let editedTask=groupedTodos.items.first{$0.id==legacyTask.id}!
check(editedTask.due==legacyTask.due && editedTask.remind==legacyTask.remind && editedTask.notificationID==legacyTask.notificationID,"editing text preserves deadline, reminder and notification identity")
check(!groupedTodos.updateText(newTaskID,title:" ",detail:"") && groupedTodos.add(" ",to:legacyTask.id)==nil,"blank edits and additions preserve the list")
groupedTodos.place(otherLegacy.id,on:legacyTask.id)
check(groupedTodos.pinnedStickers.count==1 && groupedTodos.members(of:legacyTask.id).count==3,"move an existing task onto the same sticker without duplicating it")
groupedTodos.toggle(newTaskID)
check(groupedTodos.members(of:legacyTask.id).count==2 && groupedTodos.items.first{$0.id==newTaskID}?.completed==true,"completion removes only the chosen row")
groupedTodos.setPinned(false,sticker:legacyTask.id)
let reopenedTodos=TodoStore(folder:legacyTodosFolder)
check(reopenedTodos.pinnedStickers.isEmpty && reopenedTodos.stickers.first?.title=="发布准备" && reopenedTodos.items.count==3,"unpin keeps membership and content after restarting")
reopenedTodos.setPinned(true,sticker:legacyTask.id)
check(reopenedTodos.members(of:legacyTask.id).count==2 && reopenedTodos.pinnedStickers.count==1,"repinning restores the unfinished list without reopening completed tasks")
reopenedTodos.remove(legacyTask.id)
check(reopenedTodos.members(of:legacyTask.id).first?.id==otherLegacy.id && reopenedTodos.pinnedStickers.first?.title=="发布准备","removing the original owner does not remove its sticker or other rows")

let awake = AwakeSession()
check(!awake.start(seconds: 0) && awake.endsAt == nil, "zero duration cannot create an unbounded assertion")
check(AwakeSession.customMinutes(" 90 ") == 90 && AwakeSession.customMinutes("0") == nil
  && AwakeSession.customMinutes("1.5") == nil && AwakeSession.customMinutes("525601") == nil,
  "custom duration accepts whole minutes and rejects invalid input")
if awake.start(seconds: 3) {
  check(awake.endsAt != nil, "starting idle-sleep prevention sets a deadline")
  check(awake.start(seconds: nil) && awake.active && awake.endsAt == nil, "continuous mode replaces the time limit")
  check(awake.start(seconds: 1) && awake.endsAt!.timeIntervalSinceNow <= 1, "restarting replaces the current deadline")
  RunLoop.main.run(until: Date().addingTimeInterval(1.2))
  check(!awake.active && awake.endsAt == nil && awake.error == nil, "expired session automatically releases and clears the deadline")
  check(awake.start(seconds: 3), "start another session after expiry")
  awake.stop()
  awake.stop()
  check(!awake.active && awake.endsAt == nil, "manual stop is immediate and repeatable")
} else {
  check(awake.endsAt == nil && awake.error != nil, "a denied system assertion is never shown as active")
  print("SKIP power-management service unavailable for an active assertion")
}

var requestCount = 0
check(RegionSelection.directCaptureAllowed(preflight: { true }, request: { requestCount += 1; return false }) && requestCount == 0, "authorized captures bypass the permission prompt")
check(RegionSelection.directCaptureAllowed(preflight: { false }, request: { requestCount += 1; return true }) && requestCount == 1, "first direct capture requests screen recording access")
check(!RegionSelection.directCaptureAllowed(preflight: { false }, request: { false }), "denial stops the default direct capture")

let suite = "DeskToys.language-check." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
for language in ["en", "zh-Hans"] {
  AppLanguage.setPreferredLanguages(language, defaults: prefs)
  check(prefs.stringArray(forKey: "AppleLanguages") == [language], "persist explicit language " + language)
}
AppLanguage.setPreferredLanguages("system", defaults: prefs)
check(prefs.persistentDomain(forName: suite)?["AppleLanguages"] == nil, "system language clears the app override")
check(FittingColumns.count(for: 600, items: 4, minimum: 185, spacing: 10) == 2 &&
      FittingColumns.count(for: 800, items: 4, minimum: 185, spacing: 10) == 4,
      "narrow and wide dashboard cards retain readable label widths")
check(FittingColumns.count(for: 600, items: 2, minimum: 332, spacing: 12) == 1,
      "monitor panels stack when two readable panels do not fit")
