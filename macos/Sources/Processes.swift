import AppKit

func executableName(for pid: Int32) -> String? {
  var path = [CChar](repeating: 0, count: 4096)
  let n = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
  guard n > 0 else { return nil }
  return URL(fileURLWithPath: String(cString: path)).lastPathComponent
}
struct BusyProcess: Identifiable {
  let id: Int32, name: String, cpu: Double?, memory: UInt64
}
final class ProcessMonitor: ObservableObject {
  static let shared = ProcessMonitor()
  @Published private(set) var processes: [BusyProcess] = []
  @Published private(set) var status = L("正在读取进程…")
  private let queue = DispatchQueue(label: "studio.scopebar.processes", qos: .utility)
  private var timer: DispatchSourceTimer?, visible = 0, generation = 0
  #if PERCH_SCREENSHOTS
  func useSampleProcesses(_ rows: [BusyProcess]) { processes = rows }
  #endif
  func start() {
    visible += 1
    guard timer == nil else { return }
    generation += 1
    let version = generation
    let source = DispatchSource.makeTimerSource(queue: queue)
    var cache: [Int32: (ticks: UInt64, start: UInt64, name: String)] = [:]
    var lastTime = 0.0
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let nanos = Double(tb.numer) / Double(max(1, tb.denom))
    source.setEventHandler { [weak self] in
      let count = proc_listallpids(nil, 0)
      var pids = [Int32](repeating: 0, count: max(Int(count) + 128, 256))
      let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
      let now = ProcessInfo.processInfo.systemUptime
      var next: [Int32: (UInt64, UInt64, String)] = [:]
      var rows: [BusyProcess] = []
      for pid in pids.prefix(min(max(0, Int(found)), pids.count)) where pid > 0 {
        var usage = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &usage) {
          $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
          }
        }
        guard rc == 0 else { continue }
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        let stamp = usage.ri_proc_start_abstime
        let old = cache[pid]
        var pct: Double?
        var label: String
        if let old, old.start == stamp {
          label = old.name
          if ticks >= old.ticks, now > lastTime {
            pct = 100 * Double(ticks - old.ticks) * nanos / (1e9 * (now - lastTime))
          }
        } else if let fullName = executableName(for: pid) {
          label = fullName
        } else {
          var chars = [CChar](repeating: 0, count: 1024)
          let len = chars.withUnsafeMutableBytes {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
          }
          label = len > 0 ? String(cString: chars) : "PID \(pid)"
        }
        next[pid] = (ticks, stamp, label)
        rows.append(BusyProcess(id: pid, name: label, cpu: pct, memory: usage.ri_phys_footprint))
      }
      cache = next
      lastTime = now
      DispatchQueue.main.async {
        guard let self, self.generation == version else { return }
        self.processes = rows
        let status = found < 1 ? L("系统未提供进程列表") : L("当前用户没有可读取的进程")
        if self.status != status { self.status = status }
      }
    }
    source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
    timer = source
    source.resume()
  }
  func stop() {
    visible = max(0, visible - 1)
    if visible == 0 {
      generation += 1
      timer?.cancel()
      timer = nil
    }
  }
  deinit { timer?.cancel() }
}
