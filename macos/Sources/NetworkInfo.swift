import AppKit
import Network
import SystemConfiguration

struct TrafficProcess: Identifiable {
  let id: Int32, name: String, incoming: Double, outgoing: Double
}
enum TrafficCSV {
  struct Counter { let name: String, received: Double, sent: Double }
  static func snapshot(_ text: String) -> [Int32: Counter] {
    var counters: [Int32: Counter] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      var fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      while fields.last == "" { fields.removeLast() }
      guard fields.count >= 3, let tx = Double(fields.removeLast()),
        let rx = Double(fields.removeLast()), tx >= 0, rx >= 0
      else { continue }
      // nettop may prepend a clock column to data but omit it in the CSV header.
      if fields.count > 1, let prefix = fields.first,
        prefix.isEmpty || prefix.first?.isNumber == true && prefix.contains(":")
      {
        fields.removeFirst()
      }
      let label = fields.joined(separator: ",").trimmingCharacters(
        in: CharacterSet(charactersIn: "\" "))
      guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]),
        pid > 0
      else { continue }
      let name = String(label[..<dot])
      guard !name.isEmpty, tx.isFinite, rx.isFinite else { continue }
      counters[pid] = Counter(name: name, received: rx, sent: tx)
    }
    return counters
  }
  static func rates(previous: [Int32: Counter], current: [Int32: Counter], elapsed: Double)
    -> [TrafficProcess]
  {
    guard elapsed > 0 else { return [] }
    return current.compactMap { pid, now in
      guard let last = previous[pid], last.name == now.name, now.sent >= last.sent,
        now.received >= last.received
      else { return nil }
      return TrafficProcess(
        id: pid, name: now.name, incoming: (now.received - last.received) / elapsed,
        outgoing: (now.sent - last.sent) / elapsed)
    }
  }
}
final class NetworkInfo: ObservableObject {
  static let shared = NetworkInfo()
  private var visible = 0
  private var baseline: [Int32: TrafficCSV.Counter] = [:]
  private var lastTime: TimeInterval?
  @Published var local = "—"
  @Published var interface = L("网络接口")
  @Published var publicAddress: String?
  @Published var lookingUp = false
  @Published var processes: [TrafficProcess] = []
  @Published var processState = L("等待流量样本…")
  private var timer: Timer?, process: Process?, generation = 0
  func start() {
    visible += 1
    guard timer == nil else { return }
    lastTime = nil
    baseline.removeAll()
    processes = []
    processState = L("正在测量进程网速…")
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }
  func stop() {
    visible = max(0, visible - 1)
    guard visible == 0 else { return }
    timer?.invalidate()
    timer = nil
    generation += 1
    if process?.isRunning == true { process?.terminate() }
    process = nil
  }
  private var addressCheck = -Double.infinity
  private func refreshAddress() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - addressCheck >= 10 else { return }
    addressCheck = now
    if let store = SCDynamicStoreCreate(nil, "ScopeBar" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any], let name = global["PrimaryInterface"] as? String
    {
      let service = global["PrimaryService"] as? String ?? ""
      let detail =
        SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString)
        as? [String: Any]
      let address = (detail?["Addresses"] as? [String])?.first ?? "—"
      if local != address { local = address }
      let available = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
      let type = available.first { (SCNetworkInterfaceGetBSDName($0) as String?) == name }.flatMap {
        SCNetworkInterfaceGetLocalizedDisplayName($0) as String?
      }
      let label = (type ?? name) + (type == nil ? "" : " · " + name)
      if interface != label { interface = label }
    } else {
      if local != "—" { local = "—" }
      if interface != L("未连接 IPv4") { interface = L("未连接 IPv4") }
    }
  }
  private func refresh() {
    refreshAddress()
    guard process == nil else { return }
    let p = Process()
    let pipe = Pipe()
    let version = generation
    p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    p.arguments = ["-P", "-n", "-x", "-t", "external", "-L", "1", "-J", "bytes_in,bytes_out"]
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
      processState = L("无法读取进程流量")
      return
    }
    process = p
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak p] in
      if let p, self?.process === p, p.isRunning { p.terminate() }
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      let counters = TrafficCSV.snapshot(String(decoding: data, as: UTF8.self))
      var named = counters
      for (pid, row) in counters {
        if let name = executableName(for: pid) {
          named[pid] = TrafficCSV.Counter(name: name, received: row.received, sent: row.sent)
        }
      }
      let snapshot = named
      let now = ProcessInfo.processInfo.systemUptime
      DispatchQueue.main.async {
        guard let self, self.generation == version else { return }
        self.process = nil
        guard p.terminationStatus == 0 else {
          self.processState = Lf("无法读取进程网络统计（nettop %@）", String(describing: p.terminationStatus))
          self.processes = []
          self.lastTime = nil
          return
        }
        guard !counters.isEmpty else {
          self.processState = L("本次没有可读取的网络连接")
          self.processes = []
          self.lastTime = nil
          return
        }
        if let last = self.lastTime {
          self.processes = TrafficCSV.rates(
            previous: self.baseline, current: snapshot, elapsed: now - last)
          if self.processState != L("正在建立新连接的速率基线…") { self.processState = L("正在建立新连接的速率基线…") }
        }
        self.lastTime = now
        self.baseline = snapshot
      }
    }
  }
  func lookup() {
    guard !lookingUp else { return }
    lookingUp = true
    var req = URLRequest(url: URL(string: "https://api.ipify.org")!)
    req.timeoutInterval = 6
    URLSession.shared.dataTask(with: req) { data, response, _ in
      let s =
        data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(
          in: .whitespacesAndNewlines) ?? ""
      var addr = in_addr()
      var v6 = in6_addr()
      let valid =
        (response as? HTTPURLResponse)?.statusCode == 200
        && (inet_pton(AF_INET, s, &addr) == 1 || inet_pton(AF_INET6, s, &v6) == 1)
      DispatchQueue.main.async {
        self.lookingUp = false
        self.publicAddress = valid ? s : L("查询失败，点击重试")
      }
    }.resume()
  }
  deinit {
    timer?.invalidate()
    if process?.isRunning == true { process?.terminate() }
  }
}
