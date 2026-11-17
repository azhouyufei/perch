import Carbon
import SwiftUI

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
  case capture = 1
  case paste, togglePins, clipboard
  var id: Self { self }
  var title: String {
    switch self {
    case .clipboard: return L("剪贴板历史")
    case .capture: return L("区域截图")
    case .paste: return L("剪贴板贴图")
    case .togglePins: return L("隐藏 / 显示全部贴图")
    }
  }
  var standard: BindingKey {
    if self == .clipboard { return BindingKey(code:UInt32(kVK_ANSI_C),flags:UInt32(cmdKey | shiftKey)) }
    return BindingKey(
      code: UInt32(self == .capture ? kVK_F1 : kVK_F3),
      flags: self == .togglePins ? UInt32(shiftKey) : 0)
  }
  var alternate: BindingKey {
    if self == .clipboard { return BindingKey(code:UInt32(kVK_ANSI_C),flags:UInt32(controlKey | optionKey)) }
    return BindingKey(
      code: UInt32(self == .capture ? kVK_ANSI_4 : kVK_ANSI_V),
      flags: UInt32(controlKey | optionKey) | (self == .togglePins ? UInt32(shiftKey) : 0))
  }
  func candidates(preferred: BindingKey) -> [BindingKey] {
    let code = alternate.code
    let extra = UInt32(self == .togglePins ? shiftKey : 0)
    let modifiers = [cmdKey | optionKey, controlKey | cmdKey, controlKey | optionKey | cmdKey]
    let options =
      [preferred, standard, alternate]
      + modifiers.map { BindingKey(code: code, flags: UInt32($0) | extra) }
    return options.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }

}
struct BindingKey: Codable, Equatable {
  let code: UInt32
  let flags: UInt32
  var label: String {
    let prefix = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")].compactMap {
      flags & UInt32($0.0) != 0 ? $0.1 : nil
    }.joined()
    if let index = Self.functions.firstIndex(of: Int(code)) {
      return prefix + "F" + String(index + 1)
    }
    let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
    if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
      let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
      let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(
        to: UCKeyboardLayout.self)
      var dead: UInt32 = 0
      var count = 0
      var chars = [UniChar](repeating: 0, count: 8)
      if UCKeyTranslate(
        layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit), &dead, 8, &count, &chars) == noErr, count > 0
      {
        return prefix + String(utf16CodeUnits: chars, count: count).uppercased()
      }
    }
    return prefix + "Key " + String(code)
  }
  static let functions = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
    kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
  ]
  init(code: UInt32, flags: UInt32) {
    self.code = code
    self.flags = flags
  }
  init?(event: NSEvent) {
    let m = event.modifierFlags
    var flags: UInt32 = 0
    for (flag, mask) in [
      (NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey),
      (.shift, shiftKey),
    ] where m.contains(flag) { flags |= UInt32(mask) }
    guard
      Self.functions.contains(Int(event.keyCode))
        || flags & UInt32(cmdKey | controlKey | optionKey) != 0
    else { return nil }
    self.init(code: UInt32(event.keyCode), flags: flags)
  }
}
final class HotKeys: ObservableObject {
  @Published private(set) var active: [ShortcutAction: BindingKey] = [:]
  @Published var messages: [ShortcutAction: String] = [:]
  @Published var recording: ShortcutAction?
  private var refs: [ShortcutAction: EventHotKeyRef] = [:], handler: EventHandlerRef?
  private var monitor: Any?
  var action: ((ShortcutAction) -> Void)?
  private func stored(_ a: ShortcutAction) -> BindingKey {
    guard let d = UserDefaults.standard.data(forKey: "shortcut.\(a.rawValue)"),
      let b = try? JSONDecoder().decode(BindingKey.self, from: d)
    else { return a.standard }
    return b
  }
  #if PERCH_SCREENSHOTS
  func previewDefaults() { for action in ShortcutAction.allCases { active[action] = action.standard } }
  #endif
  func install() {
    guard handler == nil else { return }
    var t = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, ref in
        guard let event, let ref else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard
          GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x5343_4252,
          let a = ShortcutAction(rawValue: id.id)
        else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<HotKeys>.fromOpaque(ref).takeUnretainedValue()
        if owner.recording == nil { owner.action?(a) }
        return noErr
      }, 1, &t, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else {
      for a in ShortcutAction.allCases { messages[a] = L("系统未能安装快捷键处理器") }
      return
    }
    // Reserve saved combinations before assigning fallbacks to another action.
    for a in ShortcutAction.allCases { _ = register(stored(a), a) }
    for a in ShortcutAction.allCases where active[a] == nil {
      let desired = stored(a)
      if let key = a.candidates(preferred: desired).first(where: { register($0, a) }) {
        messages[a] = Lf("%@ 已占用，当前使用 %@", String(describing: desired.label), String(describing: key.label))
      } else {
        messages[a] = L("快捷键已占用，请重新录制")
      }
    }

  }
  private func register(_ key: BindingKey, _ a: ShortcutAction) -> Bool {
    if active[a] == key { return true }
    guard !active.values.contains(key) else { return false }
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: 0x5343_4252, id: a.rawValue)
    guard
      RegisterEventHotKey(
        key.code, key.flags, id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        == noErr, let ref
    else { return false }
    if let old = refs[a] { UnregisterEventHotKey(old) }
    refs[a] = ref
    active[a] = key
    return true
  }
  func assign(_ key: BindingKey, to a: ShortcutAction) {
    guard register(key, a) else {
      messages[a] = Lf("%@ 已被占用，原绑定继续生效", String(describing: key.label))
      return
    }
    UserDefaults.standard.set(try? JSONEncoder().encode(key), forKey: "shortcut.\(a.rawValue)")
    messages[a] = nil
  }
  func record(_ a: ShortcutAction) {
    stopRecording()
    recording = a
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self else { return e }
      if e.keyCode == 53 {
        self.stopRecording()
        return nil
      }
      guard let b = BindingKey(event: e) else {
        self.messages[a] = L("请使用功能键或带 ⌘、⌃、⌥ 的组合")
        return nil
      }
      self.stopRecording()
      self.assign(b, to: a)
      return nil
    }
  }
  func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = nil
  }
  func label(_ a: ShortcutAction) -> String { active[a]?.label ?? L("未绑定") }
  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    refs.values.forEach { UnregisterEventHotKey($0) }
    if let handler { RemoveEventHandler(handler) }
  }
}
struct ShortcutEditor: View {
  @ObservedObject var keys: HotKeys
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(ShortcutAction.allCases) { a in
        VStack(alignment: .trailing, spacing: 2) {
          HStack {
            Text(a.title)
            Spacer()
            Button(keys.recording == a ? L("请按新快捷键…") : keys.label(a)) { keys.record(a) }.frame(
              minWidth: 76)
            Button {
              keys.assign(a.standard, to: a)
            } label: {
              Image(systemName: "arrow.counterclockwise")
            }.help(L("恢复 ") + a.standard.label)
          }
          if let message = keys.messages[a] {
            Text(message).font(.caption).foregroundStyle(.orange)
          }
        }
      }
      Text(L("功能键控制亮度或调度中心时，请同时按住 fn。录制时按 Esc 取消。")).font(.caption).foregroundStyle(.secondary)
    }.onDisappear { keys.stopRecording() }
  }
}
