import IOKit.pwr_mgt
import SwiftUI

final class AwakeSession: ObservableObject {
  static let minutes = [15, 30, 60, 120]
  static func label(_ minutes: Int) -> String {
    minutes < 60 ? Lf("%@ 分钟", String(describing: minutes)) : Lf("%@ 小时", String(describing: minutes / 60))
  }

  @Published private(set) var active = false
  @Published private(set) var endsAt: Date?
  @Published private(set) var error: String?
  private var assertion: IOPMAssertionID?
  private var timer: Timer?
  private var wakeObserver: NSObjectProtocol?
  private var deadline: ContinuousClock.Instant?

  @discardableResult func start(seconds: TimeInterval?) -> Bool {
    if let seconds, !seconds.isFinite || seconds <= 0 { return false }
    var newID = IOPMAssertionID(0)
    // powerd turns the assertion off at the deadline, even if our main loop is busy.
    let result = IOPMAssertionCreateWithDescription(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, (L("Perch · ") + L("保持唤醒")) as CFString,
      nil, nil, nil, seconds ?? 0, kIOPMAssertionTimeoutActionTurnOff as CFString, &newID)
    guard result == kIOReturnSuccess else {
      error = Lf("系统未能开启保持唤醒（%@）", String(describing: result))
      return false
    }
    stop()
    assertion = newID
    active = true
    guard let seconds else { return true }
    deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    endsAt = Date().addingTimeInterval(seconds)
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.scheduleExpiry() }
    scheduleExpiry()
    return true
  }
  static func customMinutes(_ text: String) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          (1...525600).contains(value) else { return nil }
    return value
  }
  func chooseDuration() {
    let alert = NSAlert()
    alert.messageText = L("自定义保持唤醒时长")
    alert.informativeText = L("输入分钟数（1 至 525600）。")
    let field = NSTextField(string: String(max(1, UserDefaults.standard.integer(forKey: "awake.customMinutes"))))
    field.frame.size = NSSize(width: 240, height: 24)
    field.setAccessibilityLabel(L("分钟"))
    alert.accessoryView = field
    alert.addButton(withTitle: L("开始"))
    alert.addButton(withTitle: L("取消"))
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    while alert.runModal() == .alertFirstButtonReturn {
      if let minutes = Self.customMinutes(field.stringValue) {
        if start(seconds: TimeInterval(minutes * 60)) {
          UserDefaults.standard.set(minutes, forKey: "awake.customMinutes")
        } else {
          let notice = NSAlert()
          notice.messageText = error ?? L("无法开启保持唤醒")
          notice.runModal()
        }
        return
      }
      alert.informativeText = L("请输入 1 至 525600 之间的整数。")
      field.selectText(nil)
    }
  }
  private func scheduleExpiry() {
    timer?.invalidate()
    guard let deadline else { return }
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    guard seconds > 0 else { stop(); return }
    let expiry = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.scheduleExpiry() }
    RunLoop.main.add(expiry, forMode: .common)
    timer = expiry
  }
  func stop() {
    timer?.invalidate()
    timer = nil
    if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    wakeObserver = nil
    if let assertion { IOPMAssertionRelease(assertion) }
    assertion = nil
    active = false
    deadline = nil
    endsAt = nil
    error = nil
  }
  deinit {
    timer?.invalidate()
    if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let assertion { IOPMAssertionRelease(assertion) }
  }
}

struct AwakeControl: View {
  @ObservedObject var session: AwakeSession
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "cup.and.saucer.fill").foregroundStyle(ScopeTheme.yellow)
        .font(.system(size: 18)).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(L("保持唤醒")).font(.headline)
        if let error = session.error {
          Text(error).foregroundStyle(ScopeTheme.upload).font(.caption)
        } else if let end = session.endsAt {
          HStack(spacing: 4) { Text(L("剩余")); Text(end, style: .timer).monospacedDigit() }
            .font(.caption).foregroundStyle(.secondary)
        } else if session.active {
          Text(L("直到手动结束")).font(.caption).foregroundStyle(.secondary)
        } else {
          Text(L("防止 Mac 闲置休眠，显示器可正常熄屏")).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if session.active { Button(L("立即结束")) { session.stop() } }
      Menu(!session.active ? L("选择时长") : L("重新计时")) {
        Button(L("直到手动结束")) { session.start(seconds: nil) }
        Button(L("自定义时长…")) { session.chooseDuration() }
        Divider()
        ForEach(AwakeSession.minutes, id: \.self) { minutes in
          Button(AwakeSession.label(minutes)) { session.start(seconds: Double(minutes * 60)) }
        }
      }.fixedSize()
    }.padding(14).tile()
  }
}
