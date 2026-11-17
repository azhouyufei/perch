import AppKit

if let mode = CommandLine.arguments.dropFirst().first,
  ["--claude-statusline", "--capture-claude-quota"].contains(mode)
{
  let input = FileHandle.standardInput.readDataToEndOfFile()
  if mode == "--capture-claude-quota" { FileHandle.standardOutput.write(input) }
  do {
    try migratePerchStorage()
    let line = try ClaudeQuota.statusLine(input, file: ClaudeQuota.file);
    if mode == "--claude-statusline" { print(line) }
  } catch { if mode == "--claude-statusline" { print("Claude Code") } }
  exit(0)
}
AppLanguage.finishRelaunch(CommandLine.arguments)
let application = NSApplication.shared
do { try migratePerchStorage() }
catch {
  NSAlert(error: error).runModal()
  exit(1)
}
let delegate = AppDelegate()
ScopeTheme.applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? ScopeTheme.defaultAppearance)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
