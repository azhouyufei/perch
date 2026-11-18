import AppKit
import SwiftUI
import PerchIsland

@MainActor
final class AgentAlerts: ObservableObject {
  static let shared = AgentAlerts()
  @Published private(set) var enabled = Set<String>()
  @Published var error: String?
  private let island = IslandHost.shared
  private var observer: NSObjectProtocol?
  // Migrate only the two hooks that this app previously managed with PerchAgent.
  private let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PerchAgent")
  private func command(_ action: String, _ agent: String) throws -> Bool {
    let process = Process(), output = Pipe()
    process.executableURL = bridge
    process.arguments = [action, agent]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "PerchAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text == "true"
  }

  func start() {
    observer = NotificationCenter.default.addObserver(forName: IslandHost.hooksChanged, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    for agent in ["claude", "codex"] {
      do {
        if try command("status", agent) {
          try island.setHook(agent, enabled: true)
          _ = try command("disable", agent)
        }
      } catch { self.error = error.localizedDescription }
    }
    island.restore()
    refresh()
  }
  private func refresh() {
    enabled = Set(["claude", "codex"].filter(island.installed))
  }
  func toggle(_ agent: String, _ on: Bool) {
    do { try island.setHook(agent, enabled: on); error = nil }
    catch { self.error = error.localizedDescription }
    refresh()
  }
  func open(_ destination: IslandDestination) { island.open(destination) }
  func stop() { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
struct AgentAlertSettings: View {
  @ObservedObject private var alerts = AgentAlerts.shared
  @State private var selectedTerminal = IslandHost.shared.preferredTerminal
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L("AI 会话灵动岛")).font(.headline)
      HStack {
        Button(L("打开会话")) { alerts.open(.sessions) }
        Button(L("设置向导")) { alerts.open(.setup) }
        Button(L("角色外观")) { alerts.open(.character) }
        Button(L("灵动岛设置")) { alerts.open(.settings) }
      }
      Picker(L("默认终端"), selection: $selectedTerminal) {
        Text(L("自动（最近使用）")).tag("")
        ForEach(IslandHost.shared.terminalChoices, id: \.id) { terminal in
          Text(verbatim: terminal.name).tag(terminal.id)
        }
      }.fixedSize().onChange(of: selectedTerminal) { IslandHost.shared.preferredTerminal = $0 }
      ForEach(["claude", "codex"], id: \.self) { agent in
        Toggle(agent == "claude" ? "Claude Code" : "Codex", isOn: Binding(
          get: { alerts.enabled.contains(agent) }, set: { alerts.toggle(agent, $0) }))
      }
      Text(L("通过本地 hook 提醒审批和提问。启用后请新开会话，并在 Codex 中信任该 hook。"))
        .font(.caption).foregroundStyle(.secondary)
      if let error = alerts.error { Text(verbatim: error).font(.caption).foregroundStyle(.red) }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).tile()
  }
}
