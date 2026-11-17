import SwiftUI

private struct ProcessTablesVisibleKey: EnvironmentKey {
  static let defaultValue = true
}
extension EnvironmentValues {
  var processTablesVisible: Bool {
    get { self[ProcessTablesVisibleKey.self] }
    set { self[ProcessTablesVisibleKey.self] = newValue }
  }
}
enum LedgerKind { case resources, network }
struct LedgerEntry: Identifiable {
  let id: Int32, name: String, first: Double?, second: Double
}
extension LedgerEntry {
  static func precedes(_ lhs: Self, _ rhs: Self, column: Int, descending: Bool) -> Bool {
    let a = column == 0 ? lhs.first : lhs.second
    let b = column == 0 ? rhs.first : rhs.second
    if let a, let b, a != b { return descending ? a > b : a < b }
    if (a == nil) != (b == nil) { return a != nil }
    return lhs.id < rhs.id
  }
}
struct ProcessLedger: View {
  let kind: LedgerKind
  var compact = false
  @ObservedObject private var cpu = ProcessMonitor.shared
  @ObservedObject private var net = NetworkInfo.shared
  @AppStorage private var order: Int
  private var column: Int { abs(order) - 1 }
  private var descending: Bool { order > 0 }
  @State private var expanded = false
  @State private var query = ""
  @State private var subscribed = false
  @Environment(\.processTablesVisible) private var visible
  var paused = false
  init(kind: LedgerKind, compact: Bool = false, paused: Bool = false) {
    _order = AppStorage(wrappedValue: 1, kind == .resources ? "rank.resources" : "rank.network")
    self.kind = kind
    self.compact = compact
    self.paused = paused
  }
  private var network: Bool { kind == .network }
  private var valueWidth: CGFloat {
    let minimum: CGFloat = compact ? 57 : 65
    let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    let measured = [first, second].map { (($0 + " ↓") as NSString).size(withAttributes: [.font: font]).width }
    return max(minimum, ceil(measured.max() ?? 0) + 2)
  }
  private var first: String { network ? L("↑ 上传") : "CPU" }
  private var second: String { network ? L("↓ 下载") : L("内存") }
  private var items: [LedgerEntry] {
    let list: [LedgerEntry] =
      network
      ? net.processes.map {
        LedgerEntry(id: $0.id, name: $0.name, first: $0.outgoing, second: $0.incoming)
      }
      : cpu.processes.map {
        LedgerEntry(id: $0.id, name: $0.name, first: $0.cpu, second: Double($0.memory))
      }
    return list.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || String($0.id).contains(query)
    }.sorted { LedgerEntry.precedes($0, $1, column: column, descending: descending) }
  }
  var body: some View {
    let width = valueWidth
    let ranked = items
    let shown = expanded ? ranked : Array(ranked.prefix(5))
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(network ? L("网络分析") : L("资源占用")).font(.system(size: 12, weight: .semibold))
          .help(network ? L("外部接口的 TCP 与 UDP 流量，排除本机回环") : L("CPU 单核满载为 100%，内存为进程的实际内存占用"))
        Spacer()
        Text((column == 0 ? first : second) + (descending ? L("降序") : L("升序"))).font(.caption2)
          .foregroundStyle(.secondary)
        Button(expanded ? L("收起") : L("展开")) {
          withAnimation(.easeOut(duration: 0.12)) {
            expanded.toggle()
            if !expanded { query = "" }
          }
        }
        .buttonStyle(.plain).font(.caption).foregroundStyle(ScopeTheme.labelAccent)
      }
      if expanded {
        TextField(L("搜索进程名或 PID"), text: $query).textFieldStyle(.roundedBorder).font(.caption)
      }
      HStack(spacing: 4) {
        Text(compact && !expanded ? L("进程") : L("进程 / PID")).font(.system(size: 10)).foregroundStyle(
          .secondary)
        Spacer()
        sortKey(first, 0, width)
        sortKey(second, 1, width)
      }
      Divider()
      if ranked.isEmpty {
        Text(query.isEmpty ? (network ? net.processState : cpu.status) : L("未找到匹配进程")).font(.caption)
          .foregroundStyle(.secondary).frame(
            maxWidth: .infinity, minHeight: 47, alignment: .leading)
      } else if expanded {
        ScrollView { LazyVStack(spacing: 4) { ForEach(shown) { row($0, width) } } }.frame(
          height: compact ? 150 : 220)
      } else {
        ForEach(shown) { row($0, width) }
      }
    }.onAppear { setSampling(visible && !paused) }.onDisappear { setSampling(false) }.onChange(of: visible && !paused) {
      setSampling($0)
    }
  }
  private func setSampling(_ on: Bool) {
    guard subscribed != on else { return }
    subscribed = on
    if network {
      if on { net.start() } else { net.stop() }
    } else {
      if on { cpu.start() } else { cpu.stop() }
    }
  }
  private func sortKey(_ title: String, _ i: Int, _ valueWidth: CGFloat) -> some View {
    Button {
      order = column == i ? -order : i + 1
    } label: {
      Text(title + (column == i ? (descending ? " ↓" : " ↑") : "")).font(
        .system(size: 10, weight: column == i ? .semibold : .regular)
      ).frame(width: valueWidth, alignment: .trailing)
    }.foregroundStyle(column == i ? ScopeTheme.labelAccent : .secondary).buttonStyle(.plain).help(
      L("按") + title + L("排序"))
  }
  private func row(_ p: LedgerEntry, _ valueWidth: CGFloat) -> some View {
    HStack(spacing: 4) {
      ProcessIcon(pid: p.id, name: p.name)
      Text(p.name).lineLimit(1).truncationMode(.tail)
      if !compact || expanded {
        Text(String(p.id)).foregroundStyle(.secondary).font(.system(size: 9, design: .monospaced))
      }
      Spacer(minLength: 0)
      Text(network ? formattedRate(p.first) : gaugeValue(p.first, "%.1f%%")).frame(
        width: valueWidth, alignment: .trailing)
      Text(network ? formattedRate(p.second) : bytes(p.second)).frame(
        width: valueWidth, alignment: .trailing)
    }.font(.system(size: compact ? 10.5 : 11.5)).monospacedDigit().frame(minHeight: 17)
      .help("\(p.name) · PID \(p.id)").accessibilityElement(children: .combine)
  }
  private func formattedRate(_ value: Double?) -> String {
    let (num, unit) = rateNumber(value)
    return num + (unit.isEmpty ? "" : " " + unit)
  }
}

private struct ProcessIcon: View {
  let pid: Int32
  let name: String
  @State private var icon: NSImage?
  private static let icons: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 96
    return cache
  }()
  private func loadIcon() {
    let key = "\(pid)/\(name)" as NSString
    if let small = Self.icons.object(forKey: key) { icon = small; return }
    guard let source = NSRunningApplication(processIdentifier: pid)?.icon else { icon = nil; return }
    let size = NSSize(width: 20, height: 20)
    let small = NSImage(size: size)
    small.lockFocus()
    source.draw(in: CGRect(origin: .zero, size: size))
    small.unlockFocus()
    Self.icons.setObject(small, forKey: key)
    icon = small
  }
  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }.frame(width: 13, height: 13)
      .onAppear { loadIcon() }
      .onChange(of: name) { _ in loadIcon() }
      .accessibilityHidden(true)
  }
}
