import Foundation

enum AppLanguage {
  static let selectionAtLaunch = UserDefaults.standard.string(forKey: "ui.language") ?? "system"
  static func setPreferredLanguages(_ choice: String, defaults: UserDefaults = .standard) {
    if choice == "system" { defaults.removeObject(forKey: "AppleLanguages") }
    else { defaults.set([choice], forKey: "AppleLanguages") }
  }

  static func scheduleRelaunch(applying choice: String) throws {
    guard let executable = Bundle.main.executableURL else { throw CocoaError(.executableNotLoadable) }
    let next = Process()
    next.executableURL = executable
    next.arguments = ["--relaunch-after", String(getpid()), choice]
    try next.run()
  }

  static func finishRelaunch(_ arguments: [String]) {
    guard arguments.count == 4, arguments[1] == "--relaunch-after",
          ["system", "en", "zh-Hans"].contains(arguments[3]),
          let parent = Int32(arguments[2]), parent > 1 else { return }
    // Wait before initializing preferences, hotkeys or windows. Once the parent exits we are reparented.
    while getppid() == parent { Thread.sleep(forTimeInterval: 0.05) }
    // Carry the confirmed choice across the handoff even if the preferences daemon is still flushing.
    UserDefaults.standard.set(arguments[3], forKey: "ui.language")
    setPreferredLanguages(arguments[3])
  }

  static let resources: Bundle = {
    if ["en", "zh-Hans"].contains(selectionAtLaunch),
       let path = Bundle.main.path(forResource: selectionAtLaunch, ofType: "lproj"),
       let localized = Bundle(path: path) { return localized }
    return .main
  }()
}
func L(_ key: String) -> String {
  AppLanguage.resources.localizedString(forKey: key, value: key, table: nil)
}
func Lf(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: L(key), locale: Locale.current, arguments: arguments)
}
