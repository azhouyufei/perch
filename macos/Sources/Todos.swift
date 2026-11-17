import AppKit
import SwiftUI
import UserNotifications

struct TodoItem: Identifiable, Codable, Equatable {
  var id = UUID()
  var title = ""
  var detail = ""
  var due: Date?
  var remind: Date?
  var completed = false
  var pinned = false
  var created = Date()
  var stickerID: UUID?
  var notificationID: String { "glint.todo." + id.uuidString }
}

struct TodoSticker: Identifiable, Codable, Equatable {
  let id: UUID
  var title: String
}

final class TodoStore: ObservableObject {
  private struct Archive: Codable {
    var items: [TodoItem]
    var stickers: [TodoSticker]
  }
  @Published private var archive = Archive(items: [], stickers: [])
  var items: [TodoItem] { archive.items }
  var stickers: [TodoSticker] { archive.stickers }
  var pinnedStickers: [TodoSticker] {
    let ids = Set(items.filter { $0.pinned && !$0.completed }.compactMap(\.stickerID))
    return stickers.filter { ids.contains($0.id) }
  }
  func members(of id: UUID) -> [TodoItem] {
    items.filter { $0.stickerID == id && $0.pinned && !$0.completed }
      .sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
  }
  @Published var editing: TodoItem?
  @Published var notice: String?
  @Published var notificationBlocked = false
  var didChange: (() -> Void)?
  let file: URL
  private var loadFailed = false
  init(folder: URL = perchSupportFolder()) {
    file = folder.appendingPathComponent("Todos.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    do {
      let data = try Data(contentsOf: file)
      if let current = try? JSONDecoder().decode(Archive.self, from: data) {
        archive = current
        return
      }
      let legacy = try JSONDecoder().decode([TodoItem].self, from: data)
      var restored = Archive(items: legacy, stickers: [])
      for i in restored.items.indices where restored.items[i].pinned && !restored.items[i].completed
      {
        let id = restored.items[i].id
        restored.items[i].stickerID = id
        restored.stickers.append(TodoSticker(id: id, title: Self.newName(in: restored)))
      }
      archive = restored
    } catch {
      loadFailed = true
      notice = L("无法读取待办 · ") + error.localizedDescription
    }
  }
  private static func newName(in state: Archive) -> String {
    let used = Set(state.stickers.map(\.title))
    if !used.contains(L("待办清单")) { return L("待办清单") }
    var number = 2
    while used.contains(L("待办清单 ") + String(number)) { number += 1 }
    return L("待办清单 ") + String(number)
  }
  @discardableResult func save(_ value: TodoItem) -> Bool {
    var item = value
    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !item.title.isEmpty else {
      notice = L("请输入待办标题")
      return false
    }
    if item.completed { item.pinned = false }
    var state = archive
    if item.pinned {
      let id = item.stickerID ?? pinnedStickers.first?.id ?? UUID()
      item.stickerID = id
      if !state.stickers.contains(where: { $0.id == id }) {
        state.stickers.append(TodoSticker(id: id, title: Self.newName(in: state)))
      }
    }
    if let index = state.items.firstIndex(where: { $0.id == item.id }) {
      state.items[index] = item
    } else {
      state.items.insert(item, at: 0)
    }
    return persist(state)
  }
  func add(_ title: String, to id: UUID) -> UUID? {
    guard stickers.contains(where: { $0.id == id }) else { return nil }
    let task = TodoItem(title: title, pinned: true, stickerID: id)
    return save(task) ? task.id : nil
  }
  func place(_ itemID: UUID, on id: UUID) {
    guard var task = items.first(where: { $0.id == itemID }), !task.completed else { return }
    task.pinned = true
    task.stickerID = id
    save(task)
  }
  func updateText(_ id: UUID, title: String, detail: String) -> Bool {
    guard var item = items.first(where: { $0.id == id }) else { return false }
    item.title = title
    item.detail = detail
    return save(item)
  }
  func rename(_ id: UUID, to title: String) -> Bool {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let i = stickers.firstIndex(where: { $0.id == id }) else { return false }
    var state = archive
    state.stickers[i].title = name
    return persist(state)
  }
  func setPinned(_ pinned: Bool, sticker id: UUID) {
    var state = archive
    for i in state.items.indices where state.items[i].stickerID == id && !state.items[i].completed {
      state.items[i].pinned = pinned
    }
    _ = persist(state)
  }
  func remove(_ id: UUID) {
    var state = archive
    state.items.removeAll { $0.id == id }
    _ = persist(state)
  }
  func toggle(_ id: UUID, pin: Bool = false) {
    guard var item = items.first(where: { $0.id == id }) else { return }
    if pin { item.pinned.toggle() } else { item.completed.toggle() }
    save(item)
  }
  private func persist(_ changed: Archive) -> Bool {
    guard !loadFailed else { return false }
    var state = changed
    let used = Set(state.items.compactMap(\.stickerID))
    state.stickers.removeAll { !used.contains($0.id) }
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(state).write(to: file, options: .atomic)
      archive = state
      notice = nil
      didChange?()
      return true
    } catch {
      notice = L("待办未保存 · ") + error.localizedDescription
      return false
    }
  }
}
func perchSupportFolder() -> URL {
  FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("perch", isDirectory: true)
}

// Rename the complete tree on the same volume so SQLite databases and their sidecars
// stay together. A concurrent first launch may have completed the rename already.
func migratePerchStorage(to destination: URL = perchSupportFolder()) throws {
  let fm = FileManager.default
  let legacy = destination.deletingLastPathComponent().appendingPathComponent("ScopeBar")
  guard !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: legacy.path) else { return }
  do { try fm.moveItem(at: legacy, to: destination) }
  catch {
    guard fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: legacy.path) else { throw error }
  }
}

@MainActor final class TodoReminders: NSObject, UNUserNotificationCenterDelegate {
  let store: TodoStore
  var show: (UUID?) -> Void = { _ in }
  private var syncing = false, dirty = false, ask = false
  private let center = UNUserNotificationCenter.current()
  init(store: TodoStore) {
    self.store = store
    super.init()
    center.delegate = self
  }
  func update(requestAccess: Bool = false) {
    dirty = true
    ask = ask || requestAccess
    guard !syncing else { return }
    syncing = true
    Task {
      while dirty {
        dirty = false
        let prompt = ask
        ask = false
        await reconcile(prompt: prompt)
      }
      syncing = false
    }
  }
  nonisolated static func request(for item: TodoItem, now: Date = Date()) -> UNNotificationRequest?
  {
    guard !item.completed, let date = item.remind, date > now else { return nil }
    let c = UNMutableNotificationContent()
    c.title = item.title
    c.body = [item.detail, item.due.map { L("截止 ") + $0.formatted() } ?? ""].filter { !$0.isEmpty }
      .joined(separator: "\n")
    if c.body.isEmpty { c.body = L("待办提醒") }
    c.sound = .default
    c.userInfo = ["todo": item.id.uuidString, "time": date.timeIntervalSince1970]
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = cal.dateComponents(
      [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
    return UNNotificationRequest(
      identifier: item.notificationID, content: c,
      trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
  }
  private func reconcile(prompt: Bool) async {
    var settings = await center.notificationSettings()
    if prompt && settings.authorizationStatus == .notDetermined {
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        settings = await center.notificationSettings()
      } catch { store.notice = L("系统通知未启用 · ") + error.localizedDescription }
    }
    let allowed =
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    store.notificationBlocked =
      !allowed && store.items.contains { !$0.completed && ($0.remind ?? .distantPast) > Date() }
    let pending = await center.pendingNotificationRequests()
    let records = store.items
    let wanted = Dictionary(
      uniqueKeysWithValues: records.compactMap { Self.request(for: $0) }.map { ($0.identifier, $0) }
    )
    let old = pending.filter { $0.identifier.hasPrefix("glint.todo.") }
    center.removePendingNotificationRequests(
      withIdentifiers: old.map(\.identifier).filter { wanted[$0] == nil })
    let active = Set(records.filter { !$0.completed && $0.remind != nil }.map(\.notificationID))
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map(\.request.identifier).filter {
        $0.hasPrefix("glint.todo.") && !active.contains($0)
      })
    guard allowed else { return }
    for (id, req) in wanted {
      if dirty { return }
      if let previous = old.first(where: { $0.identifier == id }),
        previous.content.title == req.content.title, previous.content.body == req.content.body,
        previous.content.userInfo["time"] as? Double == req.content.userInfo["time"] as? Double
      {
        continue
      }
      do { try await center.add(req) } catch {
        store.notice = L("提醒未排入系统 · ") + error.localizedDescription
      }
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let uuid = (response.notification.request.content.userInfo["todo"] as? String).flatMap(
      UUID.init(uuidString:))
    Task { @MainActor in
      self.show(uuid)
      completionHandler()
    }
  }
}

private final class StickerPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
private final class StickerHostingView: NSHostingView<TodoNote> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class TodoNotes: NSObject, NSWindowDelegate {
  let store: TodoStore
  var requestReminderAccess: () -> Void = {}
  private var windows: [UUID: NSPanel] = [:]
  init(store: TodoStore) { self.store = store }
  func refresh() {
    let pinned = store.pinnedStickers
    let ids = Set(pinned.map(\.id))
    for id in Array(windows.keys) where !ids.contains(id) {
      if let w = windows.removeValue(forKey: id) {
        w.delegate = nil
        w.ignoresMouseEvents = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let host = w.contentView as? NSHostingView<TodoNote> {
          withAnimation(.easeIn(duration: reduced ? 0.12 : 0.38)) {
            host.rootView.motion.removing = true
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduced ? 0.14 : 0.4)) { w.close() }
      }
    }
    for sticker in pinned {
      let rows = store.members(of: sticker.id)
      if let panel = windows[sticker.id], let host = panel.contentView as? NSHostingView<TodoNote> {
        let motion = host.rootView.motion
        if motion.rows != rows { motion.rows = rows }
        if motion.sticker != sticker { motion.sticker = sticker }
        continue
      }
      let noteView = TodoNote(
        id: sticker.id, store: store, motion: StickerMotion(sticker: sticker, rows: rows),
        request: requestReminderAccess)
      let panel = StickerPanel(
        contentRect: NSRect(x: 0, y: 0, width: 302, height: 224),
        styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.becomesKeyOnlyIfNeeded = false
      panel.identifier = NSUserInterfaceItemIdentifier(sticker.id.uuidString)
      panel.title = L("待办便签")
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.isMovableByWindowBackground = false
      panel.isReleasedWhenClosed = false
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.minSize = NSSize(width: 250, height: 158)
      panel.contentView = StickerHostingView(rootView: noteView)
      let name = "GlintNote-" + sticker.id.uuidString
      if !panel.setFrameUsingName(name) {
        let frame = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 650))
        let offset = CGFloat(windows.count % 6) * 22
        panel.setFrameTopLeftPoint(
          NSPoint(x: frame.maxX - 334 - offset, y: frame.maxY - 36 - offset))
      }
      panel.setFrameAutosaveName(name)
      panel.delegate = self
      windows[sticker.id] = panel
      panel.orderFrontRegardless()
    }
  }
  func windowWillClose(_ n: Notification) {
    guard let w = n.object as? NSPanel, let key = w.identifier?.rawValue,
      let id = UUID(uuidString: key), windows.removeValue(forKey: id) != nil
    else { return }
    store.setPinned(false, sticker: id)
  }
  func terminate() {
    for w in windows.values {
      w.delegate = nil
      w.saveFrame(usingName: "GlintNote-" + (w.identifier?.rawValue ?? ""))
    }
  }
}
private final class StickerMotion: ObservableObject {
  @Published var removing = false
  @Published var sticker: TodoSticker
  @Published var rows: [TodoItem]
  init(sticker: TodoSticker, rows: [TodoItem]) {
    self.sticker = sticker
    self.rows = rows
  }
}
private struct StickerPaper: Shape {
  var fold: CGFloat
  var animatableData: CGFloat {
    get { fold }
    set { fold = newValue }
  }
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 2, y: 0))
    p.addLine(to: CGPoint(x: r.maxX - 2, y: 0))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: 2), control: CGPoint(x: r.maxX, y: 0))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.addQuadCurve(
      to: CGPoint(x: r.maxX - fold, y: r.maxY),
      control: CGPoint(x: r.maxX - fold * 0.65, y: r.maxY - fold * 0.4))
    p.addLine(to: CGPoint(x: 0, y: r.maxY - 1))
    p.addLine(to: CGPoint(x: 0, y: 2))
    p.closeSubpath()
    return p
  }
}
private struct StickerDragHandle: NSViewRepresentable {
  final class Handle: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  }
  func makeNSView(context: Context) -> Handle { Handle() }
  func updateNSView(_ view: Handle, context: Context) {}
}
private struct TodoNote: View {
  let id: UUID
  @ObservedObject var store: TodoStore
  @ObservedObject var motion: StickerMotion
  let request: () -> Void
  @State private var hoveringPin = false
  @State private var renaming = false
  @State private var name = ""
  @State private var newTitle = ""
  @State private var justAdded: UUID?
  private enum Field { case name, add }
  @FocusState private var focus: Field?
  private func add() {
    if let added = store.add(newTitle, to: id) {
      newTitle = ""
      justAdded = added
      focus = .add
    }
  }
  private func saveName() { if store.rename(id, to: name) { renaming = false } }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let ink = Color(red: 0.20, green: 0.16, blue: 0.10)
  private let honey = Color(red: 0.91, green: 0.77, blue: 0.46)
  var body: some View {
    let peel = motion.removing && !reduceMotion
    let fold: CGFloat = peel ? 54 : 16
    ZStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          if renaming {
            TextField(L("便签名称"), text: $name).textFieldStyle(.plain).focused($focus, equals: .name)
              .onSubmit { saveName() }.onExitCommand { renaming = false }
            Button(action: saveName) { Image(systemName: "checkmark") }.accessibilityLabel(L("保存便签名称"))
          } else {
            Button {
              name = motion.sticker.title
              renaming = true
              DispatchQueue.main.async { focus = .name }
            } label: {
              Text(motion.sticker.title).font(
                .system(size: 17, weight: .semibold, design: .rounded)
              )
              .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                Rectangle())
            }.help(L("点击修改便签名称")).accessibilityLabel(L("修改便签名称"))
            Text(String(motion.rows.count)).font(.caption.monospacedDigit()).foregroundStyle(
              ink.opacity(0.6))
            Button {
              store.setPinned(false, sticker: id)
            } label: {
              Image(systemName: "pin.slash").font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 36)
                .background(ink.opacity(hoveringPin ? 0.14 : 0.055), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .onHover { hoveringPin = $0 }
            .help(L("从桌面收起，待办保留在工作台")).accessibilityLabel(L("取消固定整张便签"))
          }
        }
        Divider()
        ScrollViewReader { reader in
          ScrollView {
            VStack(alignment: .leading, spacing: 3) {
              ForEach(motion.rows) { item in
                StickerTaskRow(item: item, store: store, request: request).id(item.id)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.onChange(of: justAdded) { added in
            if let added { reader.scrollTo(added, anchor: .bottom) }
          }
        }
        HStack(spacing: 7) {
          Image(systemName: "plus").foregroundStyle(ink.opacity(0.65))
          TextField(L("添加待办…"), text: $newTitle).textFieldStyle(.plain).focused($focus, equals: .add)
            .accessibilityLabel(L("添加待办")).onSubmit { add() }.onExitCommand {
              newTitle = ""
              focus = nil
            }
          if !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: add) { Image(systemName: "return") }.help(L("添加到这张便签")).accessibilityLabel(
              L("确认添加"))
          } else {
            Menu {
              let available = store.items.filter {
                !$0.completed && (!$0.pinned || $0.stickerID != id)
              }
              if available.isEmpty { Text(L("没有其他待办")) }
              ForEach(available) { item in Button(item.title) { store.place(item.id, on: id) } }
            } label: {
              Image(systemName: "text.badge.plus")
            }.fixedSize().menuStyle(.borderlessButton)
              .help(L("将已有待办移到这张便签")).accessibilityLabel(L("加入已有待办"))
          }
        }.font(.callout)
        if let notice = store.notice { Text(notice).font(.caption2).foregroundStyle(.red) }
      }
      .buttonStyle(.plain).foregroundStyle(ink).padding(.horizontal, 16).padding(.top, 24).padding(
        .bottom, 13
      )
      .background(alignment: .bottomTrailing) {
        ZStack(alignment: .bottomTrailing) {
          StickerPaper(fold: fold).fill(
            LinearGradient(
              colors: [
                Color(red: 1, green: 0.97, blue: 0.83), Color(red: 0.98, green: 0.89, blue: 0.63),
              ], startPoint: .topLeading, endPoint: .bottomTrailing)
          )
          .shadow(color: .black.opacity(0.24), radius: 4, x: 0, y: 3)
          Path { p in
            p.move(to: CGPoint(x: 0, y: fold))
            p.addQuadCurve(
              to: CGPoint(x: fold, y: 0), control: CGPoint(x: fold * 0.35, y: fold * 0.65))
            p.addQuadCurve(to: CGPoint(x: 0, y: fold), control: CGPoint(x: 0, y: 1))
          }
          .fill(honey).frame(width: fold, height: fold)
        }
      }
      RoundedRectangle(cornerRadius: 1).fill(
        Color(red: 0.86, green: 0.74, blue: 0.53).opacity(0.63)
      )
      .frame(width: 60, height: 12).rotationEffect(.degrees(-4)).offset(y: -5).allowsHitTesting(
        false)
      StickerDragHandle().frame(width: 96, height: 19).accessibilityHidden(true)
    }
    .environment(\.colorScheme, .light).tint(ink)
    .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 10)
    .rotation3DEffect(
      .degrees(peel ? -44 : 0), axis: (x: 0.7, y: -0.4, z: 0.2), anchor: .topLeading,
      perspective: 0.6
    )
    .offset(x: peel ? 18 : 0, y: peel ? -30 : 0).opacity(motion.removing ? 0 : 1)
  }
}
private struct StickerTaskRow: View {
  let item: TodoItem
  let store: TodoStore
  let request: () -> Void
  @State private var editing = false
  @State private var options = false
  @State private var hoveringOptions = false
  @State private var title = ""
  @State private var detail = ""
  @FocusState private var titleFocused: Bool

  private func begin() {
    title = item.title
    detail = item.detail
    editing = true
    DispatchQueue.main.async { titleFocused = true }
  }
  private func save() {
    if store.updateText(item.id, title: title, detail: detail) { editing = false }
  }
  var body: some View {
    HStack(alignment: editing ? .top : .center, spacing: 4) {
      Button {
        store.toggle(item.id)
      } label: {
        Image(systemName: "circle").font(.system(size: 16))
          .frame(width: 28, height: 36).contentShape(Rectangle())
      }.help(L("完成此项")).accessibilityLabel(Lf("完成待办：%@", item.title))
      if editing {
        VStack(alignment: .leading, spacing: 4) {
          TextField(L("待办标题"), text: $title).textFieldStyle(.plain).focused($titleFocused)
            .accessibilityLabel(L("编辑待办标题")).onSubmit { save() }.onExitCommand { editing = false }
          TextField(L("备注"), text: $detail, axis: .vertical).textFieldStyle(.plain)
            .lineLimit(1...4).font(.caption).onExitCommand { editing = false }
          HStack {
            Button(L("取消")) { editing = false }
            Spacer()
            Button(L("保存"), action: save).disabled(
              title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          .font(.caption.weight(.semibold))
        }.padding(5).background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 4))
      } else {
        Button(action: begin) {
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(3)
            if !item.detail.isEmpty {
              Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let due = item.due {
              Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(
                .caption2)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.help(L("点击编辑标题和备注")).accessibilityLabel(Lf("编辑待办：%@", item.title))
        Button {
          options = true
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 36)
            .background(.primary.opacity(hoveringOptions || options ? 0.11 : 0.04),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .onHover { hoveringOptions = $0 }
        .help(L("编辑日期与提醒")).accessibilityLabel(L("编辑日期与提醒"))
        .popover(isPresented: $options) {
          TodoForm(initial: item, store: store, request: request, onSticker: true)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct TodosPage: View {
  @ObservedObject var store: TodoStore
  let request: () -> Void
  @State private var completed = false
  @State private var deleting: TodoItem?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Picker(L("状态"), selection: $completed) {
          Text(L("待完成")).tag(false)
          Text(L("已完成")).tag(true)
        }.labelsHidden().pickerStyle(.segmented).fixedSize()
        if !store.stickers.isEmpty {
          Menu(L("桌面便签")) {
            ForEach(store.stickers) { sticker in
              let isPinned = store.pinnedStickers.contains(sticker)
              Button((isPinned ? L("收起 · ") : L("固定 · ")) + sticker.title) {
                store.setPinned(!isPinned, sticker: sticker.id)
              }
              .disabled(!store.items.contains { $0.stickerID == sticker.id && !$0.completed })
            }
          }.fixedSize()
        }
        Spacer()
        Button {
          store.editing = TodoItem()
        } label: {
          Label(L("新建待办"), systemImage: "plus")
        }.buttonStyle(.borderedProminent)
      }
      if store.notificationBlocked {
        HStack {
          Label(L("提醒尚未获得系统通知权限"), systemImage: "bell.slash")
          Spacer()
          Button(L("启用通知"), action: request)
          Button(L("系统设置")) {
            NSWorkspace.shared.open(
              URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
          }
        }.font(.callout)
      }
      if let notice = store.notice { Text(notice).foregroundStyle(.orange) }
      let rows = store.items.filter { $0.completed == completed }.sorted {
        ($0.due ?? .distantFuture, $0.created) < ($1.due ?? .distantFuture, $1.created)
      }
      if rows.isEmpty {
        Label(completed ? L("还没有已完成的待办") : L("没有待完成事项"), systemImage: "checkmark.circle").foregroundStyle(
          .secondary
        ).padding()
      }
      ForEach(rows) { item in
        HStack(alignment: .top, spacing: 12) {
          Button {
            store.toggle(item.id)
          } label: {
            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.title2)
          }.buttonStyle(.plain).help(item.completed ? L("恢复待办") : L("标记完成"))
          VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline)
            if !item.detail.isEmpty { Text(item.detail).lineLimit(2).foregroundStyle(.secondary) }
            if let due = item.due {
              Label(L("截止 ") + due.formatted(), systemImage: "calendar").foregroundStyle(
                !item.completed && due < Date() ? ScopeTheme.upload : .secondary
              ).font(.caption)
            }
            if let time = item.remind {
              Label(time.formatted(), systemImage: "bell").font(.caption).foregroundStyle(
                .secondary)
            }
          }
          Spacer()
          if !completed {
            Menu {
              ForEach(store.stickers) { sticker in
                Button(sticker.title) { store.place(item.id, on: sticker.id) }
              }
              Button(L("新建独立便签")) { store.place(item.id, on: UUID()) }
            } label: {
              Image(systemName: "rectangle.on.rectangle")
            }.fixedSize().help(L("选择桌面便签"))
            Button {
              store.toggle(item.id, pin: true)
            } label: {
              Image(systemName: item.pinned ? "pin.fill" : "pin")
            }.help(item.pinned ? L("取消固定") : L("固定在桌面"))
          }
          Button {
            store.editing = item
          } label: {
            Image(systemName: "pencil")
          }.help(L("编辑"))
          Button {
            deleting = item
          } label: {
            Image(systemName: "trash")
          }.help(L("删除"))
        }.padding(14).tile()
      }
    }.sheet(item: $store.editing) { item in TodoForm(initial: item, store: store, request: request)
    }
    .alert(
      L("删除这项待办？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { item in
      Button(L("删除"), role: .destructive) { store.remove(item.id) }
      Button(L("取消"), role: .cancel) {}
    }
  }
}
private struct TodoForm: View {
  let initial: TodoItem
  @ObservedObject var store: TodoStore
  let request: () -> Void
  let onSticker: Bool
  @State private var newStickerID = UUID()
  @State private var draft: TodoItem
  @State private var due: Bool
  @State private var remind: Bool
  @State private var deadline: Date
  @State private var alarm: Date
  @Environment(\.dismiss) private var dismiss
  init(initial: TodoItem, store: TodoStore, request: @escaping () -> Void, onSticker: Bool = false)
  {
    self.onSticker = onSticker
    self.initial = initial
    self.store = store
    self.request = request
    var prepared = initial
    if prepared.stickerID == nil { prepared.stickerID = store.pinnedStickers.first?.id }
    _draft = State(initialValue: prepared)
    _due = State(initialValue: initial.due != nil)
    _remind = State(initialValue: initial.remind != nil)
    let next = Date().addingTimeInterval(3600)
    _deadline = State(initialValue: initial.due ?? next)
    _alarm = State(initialValue: initial.remind ?? initial.due ?? next)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(initial.title.isEmpty ? L("新建待办") : L("编辑待办")).font(.title2.bold())
      TextField(L("待办标题"), text: $draft.title).textFieldStyle(.roundedBorder)
      TextField(L("备注"), text: $draft.detail, axis: .vertical).lineLimit(2...5).textFieldStyle(
        .roundedBorder)
      HStack {
        Toggle(L("截止时间"), isOn: $due)
        Spacer()
        if due { DatePicker(L("截止"), selection: $deadline).labelsHidden() }
      }
      HStack {
        Toggle(L("定时提醒"), isOn: $remind)
        Spacer()
        if remind { DatePicker(L("提醒"), selection: $alarm).labelsHidden() }
      }.onChange(of: remind) { on in if on && initial.remind == nil && due { alarm = deadline } }
      if remind && alarm <= Date() && initial.remind != alarm {
        Text(L("请选择未来的提醒时间")).font(.caption).foregroundStyle(ScopeTheme.upload)
      }
      if !onSticker {
        Toggle(L("固定到桌面便签"), isOn: $draft.pinned).disabled(draft.completed)
        if draft.pinned {
          Picker(
            L("便签"),
            selection: Binding(
              get: { draft.stickerID ?? newStickerID }, set: { draft.stickerID = $0 })
          ) {
            ForEach(store.stickers) { sticker in Text(sticker.title).tag(sticker.id) }
            Text(L("新建独立便签")).tag(newStickerID)
          }
        }
      }
      HStack {
        Spacer()
        Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("保存")) {
          draft.due = due ? deadline : nil
          draft.remind = remind ? alarm : nil
          if draft.pinned && draft.stickerID == nil { draft.stickerID = newStickerID }
          var changed = draft
          if !initial.title.isEmpty {
            guard var latest = store.items.first(where: { $0.id == initial.id }) else {
              dismiss()
              return
            }
            if draft.title != initial.title { latest.title = draft.title }
            if draft.detail != initial.detail { latest.detail = draft.detail }
            if draft.due != initial.due { latest.due = draft.due }
            if draft.remind != initial.remind { latest.remind = draft.remind }
            if !onSticker {
              if draft.pinned != initial.pinned { latest.pinned = draft.pinned }
              if draft.pinned && draft.stickerID != initial.stickerID {
                latest.stickerID = draft.stickerID
              }
            }
            changed = latest
          }
          if store.save(changed) {
            if changed.remind != nil && !changed.completed { request() }
            dismiss()
          }
        }.keyboardShortcut(.defaultAction).disabled(
          draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (remind && alarm <= Date() && initial.remind != alarm))
      }
      if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
    }.padding(20).frame(width: 430)
  }
}
