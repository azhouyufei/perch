import Foundation
import SQLite3

enum SessionNames {
  static func clean(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    for line in raw.prefix(4096).split(whereSeparator: \.isNewline) {
      let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !s.isEmpty else { continue }
      if s.hasPrefix("<") || s.hasPrefix("# AGENTS.md") || s.hasPrefix("You are ")
        || UUID(uuidString: s) != nil
      {
        return nil
      }
      return String(s.prefix(100))
    }
    return nil
  }
  static func prompt(_ value: Any?) -> String? {
    if let text = clean(value) { return text }
    guard let blocks = value as? [[String: Any]] else { return nil }
    return blocks.lazy.filter { ["text", "input_text"].contains($0["type"] as? String ?? "") }
      .compactMap { clean($0["text"]) }.first
  }
  static func loadOpenClaw(indices: [URL]) -> [String: String] {
    var names = [String: String]()
    for url in indices {
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        let sessions = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]]
      else { continue }
      for session in sessions.values {
        if let id = session["sessionId"] as? String,
          let name = clean(session["label"]) ?? clean(session["displayName"])
        {
          names[id] = name
        }
      }
    }
    return names
  }
  static func loadCodex(root: URL, database: URL?) -> [String: String] {
    var titles = [String: String]()
    if let database {
      var db: OpaquePointer?
      if sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(
          db, "SELECT id,substr(title,1,400) FROM threads WHERE title<>''", -1, &statement, nil)
          == SQLITE_OK
        {
          while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0),
              let title = sqlite3_column_text(statement, 1),
              let name = clean(String(cString: title))
            {
              titles[String(cString: id)] = name
            }
          }
        }
        sqlite3_finalize(statement)
      }
      sqlite3_close(db)
    }
    if let data = try? Data(
      contentsOf: root.appendingPathComponent("session_index.jsonl"), options: .mappedIfSafe)
    {
      for line in data.split(separator: 10) {
        if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let id = obj["id"] as? String, let name = clean(obj["thread_name"])
        {
          titles[id] = name
        }
      }
    }
    return titles
  }
}
extension QuotaWindow {
  var remaining: Double { 100 - percent }
  var label: String {
    minutes.isMultiple(of: 1440)
      ? Lf("%@ 天", String(describing: minutes/1440)) : minutes.isMultiple(of: 60) ? Lf("%@ 小时", String(describing: minutes/60)) : Lf("%@ 分钟", String(describing: minutes))
  }
  static func read(percent: Any?, minutes: Int, reset: Any?) -> Self? {
    guard let used = percent as? Double, (0...100).contains(used), minutes > 0,
      let end = reset as? Double, end > 0, end.isFinite
    else { return nil }
    return Self(percent: used, minutes: minutes, reset: Date(timeIntervalSince1970: end))
  }
}
enum ClaudeRoute: String {
  case direct, external, unknown

  static var configFolder: URL {
    ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
  }

  static func detect(
    environment: [String: String] = ProcessInfo.processInfo.environment, config: URL = configFolder,
    project: URL? = nil
  ) -> Self {
    var candidates = [
      config.appendingPathComponent("settings.json"),
      config.appendingPathComponent("settings.local.json"),
      URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
    ]
    if let project {
      candidates += ["settings.json", "settings.local.json"].map {
        project.appendingPathComponent(".claude/" + $0)
      }
    }
    var layers = [environment]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      guard let data = try? Data(contentsOf: url),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return .unknown }
      if let env = json["env"] as? [String: String] { layers.append(env) }
      if let provider = json["modelProvider"] as? String, provider.lowercased() != "anthropic" {
        return .external
      }
    }
    for env in layers {
      for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
      where ["1", "true"].contains(env[key]?.lowercased() ?? "") { return .external }
      if let raw = env["ANTHROPIC_BASE_URL"], !raw.isEmpty {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
          url.host?.lowercased() == "api.anthropic.com", url.port == nil || url.port == 443
        else { return .external }
      }
    }
    return .direct
  }
}
enum ClaudeQuota {
  static var file: URL { perchSupportFolder().appendingPathComponent("ClaudeQuota.json") }
  static func windows(_ event: [String: Any]) -> [QuotaWindow] {
    let info =
      event["rate_limit_info"] as? [String: Any] ?? event["rateLimitInfo"] as? [String: Any] ?? [:]
    let rates = event["rate_limits"] as? [String: Any] ?? [:]
    let unified = info["unifiedWindows"] as? [String: Any] ?? [:]
    return [("five_hour", 300), ("seven_day", 10080)].compactMap { name, minutes in
      if let w = rates[name] as? [String: Any],
        let item = QuotaWindow.read(
          percent: w["used_percentage"], minutes: minutes, reset: w["resets_at"])
      {
        return item
      }
      let w =
        unified[name] as? [String: Any] ?? (info["rateLimitType"] as? String == name ? info : [:])
      guard let used = w["utilization"] as? Double else { return nil }
      return QuotaWindow.read(percent: used * 100, minutes: minutes, reset: w["resetsAt"])
    }
  }
  static func statusLine(
    _ data: Data, file: URL, now: Date = Date(), route override: ClaudeRoute? = nil
  ) throws -> String {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let workspace = obj["workspace"] as? [String: Any]
    let project = ((workspace?["project_dir"] ?? obj["cwd"]) as? String).map {
      URL(fileURLWithPath: $0)
    }
    let route = override ?? ClaudeRoute.detect(project: project)
    let id = (obj["model"] as? [String: Any])?["id"] as? String ?? ""
    let knownModel = id.lowercased().hasPrefix("claude-")
    let windows = route == .direct && knownModel ? windows(obj) : []
    let snapshot = QuotaSample(
      date: now, windows: windows, source: windows.isEmpty ? nil : "anthropic-statusline",
      modelID: id)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    let model = (obj["model"] as? [String: Any])?["display_name"] as? String ?? "Claude Code"
    return
      ([model]
      + windows.filter { $0.reset > now }.map {
        String(format: L("%@ 剩余 %.0f%%"), $0.label, $0.remaining)
      }).joined(separator: " · ")
  }
}
