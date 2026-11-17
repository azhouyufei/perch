import ServiceManagement
import SwiftUI

struct StartupPreferences: View {
  @AppStorage("ui.language") private var language = "system"
  @State private var status = SMAppService.mainApp.status
  @State private var updating = false
  @State private var failure: String?
  @State private var confirmRestart = false
  @State private var restartError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L("界面语言"))
        Spacer()
        Picker(L("界面语言"), selection: $language) {
          Text(L("跟随系统")).tag("system")
          Text(verbatim: "简体中文").tag("zh-Hans")
          Text(verbatim: "English").tag("en")
        }.labelsHidden().fixedSize()
        .onChange(of: language) { choice in
          AppLanguage.setPreferredLanguages(choice)
          confirmRestart = choice != AppLanguage.selectionAtLaunch
        }
      }
      if language != AppLanguage.selectionAtLaunch {
        HStack {
          Text(L("重新打开 Perch 后应用语言设置。")).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(L("立即重启")) { confirmRestart = true }.fixedSize()
        }
        if let restartError { Text(restartError).font(.caption).foregroundStyle(.secondary) }
      }
      Divider()
      Toggle(L("登录 Mac 时自动启动"), isOn: Binding(
        get: { status == .enabled || status == .requiresApproval },
        set: { enabled in
          updating = true
          Task { @MainActor in
            defer { status = SMAppService.mainApp.status; updating = false }
            do {
              if enabled { try SMAppService.mainApp.register() }
              else { try await SMAppService.mainApp.unregister() }
              failure = nil
            } catch { failure = error.localizedDescription }
          }
        })).disabled(updating)
      if status == .requiresApproval || failure != nil {
        HStack {
          Text(failure ?? L("请在系统登录项中允许 Perch 自动启动。")).font(.caption)
          Spacer()
          Button(L("打开登录项")) { SMAppService.openSystemSettingsLoginItems() }
        }
      }
    }.padding(16).tile()
      .alert(L("现在重启 Perch 以切换语言？"), isPresented: $confirmRestart) {
        Button(L("立即重启")) {
          do {
            try AppLanguage.scheduleRelaunch(applying: language)
            NSApp.terminate(nil)
          } catch { restartError = error.localizedDescription }
        }
        Button(L("稍后"), role: .cancel) {}
      } message: {
        Text(L("语言选择已保存。你也可以继续使用，新的语言会在下次打开时生效。"))
      }
      .onAppear { status = SMAppService.mainApp.status }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        status = SMAppService.mainApp.status
      }
  }
}
