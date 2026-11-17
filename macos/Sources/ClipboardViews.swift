import AppKit
import ApplicationServices
import SwiftUI

enum ClipSearch: String, CaseIterable {
  case contains = "包含"
  case fuzzy = "模糊"
  case regex = "正则"
  func filter(_ entries: [ClipEntry], query: String) -> [ClipEntry] {
    guard !query.isEmpty else { return entries }
    let regex =
      self == .regex ? try? NSRegularExpression(pattern: query, options: .caseInsensitive) : nil
    return entries.filter { row in
      let subject = row.label + " " + row.app + " " + L(row.kind)
      switch self {
      case .contains: return subject.localizedCaseInsensitiveContains(query)
      case .regex:
        return regex?.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject))
          != nil
      case .fuzzy:
        var it = subject.lowercased().makeIterator()
        return query.lowercased().allSatisfy { ch in
          while let next = it.next() { if next == ch { return true } }
          return false
        }
      }
    }
  }
}
struct ClipboardPage: View {
  @ObservedObject var keys: HotKeys
  @ObservedObject var store: ClipboardHistory
  let open: () -> Void
  @State private var query = ""
  @State private var preview: ClipEntry?
  @AppStorage("clip.search") private var mode = ClipSearch.contains
  var body: some View {
    let rows = mode.filter(store.entries, query: query)
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        TextField(L("搜索内容或来源应用"), text: $query).textFieldStyle(.roundedBorder)
        Picker(L("搜索"), selection: $mode) {
          ForEach(ClipSearch.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
        }.labelsHidden().fixedSize()
        Button(L("快捷面板 · ") + keys.label(.clipboard), action: open).help(L("全局唤出剪贴板历史"))
        Menu {
          Button(store.paused ? L("恢复记录") : L("暂停记录")) { store.paused.toggle() }
          Button(store.skipOnce ? L("取消忽略下一次") : L("忽略下一次复制")) { store.skipOnce.toggle() }
          Divider()
          Button(L("清除未固定记录")) { store.clearRequest = false }
          Button(L("清空全部记录")) { store.clearRequest = true }
          Divider()
          Button(L("剪贴板设置")) { store.showSettings = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.fixedSize()
      }
      HStack {
        Circle().fill(store.paused ? ScopeTheme.yellow : ScopeTheme.live).frame(width: 7, height: 7)
        Text(store.paused ? L("记录已暂停") : store.skipOnce ? L("将忽略下一次复制") : L("正在记录"))
        Spacer()
        Text(Lf("%@ 条记录", String(describing: store.entries.count)))
      }.font(.caption).foregroundStyle(.secondary)
      if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
      if rows.isEmpty {
        Text(query.isEmpty ? L("复制文字、图片或文件后，会出现在这里。") : L("没有匹配的记录")).foregroundStyle(.secondary).padding(
          .vertical)
      }
      LazyVStack(spacing: 6) {
        ForEach(rows) { row in
          HStack(spacing: 10) {
            Button {
              preview = row
            } label: {
              ClipLabel(row: row)
            }.buttonStyle(.plain)
            Spacer()
            Button {
              store.pin(row)
            } label: {
              Image(systemName: row.pin == nil ? "pin" : "pin.fill")
            }.help(L("固定或取消固定"))
            Button {
              _ = store.copy(row, plain: false)
            } label: {
              Image(systemName: "doc.on.doc")
            }.help(L("复制"))
            Button {
              store.remove(row)
            } label: {
              Image(systemName: "trash")
            }.help(L("删除记录"))
          }.padding(10).tile(10).contextMenu {
            Button(L("预览")) { preview = row }
            Button(L("复制")) { _ = store.copy(row, plain: false) }
            Button(L("复制为纯文本")) { _ = store.copy(row, plain: true) }
            Button(row.pin == nil ? L("固定") : L("取消固定")) { store.pin(row) }
            Button(L("删除")) { store.remove(row) }
          }
        }
      }
    }.sheet(isPresented: $store.showSettings) { ClipSettings(store: store) }
      .sheet(item: $preview) { row in ClipPreview(row: row, store: store) }
      .alert(
        store.clearRequest == true ? L("清空所有剪贴板记录？") : L("清除未固定记录？"),
        isPresented: Binding(
          get: { store.clearRequest != nil }, set: { if !$0 { store.clearRequest = nil } }),
        presenting: store.clearRequest
      ) { all in
        Button(L("清除"), role: .destructive) { store.clear(all: all) }
        Button(L("取消"), role: .cancel) {}
      }
  }
}
private struct ClipLabel: View {
  let row: ClipEntry
  var body: some View {
    HStack(spacing: 10) {
      Image(
        systemName: row.kind == "图片"
          ? "photo" : row.kind == "文件" ? "folder" : row.kind == "富文本" ? "textformat" : "doc.text"
      )
      .foregroundStyle(
        row.kind == "图片"
          ? ScopeTheme.upload : row.kind == "文件" ? ScopeTheme.yellow : ScopeTheme.download
      ).frame(width: 27)
      VStack(alignment: .leading, spacing: 3) {
        Text(String(row.label.prefix(220))).lineLimit(1)
        Text(
          [L(row.kind), row.app, row.date.formatted(date: .abbreviated, time: .shortened)].filter {
            !$0.isEmpty
          }.joined(separator: " · ")
        ).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).help(
      String(row.label.prefix(1800)))
  }
}
private struct ClipPreview: View {
  let row: ClipEntry
  @ObservedObject var store: ClipboardHistory
  @State private var content: ClipContent?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(Lf("%@预览", L(row.kind))).font(.headline)
        Spacer()
        Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let data = content?.imageData ?? content?.data(.pdf), let image = NSImage(data: data) {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        ScrollView {
          Text(content?.plain ?? row.label).textSelection(.enabled).frame(
            maxWidth: .infinity, alignment: .leading)
        }
      }
      Spacer()
      Button(L("复制")) { if store.copy(row, plain: false) { dismiss() } }
    }.padding(16).frame(width: 520, height: 370).onAppear { content = store.content(row.id) }
  }
}
private struct ClipSettings: View {
  @ObservedObject var store: ClipboardHistory
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text(L("剪贴板设置")).font(.title2.bold())
        Spacer()
        Button(L("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Picker(L("未固定历史上限"), selection: $store.limit) {
        ForEach([25, 50, 100, 200, 500, 1000], id: \.self) { Text(Lf("%@ 条", String(describing: $0))).tag($0) }
      }.fixedSize(horizontal: true, vertical: false)
      Picker(L("检查复制变化"), selection: $store.interval) {
        Text("100 ms").tag(0.1)
        Text("250 ms").tag(0.25)
        Text("500 ms").tag(0.5)
        Text(L("1 秒")).tag(1.0)
      }.fixedSize(horizontal: true, vertical: false)
      Toggle(L("选择后自动粘贴到原应用"), isOn: $store.autoPaste)
      Text(L("自动粘贴需要在系统设置中允许Perch使用辅助功能。")).font(.caption).foregroundStyle(.secondary)
      Button(L("打开辅助功能设置")) {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      }
      TextField(L("忽略的应用 Bundle ID，多个用逗号分隔"), text: $store.ignoreApps).textFieldStyle(.roundedBorder)
      TextField(L("额外忽略的剪贴板类型，多个用逗号分隔"), text: $store.ignoreTypes).textFieldStyle(.roundedBorder)
      Text(L("可添加 com.apple.is-remote-clipboard 忽略通用剪贴板。带保密或临时标记的内容会自动跳过。")).font(.caption)
        .foregroundStyle(.secondary)
    }.padding(20).frame(width: 450)
  }
}

final class ClipChooser: NSObject, ObservableObject, NSWindowDelegate {
  let store: ClipboardHistory
  private var panel: NSPanel?, monitor: Any?, target: NSRunningApplication?
  @Published var query = "" { didSet { selected = nil } }
  @Published var selected: String?
  var manage: () -> Void = {}
  init(store: ClipboardHistory) { self.store = store }
  var visible: [ClipEntry] {
    (ClipSearch(rawValue: UserDefaults.standard.string(forKey: "clip.search") ?? "") ?? .contains)
      .filter(store.entries, query: query)
  }
  var current: ClipEntry? { visible.first { $0.id == selected } ?? visible.first }
  func open() {
    if panel?.isVisible == true {
      close()
      return
    }
    target = NSWorkspace.shared.frontmostApplication
    query = ""
    store.notice = nil
    let p = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 496, height: 400),
      styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    p.title = L("剪贴板历史")
    p.identifier = .init("glint.clipchooser")
    p.isReleasedWhenClosed = false
    p.level = .floating
    p.hidesOnDeactivate = false
    p.delegate = self
    p.contentView = NSHostingView(rootView: ClipChooserView(owner: self, store: store))
    panel = p
    p.center()
    NSApp.activate(ignoringOtherApps: true)
    p.makeKeyAndOrderFront(nil)
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self, self.panel?.isKeyWindow == true else { return e }
      return self.key(e) ? nil : e
    }
  }
  func close() { panel?.close() }
  func windowWillClose(_ notification: Notification) {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    panel = nil
  }
  func windowDidResignKey(_ notification: Notification) {
    guard let resigning = notification.object as? NSPanel else { return }
    DispatchQueue.main.async { [weak self, weak resigning] in
      if let self, let resigning, self.panel === resigning, resigning.isVisible,
        !resigning.isKeyWindow
      {
        self.close()
      }
    }
  }
  private func key(_ e: NSEvent) -> Bool {
    let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let opt = flags.contains(.option)
    let cmd = flags.contains(.command)
    let shift = flags.contains(.shift)
    let ch = e.characters(byApplyingModifiers: [])?.lowercased() ?? ""
    switch e.keyCode {
    case 43 where cmd:
      close()
      manage()
      store.showSettings = true
      return true
    case 53:
      close()
      target?.activate(options: [])
      return true
    case 125, 126:
      let rows = visible
      guard !rows.isEmpty else { return true }
      let i = rows.firstIndex { $0.id == selected } ?? 0
      selected = rows[min(rows.count - 1, max(0, i + (e.keyCode == 125 ? 1 : -1)))].id
      return true
    case 36, 76:
      if let current { choose(current, paste: opt || store.autoPaste, plain: opt && shift) }
      return true
    case 51 where opt && cmd:
      close()
      manage()
      store.clearRequest = shift
      return true
    case 51 where opt:
      if let current { store.remove(current) }
      return true
    default: break
    }
    if opt && ch == "p" && !cmd {
      if let current { store.pin(current) }
      return true
    }
    if let n = Int(ch), (1...9).contains(n), cmd || opt, n <= visible.count {
      choose(visible[n - 1], paste: opt || store.autoPaste, plain: opt && shift)
      return true
    }
    if cmd, let pinned = visible.first(where: { $0.pin == ch && !ch.isEmpty }),
      !["a", "c", "v", "x", "z", "w", "q"].contains(ch)
    {
      choose(pinned, paste: store.autoPaste, plain: false)
      return true
    }
    return false
  }
  func choose(_ e: ClipEntry, paste: Bool, plain: Bool) {
    guard store.copy(e, plain: plain) else { return }
    let original = target
    if paste && !AXIsProcessTrusted() {
      store.notice = L("已复制。自动粘贴需要辅助功能权限。按 Esc 返回原应用后可用 ⌘V 粘贴。")
      return
    }
    close()
    guard let original, !original.isTerminated else { return }
    original.activate(options: [])
    guard paste else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard original.isActive,
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
      else { return }
      down.flags = .maskCommand
      up.flags = .maskCommand
      down.postToPid(original.processIdentifier)
      up.postToPid(original.processIdentifier)
    }
  }
}
private struct ClipChooserView: View {
  @ObservedObject var owner: ClipChooser
  @ObservedObject var store: ClipboardHistory
  @FocusState private var focused: Bool
  var body: some View {
    let rows = owner.visible
    let selectedID = rows.first(where: { $0.id == owner.selected })?.id ?? rows.first?.id
    VStack(alignment: .leading, spacing: 8) {
      TextField(L("搜索剪贴板"), text: $owner.query).textFieldStyle(.roundedBorder).focused($focused)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
              Button {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                owner.choose(
                  row, paste: store.autoPaste || flags.contains(.option),
                  plain: flags.contains([.option, .shift]))
              } label: {
                HStack {
                  ClipLabel(row: row)
                  if let pin = row.pin {
                    Image(systemName: "pin.fill").foregroundStyle(ScopeTheme.yellow)
                    if !pin.isEmpty { Text("⌘" + pin.uppercased()).font(.caption2) }
                  }
                  if i < 9 { Text("⌘" + String(i + 1)).font(.caption2) }
                }
                .padding(6).background(
                  selectedID == row.id ? ScopeTheme.raised : .clear,
                  in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain).id(row.id)
            }
          }
        }.onChange(of: owner.selected) { id in if let id { reader.scrollTo(id) } }
      }
      if store.entries.isEmpty { Text(L("复制内容后即可在此搜索")).foregroundStyle(.secondary) }
      if let msg = store.notice { Text(msg).font(.caption).foregroundStyle(.secondary) }
      Divider()
      HStack {
        Text(store.autoPaste ? L("↑↓ 选择　↩ 粘贴　⇧⌥↩ 纯文本") : L("↑↓ 选择　↩ 复制　⌥↩ 粘贴")).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(L("管理记录")) {
          owner.close()
          owner.manage()
        }
      }
    }.padding(12).frame(width: 496, height: 400).background(ScopeTheme.canvas).onAppear {
      focused = true
    }
  }
}
