import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
  case cpu, memory, download, upload, diskRead, diskWrite
  var id: Self { self }
  var title: String {
    switch self {
    case .cpu: return L("CPU 使用率")
    case .memory: return L("内存占用")
    case .download: return L("网络下载")
    case .upload: return L("网络上传")
    case .diskRead: return L("磁盘读取")
    case .diskWrite: return L("磁盘写入")
    }
  }
  var symbol: String {
    switch self {
    case .cpu: return "cpu"
    case .memory: return "memorychip"
    case .download: return "arrow.down.left"
    case .upload: return "arrow.up.right"
    case .diskRead: return "internaldrive"
    case .diskWrite: return "square.and.pencil"
    }
  }
  var color: Color {
    switch self {
    case .cpu: return ScopeTheme.download
    case .memory: return ScopeTheme.yellow
    case .download: return ScopeTheme.download
    case .upload: return ScopeTheme.upload
    case .diskRead, .diskWrite: return ScopeTheme.download
    }
  }
  var percent: Bool { self == .cpu || self == .memory }
  func format(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return percent ? String(format: "%.0f%%", value) : bytes(value) + "/s"
  }
}
func bytes(_ n: Double) -> String {
  guard n.isFinite && n >= 0 else { return "—" }
  return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .decimal)
}
struct Reading {
  let date: Date
  var values: [Metric: Double] = [:]
  var sensors: SBSensors?
  var cores: [Double] = []
  var used = -1.0, total = -1.0, available = -1.0, capacity = -1.0
  var swapUsed: Double?
  var pressure = 0
  var battery = -1, plugged = false
}
final class Monitor: ObservableObject {
  @Published private(set) var samples: [Reading] = []
  @Published var paused = false
  private let queue = DispatchQueue(label: "studio.scopebar.telemetry", qos: .utility)
  private var timer: Timer?
  private var previous: (SBMetrics, TimeInterval)?
  private var busy = false
  private var sensorSample: SBSensors?
  private var sensorTime = -Double.infinity
  var current: Reading { samples.last ?? Reading(date: Date()) }
  var interval: Double { max(1, UserDefaults.standard.double(forKey: "interval")) }
  #if PERCH_SCREENSHOTS
  func useSampleReadings(_ readings: [Reading]) { samples = readings }
  #endif
  func start() {
    timer?.invalidate()
    sample()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.sample()
    }
    timer?.tolerance = 0.2
  }
  func sample() {
    guard !paused && !busy else { return }
    busy = true
    queue.async { [weak self] in
      guard let self else { return }
      let m = sb_sample()
      let now = ProcessInfo.processInfo.systemUptime
      var r = Reading(date: Date())
      if now - self.sensorTime >= 5 {
        self.sensorSample = sb_sensors()
        self.sensorTime = now
      }
      r.sensors = self.sensorSample
      r.swapUsed = m.swapUsed >= 0 ? m.swapUsed : nil
      r.pressure = Int(m.pressure)
      if m.cpu >= 0 { r.values[.cpu] = m.cpu }
      r.used = m.memoryUsed
      r.total = m.memoryTotal
      if m.memoryTotal > 0 && m.memoryUsed >= 0 {
        r.values[.memory] = min(100, 100 * m.memoryUsed / m.memoryTotal)
      }
      r.available = m.diskFree
      r.capacity = m.diskTotal
      r.battery = Int(m.battery)
      r.plugged = m.charging != 0
      r.cores = (0..<m.cores).map { sb_core(m, $0) }
      if let (p, t) = self.previous, now > t {
        let counters: [(Metric, Double, Double)] = [
          (.download, m.received, p.received), (.upload, m.sent, p.sent),
          (.diskRead, m.diskRead, p.diskRead), (.diskWrite, m.diskWrite, p.diskWrite),
        ]
        for (metric, new, old) in counters where old >= 0 && new >= old {
          r.values[metric] = (new - old) / (now - t)
        }
      }
      self.previous = (m, now)
      DispatchQueue.main.async {
        self.busy = false
        guard !self.paused else { return }
        var history = self.samples
        if let first = history.first, first.date < r.date.addingTimeInterval(-600) {
          history.removeFirst(history.prefix { $0.date < r.date.addingTimeInterval(-600) }.count)
        }
        history.append(r)
        self.samples = history
      }
    }
  }
  deinit { timer?.invalidate() }
}
