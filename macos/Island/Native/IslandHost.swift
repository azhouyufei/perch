import AppKit
import Carbon
import PerchCore

public enum IslandDestination { case setup, character, sessions, settings }

@MainActor
public final class IslandHost {
    public static let shared = IslandHost()
    public static let hooksChanged = Notification.Name("PerchIslandHooksChanged")
    private let hotkeys = HotkeyService()
    private var controller: NotchController?
    private var activity: ActivityMonitor?
    private var defaults: UserDefaults { UserDefaults.standard }

    public static func report(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
    public var terminalChoices: [(id: String, name: String)] {
        Terminals.installedOpens.map { bundle in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = url?.deletingPathExtension().lastPathComponent ?? "Terminal"
            return (bundle, bundle == Terminals.iterm ? "iTerm2" : name)
        }
    }
    public var preferredTerminal: String {
        get { Prefs.preferredTerminal ?? "" }
        set { Prefs.preferredTerminal = newValue.isEmpty ? nil : newValue }
    }
    public func installed(_ agent: String) -> Bool { HookInstaller.isInstalled(agent) }
    public func setHook(_ agent: String, enabled: Bool) throws {
        guard HookInstaller.agents.contains(agent) else { return }
        if enabled { try HookInstaller.install(agent); Prefs.enabledSources.insert(agent); start() }
        else { try HookInstaller.uninstall(agent) }
        NotificationCenter.default.post(name: Self.hooksChanged, object: nil)
    }
    public func restore() {
        guard defaults.bool(forKey: "island.started") || HookInstaller.agents.contains(where: installed) else { return }
        start()
        if let step = Prefs.resumeStep { Prefs.resumeStep = nil; controller?.startOnboarding(step: step) }
    }
    public func open(_ destination: IslandDestination) {
        start()
        controller?.openFromHost(destination == .sessions && !Prefs.onboarded ? .setup : destination)
    }
    private func start() {
        guard controller == nil else { return }
        defaults.set(true, forKey: "island.started")
        let c = NotchController(provider: RealSessionProvider())
        controller = c
        // A new session, from anywhere (Settings shows it under Open Perch). Id 4 is the open shortcut (HotkeyService.openId).
        let newSession = { [hotkeys] in
            let s = Prefs.newShortcut
            return hotkeys.register(keyCode: s.keyCode ?? kVK_ANSI_N, modifiers: s.mods.carbonFlags, id: 5) { c.openNewSession() }
        }
        var newWorks = newSession()
        c.onNewShortcutChanged = { newWorks = newSession() }
        c.newComboWorks = { newWorks }
        // While the notch says an answer or a request arrived, its buttons answer to Command+Option and a key. Only then.
        let activityCodes: [String: Int] = ["pick": kVK_Return, "open": kVK_Return, "reply": kVK_ANSI_R, "gone": kVK_ANSI_Period,
                                            "allow": kVK_ANSI_A, "deny": kVK_ANSI_X, "pick1": kVK_ANSI_1, "pick2": kVK_ANSI_2, "pick3": kVK_ANSI_3, "app": kVK_ANSI_O]
        let activityIds = Dictionary(uniqueKeysWithValues: activityCodes.keys.sorted().enumerated().map { ($1, UInt32(20 + $0)) })
        c.onActivityKeys = { [hotkeys] keys in
            for (name, id) in activityIds where !keys.contains(name) { hotkeys.unregister(id: id) }
            // Reply is Command+R, the rest Command+Option and a key.
            // A key Perch's own shortcuts already use, or that another app holds, is left alone: its button shows no key.
            let mine = [Prefs.openShortcut, Prefs.newShortcut].compactMap { s in s.kind == .combo && s.mods == [.command, .option] ? s.keyCode : nil }
            var missed: [String] = []
            for name in keys { if let code = activityCodes[name], let id = activityIds[name] {
                let mods = name == "reply" ? cmdKey : cmdKey | optionKey
                if mods == cmdKey | optionKey && mine.contains(code) { hotkeys.unregister(id: id); missed.append(name); continue }
                if !hotkeys.register(keyCode: code, modifiers: mods, id: id, action: { c.activityKey(name) }) { missed.append(name) }
            } }
            c.activityKeysMissed(missed)
        }
        c.onReplyKey = { [hotkeys] on in if on { hotkeys.register(keyCode: kVK_ANSI_R, modifiers: 0, id: 40) { c.replyKey() } } else { hotkeys.unregister(id: 40) } }
        hotkeys.onChordTap = { c.chordTap() }
        hotkeys.apply(Prefs.openShortcut)
        c.openComboWorks = { [hotkeys] in hotkeys.openCombo }
        c.onShortcutRecording = { [hotkeys] recording in if recording { hotkeys.pauseAll() } else { hotkeys.resumeAll(); hotkeys.apply(Prefs.openShortcut) } }
        c.onAccessibilityGranted = { [hotkeys] in hotkeys.restartChordMonitor() }
        hotkeys.startChordMonitor()


        let monitor = ActivityMonitor(threshold: TimeInterval(max(1, Prefs.idleMinutes) * 60))
        activity = monitor
        c.onIdleMinutesChanged = { [weak monitor] m in monitor?.threshold = TimeInterval(max(1, m) * 60) }
        monitor.onReturn = { [weak c] since in
            if Prefs.idleMinutes > 0 { c?.comeBack(proactive: true, awaySince: since) }
        }
    }
}
