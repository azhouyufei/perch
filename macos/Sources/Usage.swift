import Combine
import Foundation

struct UsageAmount: Codable, Equatable {
  var input = 0, cached = 0, output = 0
  var reasoning: Int? = nil, cacheWrite: Int? = nil
  var total: Int { input + output }
  private static func combine(_ a: Int?, _ b: Int?, _ op: (Int, Int) -> Int) -> Int? {
    a == nil && b == nil ? nil : op(a ?? 0, b ?? 0)
  }
  static func + (a: Self, b: Self) -> Self {
    Self(
      input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output,
      reasoning: combine(a.reasoning, b.reasoning, +),
      cacheWrite: combine(a.cacheWrite, b.cacheWrite, +))
  }
  static func - (a: Self, b: Self) -> Self {
    Self(
      input: a.input - b.input, cached: a.cached - b.cached, output: a.output - b.output,
      reasoning: combine(a.reasoning, b.reasoning, -),
      cacheWrite: combine(a.cacheWrite, b.cacheWrite, -))
  }
}
enum UsageTool: String, CaseIterable, Identifiable {
  case all = "全部"
  case codex = "Codex"
  case claude = "Claude Code"
  case openClaw = "OpenClaw"
  var id: Self { self }
  var showsCodexQuota: Bool { self == .all || self == .codex }
  var menuLabel: String {
    switch self {
    case .all: return "TOKENS"
    case .codex: return "CODEX"
    case .claude: return "CLAUDE"
    case .openClaw: return "CLAW"
    }
  }
  func filter(_ rows: [UsageRow]) -> [UsageRow] {
    self == .all ? rows : rows.filter { $0.tool == rawValue }
  }
}
struct UsageRow: Identifiable {
  var id: String {
    [tool, session, String(date.timeIntervalSince1970), model].joined(separator: "/")
  }
  let date: Date, tool: String, session: String, model: String, project: String, amount: UsageAmount
  var title: String = L("未命名会话")
  var total: Int { amount.total }
}
enum RecordedUsage {
  static func inRange(_ rows: [UsageRow], days: Int, now: Date = Date(), calendar: Calendar = .current) -> [UsageRow] {
    guard days > 0 else { return [] }
    let today = calendar.startOfDay(for: now)
    guard let start = calendar.date(byAdding: .day, value: 1 - days, to: today),
      let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
    return rows.filter { $0.date >= start && $0.date < end }
  }
  /// No readable observations is not evidence of zero account consumption.
  static func total(_ rows: [UsageRow]) -> Int? {
    rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.total }
  }
  static func display(_ rows: [UsageRow]) -> String {
    total(rows).map(shortTokens) ?? "—"
  }
}
struct QuotaWindow: Codable {
  let percent: Double, minutes: Int, reset: Date
}
struct QuotaSample: Codable {
  let date: Date, windows: [QuotaWindow]
  var source: String? = nil, modelID: String? = nil
  func verifiedClaude(for route: ClaudeRoute) -> Self? {
    guard route == .direct, source == "anthropic-statusline",
      modelID?.lowercased().hasPrefix("claude-") == true
    else { return nil }
    return self
  }
}
private struct Bucket: Codable {
  let day: Date, model: String
  var amount: UsageAmount
}
struct UsageFile: Codable {
  var offset: UInt64 = 0, inode: UInt64 = 0
  var model = "未记录", project = "", session = ""
  var title: String?, firstPrompt: String?, automaticTitle: String?
  var previous: UsageAmount?
  private var buckets: [String: Bucket] = [:]
  private struct Receipt: Codable { let key: String, amount: UsageAmount }
  private var receipts: [String: Receipt] = [:]
  var quota: QuotaSample?
  private static let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let whole = ISO8601DateFormatter()
  mutating func consume(_ line: Data, tool: String) {
    let prefix = line.prefix(500)
    var candidates =
      tool == "Codex"
      ? ["\"session_meta\"", "\"turn_context\"", "\"token_count\""]
      : tool == "OpenClaw" ? ["\"session\"", "\"session_info\"", "\"assistant\""] : ["\"assistant\""]
    candidates += [
      "\"custom-title\"", "\"ai-title\"", "\"thread_name_updated\"", "\"rate_limit_event\"",
    ]
    if firstPrompt == nil { candidates += ["\"user_message\"", "\"user\""] }
    guard
      candidates.contains(where: { prefix.range(of: Data($0.utf8)) != nil })
        || (tool != "Codex" && line.range(of: Data("\"usage\"".utf8)) != nil)
    else { return }
    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      let type = obj["type"] as? String
    else { return }
    let p = obj["payload"] as? [String: Any] ?? [:]
    if tool == "Claude Code" {
      if type == "custom-title" { title = SessionNames.clean(obj["customTitle"]); return }
      if type == "ai-title" { automaticTitle = SessionNames.clean(obj["aiTitle"]); return }
      if type == "user", obj["isMeta"] as? Bool != true, firstPrompt == nil {
        firstPrompt = SessionNames.prompt((obj["message"] as? [String: Any])?["content"]); return
      }
    }
    if tool == "Codex", type == "event_msg" {
      if p["type"] as? String == "thread_name_updated" {
        title = SessionNames.clean(p["thread_name"]); return
      }
      if p["type"] as? String == "user_message", firstPrompt == nil {
        firstPrompt = SessionNames.prompt(p["message"]); return
      }
    }
    if tool == "OpenClaw", firstPrompt == nil, let m = obj["message"] as? [String: Any],
      m["role"] as? String == "user"
    {
      firstPrompt = SessionNames.prompt(m["content"]); return
    }
    if tool == "OpenClaw", type == "session_info" {
      title=SessionNames.clean(obj["name"]) ?? title
      return
    }
    if tool == "OpenClaw", type == "session" {
      session = obj["id"] as? String ?? session
      project = Self.basename(obj["cwd"])
      return
    }
    if type == "session_meta" {
      session = (p["id"] as? String) ?? session
      title = SessionNames.clean(p["thread_name"]) ?? title
      project = Self.basename(p["cwd"])
      return
    }
    if type == "turn_context" {
      model = p["model"] as? String ?? model
      return
    }
    guard let stamp = obj["timestamp"] as? String,
      let date = Self.iso.date(from: stamp) ?? Self.whole.date(from: stamp)
    else { return }
    if tool == "Claude Code", type == "rate_limit_event" {
      let windows = ClaudeQuota.windows(obj)
      if !windows.isEmpty { quota = QuotaSample(date: date, windows: windows) }
      return
    }
    let day = Calendar.current.startOfDay(for: date)
    var amount: UsageAmount
    var messageID: String?
    if tool == "Codex" {
      guard type == "event_msg", p["type"] as? String == "token_count" else { return }
      if let limits = p["rate_limits"] as? [String: Any],
        (limits["limit_id"] as? String ?? "codex") == "codex"
      {
        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
          guard let w = limits[key] as? [String: Any], let percent = w["used_percent"] as? Double,
            let minutes = (w["window_minutes"] ?? w["window_duration_mins"]) as? Int,
            let reset = w["resets_at"] as? Double
          else { return nil }
          return QuotaWindow.read(percent: percent, minutes: minutes, reset: reset)
        }
        if !windows.isEmpty { quota = QuotaSample(date: date, windows: windows) }
      }
      guard let info = p["info"] as? [String: Any],
        let counts = info["total_token_usage"] as? [String: Any]
      else { return }
      func parse(_ d: [String: Any]) -> UsageAmount {
        UsageAmount(
          input: d["input_tokens"] as? Int ?? 0, cached: d["cached_input_tokens"] as? Int ?? 0,
          output: d["output_tokens"] as? Int ?? 0, reasoning: d["reasoning_output_tokens"] as? Int)
      }
      let cumulative = parse(counts)
      let last = (info["last_token_usage"] as? [String: Any]).map(parse)
      var delta = previous.map { cumulative - $0 }
      if let old = previous,
        old.reasoning == nil || cumulative.reasoning == nil || (delta?.reasoning ?? 0) < 0
      {
        delta?.reasoning = last?.reasoning
      }
      previous = cumulative
      if let delta, delta.input >= 0, delta.output >= 0, delta.cached >= 0 {
        amount = delta
      } else {
        amount = last ?? cumulative
      }
    } else if tool == "OpenClaw" {
      guard type == "message", let message = obj["message"] as? [String: Any],
        message["role"] as? String == "assistant", let usage = message["usage"] as? [String: Any]
      else { return }
      let hit = usage["cacheRead"] as? Int ?? 0
      amount = UsageAmount(
        input: (usage["input"] as? Int ?? 0) + hit + (usage["cacheWrite"] as? Int ?? 0),
        cached: hit, output: usage["output"] as? Int ?? 0, cacheWrite: usage["cacheWrite"] as? Int)
      model = message["model"] as? String ?? "未记录"
      messageID = obj["id"] as? String
    } else {
      guard type == "assistant", let m = obj["message"] as? [String: Any],
        let u = m["usage"] as? [String: Any], let id = m["id"] as? String
      else { return }
      let hit = u["cache_read_input_tokens"] as? Int ?? 0
      amount = UsageAmount(
        input: (u["input_tokens"] as? Int ?? 0) + hit
          + (u["cache_creation_input_tokens"] as? Int ?? 0), cached: hit,
        output: u["output_tokens"] as? Int ?? 0,
        cacheWrite: u["cache_creation_input_tokens"] as? Int)
      model = m["model"] as? String ?? "未记录"
      project = Self.basename(obj["cwd"])
      messageID = id
    }
    guard amount.total > 0 else { return }
    let key = String(Int(day.timeIntervalSince1970)) + "/" + model
    if let messageID {
      if let old = receipts[messageID] {
        if old.amount == amount { return }
        if var bucket = buckets[old.key] {
          bucket.amount = bucket.amount - old.amount
          buckets[old.key] = bucket
        }
      }
      receipts[messageID] = Receipt(key: key, amount: amount)
    }
    var b = buckets[key] ?? Bucket(day: day, model: model, amount: UsageAmount())
    b.amount = b.amount + amount
    buckets[key] = b
  }
  private static func basename(_ v: Any?) -> String {
    (v as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
  }
  func rows(tool: String, path: String, names: [String: String] = [:]) -> [UsageRow] {
    let id =
      session.isEmpty
      ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : session
    let earliest = buckets.values.map(\.day).min()
    let fallback =
      [project.isEmpty ? tool : project, earliest?.formatted(date: .abbreviated, time: .omitted)]
      .compactMap { $0 }.joined(separator: " · ") + L(" 会话")
    let displayName = names[id] ?? title ?? automaticTitle ?? firstPrompt ?? fallback
    return buckets.values.filter { $0.amount.total > 0 }.map {
      UsageRow(
        date: $0.day, tool: tool, session: id, model: $0.model, project: project, amount: $0.amount,
        title: displayName)
    }
  }
  var checkedLegacyTitle: Bool?
  mutating func backfillTitle(url: URL, tool: String, size: UInt64) {
    guard tool == "Claude Code", title == nil, automaticTitle == nil, firstPrompt == nil,
      checkedLegacyTitle != true, offset > 0, let f = try? FileHandle(forReadingFrom: url)
    else { return }
    defer { try? f.close() }; checkedLegacyTitle = true
    for start in Set([UInt64(0), size > 131072 ? size - 131072 : 0]).sorted() {
      try? f.seek(toOffset: start)
      guard let data = try? f.read(upToCount: 131072) else { continue }
      for line in data.split(separator: 10) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
          continue
        }
        switch obj["type"] as? String {
        case "custom-title": title = SessionNames.clean(obj["customTitle"]) ?? title
        case "ai-title": automaticTitle = SessionNames.clean(obj["aiTitle"]) ?? automaticTitle
        case "user" where firstPrompt == nil && obj["isMeta"] as? Bool != true:
          firstPrompt = SessionNames.prompt((obj["message"] as? [String: Any])?["content"])
        default: break
        }
      }
    }
  }
  mutating func update(url: URL, tool: String, size: UInt64, node: UInt64) throws {
    if node != inode || size < offset {
      self = UsageFile()
      inode = node
    }
    guard size > offset else { return }
    let f = try FileHandle(forReadingFrom: url)
    defer { try? f.close() }
    try f.seek(toOffset: offset)
    var pending = Data()
    while let chunk = try f.read(upToCount: 256 * 1024), !chunk.isEmpty {
      autoreleasepool {
        var begin = chunk.startIndex
        while let newline = chunk[begin...].firstIndex(of: 10) {
          if pending.isEmpty {
            consume(chunk[begin..<newline], tool: tool)
          } else {
            pending.append(chunk[begin..<newline])
            consume(pending, tool: tool)
          }
          offset += UInt64(pending.isEmpty ? newline - begin + 1 : pending.count + 1)
          pending.removeAll(keepingCapacity: false)
          begin = newline + 1
        }
        pending.append(chunk[begin...])
      }
    }
  }
}
final class UsageStore: ObservableObject {
  @Published var tool =
    UsageTool(rawValue: UserDefaults.standard.string(forKey: "usage.tool") ?? "") ?? .all
  {
    didSet { UserDefaults.standard.set(tool.rawValue, forKey: "usage.tool") }
  }
  @Published private(set) var rows: [UsageRow] = []
  @Published private(set) var quota: QuotaSample?
  @Published private(set) var codexQuotaStatus = L("正在查询 Codex 账户额度…")
  @Published private(set) var claudeQuota: QuotaSample?
  @Published private(set) var claudeRoute = ClaudeRoute.unknown
  @Published private(set) var status = L("正在读取本机会话…")
  @Published private(set) var scanning = false
  private let queue = DispatchQueue(label: "glint.usage", qos: .utility)
  private let quotaQueue = DispatchQueue(label: "perch.codex-quota", qos: .utility)
  private var quotaRefreshing = false
  private var lastQuotaRequest = Date.distantPast
  private var quotaGeneration = 0
  private var timer: Timer?
  private var files: [String: UsageFile] = [:]
  private var titleSources = [String]()
  private var clawNames=[String:String]()
  private var codexNames = [String: String]()
  private var lastRoute: ClaudeRoute?
  private var lastScanComplete = false
  private var loaded = false
  private var consumers = 0
  private let folder: URL
  private var cache: URL { folder.appendingPathComponent("Usage-v4.json") }
  init(folder: URL = perchSupportFolder()) { self.folder = folder }

  #if PERCH_SCREENSHOTS
  private var hasSampleData = false
  func useSampleRows(_ samples: [UsageRow]) {
    rows = samples
    status = "\(samples.count) sample sessions"
    hasSampleData = true
  }
  #endif

  static func restore(folder: URL) -> [String: UsageFile] {
    func read(_ version: Int) -> [String: UsageFile]? {
      let file = folder.appendingPathComponent("Usage-v" + String(version) + ".json")
      guard let data = try? Data(contentsOf: file) else { return nil }
      return try? JSONDecoder().decode([String: UsageFile].self, from: data)
    }
    if let current = read(4) { return current }
    var result = [String: UsageFile]()
    for version in 1...3 {
      if let previous = read(version) { result.merge(previous) { _, latest in latest } }
    }
    return result
  }
  func start() {
    consumers += 1
    guard timer == nil else { return }
    refresh(forceQuota: true)
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }
  func stop() {
    consumers = max(0, consumers - 1)
    guard consumers == 0 else { return }
    timer?.invalidate()
    timer = nil
    quotaGeneration += 1
    quota = nil
    queue.async { [self] in
      files.removeAll()
      codexNames.removeAll()
      clawNames.removeAll()
      titleSources.removeAll()
      loaded = false
    }
  }
  private func refreshCodexQuota(force: Bool) {
    guard !quotaRefreshing, force || Date().timeIntervalSince(lastQuotaRequest) >= 60 else { return }
    quotaRefreshing = true
    lastQuotaRequest = Date()
    let generation = quotaGeneration
    if quota == nil { codexQuotaStatus = L("正在查询 Codex 账户额度…") }
    quotaQueue.async { [weak self] in
      let result = CodexQuota.fetch()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.quotaRefreshing = false
        guard generation == self.quotaGeneration else {
          if self.consumers > 0 { self.refreshCodexQuota(force: true) }
          return
        }
        switch result {
        case .success(let sample):
          self.quota = sample
          self.codexQuotaStatus = L("Codex 当前登录账户 · ")
            + sample.date.formatted(date: .omitted, time: .shortened)
        case .failure(let error):
          // Never replace a failed account read with another account's transcript snapshot.
          self.quota = nil
          self.codexQuotaStatus = error == .missingCLI
            ? L("未找到 Codex，请安装或更新 Codex 后重试")
            : L("Codex 额度暂不可用，请检查 Codex 登录状态和网络")
        }
      }
    }
  }
  func refresh(forceQuota: Bool = false) {
    #if PERCH_SCREENSHOTS
    if hasSampleData { return }
    #endif
    refreshCodexQuota(force: forceQuota)
    guard !scanning else { return }
    scanning = true
    queue.async { [self] in
      let fm = FileManager.default
      let initialScan = !loaded
      if !loaded {
        loaded = true
        files = Self.restore(folder: folder)
      }
      let base = fm.homeDirectoryForCurrentUser
      let codex =
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? base.appendingPathComponent(".codex")
      var roots = [
        ("Codex", codex.appendingPathComponent("sessions")),
        ("Codex", codex.appendingPathComponent("archived_sessions")),
        (
          "Claude Code",
          (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? base.appendingPathComponent(".claude")).appendingPathComponent("projects")
        ),
      ]
      let stateDir =
        ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? base.appendingPathComponent(".openclaw")
      let agents = stateDir.appendingPathComponent("agents")
      if let dirs = try? fm.contentsOfDirectory(
        at: agents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      {
        roots += dirs.map { ("OpenClaw", $0.appendingPathComponent("sessions")) }
      }
      func origin(_ path: String) -> String? {
        roots.first { path.hasPrefix($0.1.path + "/") }?.0
      }
      func mergedRows() -> [UsageRow] {
        var unique = [String: UsageRow]()
        for (path, state) in files {
          guard let tool = origin(path) else { continue }
          let titles = tool == "Codex" ? codexNames : tool == "OpenClaw" ? clawNames : [:]
          for row in state.rows(tool: tool, path: path, names: titles)
          where row.total >= (unique[row.id]?.total ?? 0) { unique[row.id] = row }
        }
        return Array(unique.values)
      }
      if initialScan && !files.isEmpty {
        let cached = mergedRows()
        DispatchQueue.main.async {
          self.rows = cached; self.status = L("已恢复历史，正在检查新增记录…")
        }
      }
      let route = ClaudeRoute.detect()
      let stateDB = (try? fm.contentsOfDirectory(at: codex, includingPropertiesForKeys: nil))?
        .filter {
          $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression)
            != nil
        }.max {
          $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
      let clawIndices = roots.filter{$0.0=="OpenClaw"}.map{$0.1.appendingPathComponent("sessions.json")}.sorted{$0.path<$1.path}
      let codexIndices:[URL?] = [
        codex.appendingPathComponent("session_index.jsonl"), stateDB,
        stateDB.map { URL(fileURLWithPath: $0.path + "-wal") }
      ]
      let external = (codexIndices.compactMap{$0}+clawIndices+[ClaudeQuota.file]).map { u in
        let a = try? fm.attributesOfItem(atPath: u.path)
        return u.path + "|" + String((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
          + "|" + String((a?[.size] as? NSNumber)?.intValue ?? 0)
      }
      let metadataChanged = external != titleSources || lastRoute != route
      lastRoute = route
      if initialScan || external.dropLast() != titleSources.dropLast() {
        clawNames=SessionNames.loadOpenClaw(indices:clawIndices)
        codexNames = SessionNames.loadCodex(root: codex, database: stateDB)
      }
      titleSources = external
      var changed = initialScan && !fm.fileExists(atPath: cache.path)
      var errors = 0
      for (tool, root) in roots where fm.fileExists(atPath: root.path) {
        let entries = fm.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
          errorHandler: { _, _ in
            errors += 1
            return true
          })
        while let u = entries?.nextObject() as? URL {
          guard u.pathExtension == "jsonl" else { continue }
          do {
            let a = try fm.attributesOfItem(atPath: u.path)
            guard a[.type] as? FileAttributeType == .typeRegular,
              let size = (a[.size] as? NSNumber)?.uint64Value,
              let node = (a[.systemFileNumber] as? NSNumber)?.uint64Value
            else { continue }
            var state = files[u.path] ?? UsageFile()
            let checked = state.checkedLegacyTitle
            state.backfillTitle(url: u, tool: tool, size: size)
            if checked != state.checkedLegacyTitle { files[u.path] = state; changed = true }
            if state.offset != size || state.inode != node {
              try state.update(url: u, tool: tool, size: size, node: node)
              files[u.path] = state
              changed = true
            }
          } catch { errors += 1 }
        }
      }
      // Already indexed totals remain available when the CLI archives or prunes a transcript.
      let previouslyComplete = lastScanComplete
      lastScanComplete = errors == 0
      if previouslyComplete && !initialScan && !changed && !metadataChanged && errors == 0 {
        DispatchQueue.main.async {
          self.status = self.rows.isEmpty ? L("未发现含用量记录的本地 AI 会话") : L("已更新 · ") + Date().formatted(date: .omitted, time: .shortened)
          self.scanning = false
        }
        return
      }
      if changed, let d = try? JSONEncoder().encode(files) {
        try? fm.createDirectory(
          at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: cache, options: .atomic)
      }
      let rows = mergedRows()
      let bridged = (try? Data(contentsOf: ClaudeQuota.file)).flatMap {
        try? JSONDecoder().decode(QuotaSample.self, from: $0)
      }
      let claude = bridged?.verifiedClaude(for: route)
      let status =
        errors > 0
        ? Lf("有 %@ 个位置暂时无法读取", String(describing: errors))
        : rows.isEmpty
          ? L("未发现含用量记录的 本地 AI 会话") : L("已更新 · ") + Date().formatted(date: .omitted, time: .shortened)
      DispatchQueue.main.async {
        self.rows = rows
        self.claudeRoute = route
        self.claudeQuota = claude
        self.status = status
        self.scanning = false
      }
    }
  }
}
func shortTokens(_ n: Int) -> String {
  if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1e9) }
  if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1e6) }
  if n >= 1000 { return String(format: "%.1fK", Double(n) / 1e3) }
  return String(n)
}
