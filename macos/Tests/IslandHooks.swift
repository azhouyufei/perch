import Foundation
import PerchCore

// Runs with an isolated home and custom agent config directories provided by test.sh.
@main
enum IslandHookChecks {
    static func main() throws {
        let fm = FileManager.default
        precondition(ProcessInfo.processInfo.environment["PERCH_HOME"] != nil)
        let claude = HookInstaller.claudeSettings
        precondition(claude.deletingLastPathComponent().lastPathComponent == "claude config")
        try fm.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other: [String: String] = ["type": "command", "command": "my-existing-hook"]
        let original: [String: Any] = ["theme":"dark", "hooks":["Stop":[["hooks":[other]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: claude)
        for agent in HookInstaller.agents {
            try HookInstaller.install(agent)
            let installed = try Data(contentsOf: HookInstaller.file(agent))
            try HookInstaller.install(agent)
            let again = try Data(contentsOf: HookInstaller.file(agent))
            precondition(again == installed && HookInstaller.isInstalled(agent))
        }
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as! [String: Any]
        var hooks = json["hooks"] as! [String: Any]
        var stop = hooks["Stop"] as! [[String: Any]]
        var mixed = stop[1]["hooks"] as! [[String: Any]]
        // Move the other command into the group Perch added, as another hook manager might do.
        mixed.append(other); stop[1]["hooks"] = mixed; hooks["Stop"] = [stop[1]]; json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json).write(to: claude)
        for agent in HookInstaller.agents { try HookInstaller.uninstall(agent); precondition(!HookInstaller.isInstalled(agent)) }
        let cleaned = try JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as! NSDictionary
        precondition(cleaned.isEqual(to: original))

        let data = Data(#"{"session_id":"first","tool_name":"request_user_input"}"#.utf8)
        guard case .asks(let codex)? = HookEvent.parse(agent: "codex", event: "PreToolUse", body: data, requestId: "c")?.kind else { fatalError("Missing Codex request") }
        precondition(!codex.answerable && codex.kind == .question)
        let approval = Data(#"{"session_id":"second","tool_name":"Bash","tool_input":{"command":"pwd"}}"#.utf8)
        guard case .asks(let ask)? = HookEvent.parse(agent: "claude", event: "PermissionRequest", body: approval, requestId: "a")?.kind else { fatalError("Missing Claude request") }
        let body = try JSONSerialization.jsonObject(with: ask.reply("deny")) as! [String: Any]
        let payload = body["hookSpecificOutput"] as! [String: Any]
        precondition((payload["decision"] as? [String: Any])?["behavior"] as? String == "deny")
        try checkCodexThreads()
        var island = NotchMachine(projectCount: 1)
        island.send(.openSettings)
        precondition(!island.allowsDismissOnKeyLoss(settingsOpenedFromMainWindow: true))
        precondition(island.allowsDismissOnKeyLoss(settingsOpenedFromMainWindow: false))
        island.send(.hoverChanged(false)); island.send(.timeout)
        precondition(island.phase == .settings)
        island.send(.back); precondition(island.phase == .idle)
        island.send(.openSettings); island.send(.dismiss); precondition(island.phase == .idle)
        print("PASS main-window island settings survive focus transfer, hover exit and timeout, and close explicitly")
        island.send(.openOnboarding); precondition(island.phase == .onboarding)
        island.send(.dismiss); island.send(.openSwitcher); island.send(.show(0))
        precondition(island.phase == .open)
        print("PASS Island setup, real hook installation, custom config paths, Codex questions and Claude decisions")
    }
}
