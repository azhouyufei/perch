import SwiftUI

struct MonitorPage: View {
  @ObservedObject var monitor: Monitor
  @State private var display = "instruments"
  @State private var selected = Metric.cpu
  @State private var seconds = 120.0
  init(monitor: Monitor, initialMetric: Metric? = nil) {
    self.monitor = monitor
    _display = State(initialValue: initialMetric == nil ? "instruments" : "history")
    _selected = State(initialValue: initialMetric ?? .cpu)
  }
  var body: some View {
    let r = monitor.current
    VStack(alignment: .leading, spacing: 15) {
      Picker(L("监控视图"), selection: $display) {
        Text(L("仪表面板")).tag("instruments")
        Text(L("活动趋势")).tag("history")
      }.pickerStyle(.segmented).labelsHidden().fixedSize()
      if display == "instruments" {
        FittingColumns(minimum: 332, spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            Label(L("硬件"), systemImage: "cpu").font(.headline)
            ProcessLedger(kind: .resources, compact: true, paused: monitor.paused).padding(9).tile(
              8)
            HardwareBody(r: r)
          }
          .padding(12).frame(maxWidth: .infinity).background(
            instrumentBackground, in: RoundedRectangle(cornerRadius: 14))
          VStack(alignment: .leading, spacing: 8) {
            Label(L("网络"), systemImage: "network").font(.headline)
            NetworkBody(samples: monitor.samples)
            PanelGroup(title: L("存储"), trailing: L("启动磁盘")) {
              HStack {
                Text(L("可用空间"))
                Spacer()
                Text(bytes(r.available)).monospacedDigit()
              }.font(.caption)
            }
          }.padding(12).frame(maxWidth: .infinity).background(
            instrumentBackground, in: RoundedRectangle(cornerRadius: 14))
        }.foregroundStyle(ScopeTheme.ink)
      } else {
        HStack {
          Text(L("活动趋势")).font(.title3.bold())
          Spacer()
          Picker(L("时间范围"), selection: $seconds) {
            Text(L("2 分钟")).tag(120.0)
            Text(L("10 分钟")).tag(600.0)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
          Button {
            monitor.paused.toggle()
            if !monitor.paused { monitor.start() }
          } label: {
            Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
          }.help(monitor.paused ? L("继续采样") : L("暂停采样"))
        }
        ActivityCard(monitor: monitor, metric: selected, seconds: seconds)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10
        ) {
          ForEach(Metric.allCases) { metric in
            Button {
              selected = metric
            } label: {
              VStack(alignment: .leading, spacing: 7) {
                Label(metric.title, systemImage: metric.symbol).font(.callout).foregroundStyle(
                  .secondary)
                Text(metric.format(r.values[metric])).font(
                  .system(size: 20, weight: .semibold, design: .rounded)
                ).monospacedDigit()
                Trend(
                  samples: monitor.samples, metric: metric, color: metric.color, seconds: seconds
                )
                .frame(height: 24)
              }.padding(12).tile(12).overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                  selected == metric ? ScopeTheme.accent : .clear, lineWidth: 1.5))
            }.buttonStyle(.plain)
          }
        }
      }
      if display == "history" {
        ProcessLedger(
          kind: selected == .upload || selected == .download ? .network : .resources,
          paused: monitor.paused
        )
        .id(selected == .upload || selected == .download).padding(14).tile()
      }
      MemoryHistory(samples: monitor.samples)
      Text(L("硬件概况")).font(.title3.bold())
      VStack(alignment: .leading, spacing: 12) {
        CoreHistory(samples: monitor.samples)
        Divider()
        info(L("物理内存"), "\(bytes(r.used)) / \(bytes(r.total))")
        info(L("启动磁盘可用"), "\(bytes(r.available)) / \(bytes(r.capacity))")
        info(L("电源"), r.battery < 0 ? L("未检测到内置电池") : "\(r.battery)% · " + (r.plugged ? L("电源适配器") : L("电池供电")))
        info(L("系统热状态"), thermal)
      }.padding(16).tile()
    }
  }
  private var instrumentBackground: LinearGradient { ScopeTheme.panel }
  var thermal: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return L("正常")
    case .fair: return L("轻度升温")
    case .serious: return L("较热")
    case .critical: return L("高温")
    @unknown default: return L("未知")
    }
  }
  func info(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }.font(.callout)
  }
}
struct CoreBins {
  static let columns = 30
  static let seconds = 4.0
  static func history(_ samples: [Reading]) -> [[Double?]] {
    guard let latest = samples.last else { return [] }
    let count = latest.cores.count
    var rows = Array(repeating: Array<Double?>(repeating: nil, count: columns), count: count)
    for sample in samples.reversed() {
      let age = latest.date.timeIntervalSince(sample.date)
      if age >= Double(columns) * seconds { break }
      guard age >= 0 else { continue }
      let column = columns - 1 - Int(age / seconds)
      for core in 0..<min(count, sample.cores.count) {
        let value = sample.cores[core]
        guard value.isFinite, (0...100).contains(value) else { continue }
        rows[core][column] = max(rows[core][column] ?? 0, value)
      }
    }
    return rows
  }
}
private struct CoreHistory: View {
  let samples: [Reading]
  private func tint(_ value: Double?) -> Color {
    guard let value else { return ScopeTheme.raised }
    if value >= 85 { return ScopeTheme.upload }
    if value >= 60 { return ScopeTheme.yellow }
    return ScopeTheme.download.opacity(0.25 + value / 100)
  }
  var body: some View {
    let rows = CoreBins.history(samples)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(L("各核心负载"), systemImage: "cpu").font(.headline)
        Spacer()
        Text(L("近 2 分钟 · 每格 4 秒峰值")).font(.caption).foregroundStyle(.secondary)
      }
      if rows.isEmpty { Text(L("等待核心采样…")).font(.caption).foregroundStyle(.secondary) }
      ForEach(rows.indices, id: \.self) { i in
        let current = samples.last?.cores[i]
        let label = Metric.cpu.format(current.flatMap { $0 >= 0 ? $0 : nil })
        HStack(spacing: 8) {
          Text(L("核 ") + String(i+1)).frame(minWidth: 48, alignment: .leading)
          Canvas { context, size in
            let pitch = size.width / Double(CoreBins.columns)
            for (j, value) in rows[i].enumerated() {
              let rect = CGRect(x: Double(j)*pitch, y: 0, width: max(1,pitch-2), height: size.height)
              context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint(value)))
            }
          }.frame(height: 10)
          Text(label).frame(width: 35, alignment: .trailing)
        }.font(.caption.monospacedDigit()).accessibilityElement(children: .combine)
      }
      HStack(spacing: 8) {
        Text(L("2 分钟前"))
        Spacer()
        ForEach([0, 60, 85], id: \.self) { v in
          HStack(spacing: 3) {
            Circle().fill(tint(Double(v))).frame(width: 6, height: 6)
            Text(v == 0 ? L("低于 60%") : v == 60 ? "60–84%" : L("85% 以上"))
          }
        }
        Spacer()
        Text(L("现在"))
      }.font(.caption2).foregroundStyle(.secondary)
    }
  }
}
struct Preferences: View {
  @ObservedObject var studio: Studio
  @AppStorage("appearance") private var appearance = "dark"
  @AppStorage("systemCapturePicker") private var systemCapturePicker = false
  @State private var screenAllowed = CGPreflightScreenCaptureAccess()
  @AppStorage("interval") var interval = 2.0
  @AppStorage("hoverPreview") var hoverPreview = true
  @AppStorage("menuLayout") var menu = "dual"
  @AppStorage("menuUsage") var menuUsage = false
  @AppStorage("afterCapture") var after = "preview"
  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      StartupPreferences()
      row(L("外观")) {
        Picker(L("外观"), selection: $appearance) {
          Text(L("跟随系统")).tag("system")
          Text(L("浅色")).tag("light")
          Text(L("深色")).tag("dark")
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
          .onChange(of: appearance) { ScopeTheme.applyAppearance($0) }
      }.padding(16).tile()
      Text(L("监控")).font(.title3.bold())
      VStack(spacing: 14) {
        row(L("采样间隔")) {
          Picker(L("采样间隔"), selection: $interval) {
            ForEach([1.0, 2.0, 5.0], id: \.self) { Text(Lf("%@ 秒", String(describing: Int($0)))).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().fixedSize().onChange(of: interval) { _ in
            studio.monitor.start()
          }
        }
        Divider()
        row(L("菜单栏显示")) {
          Picker(L("菜单栏显示"), selection: $menu) {
            Text(L("仅图标")).tag("icon")
            Text(L("硬件与网络")).tag("dual")
            Text(L("仅硬件")).tag("hardware")
            Text(L("仅网络")).tag("network")
          }.labelsHidden().fixedSize()
        }
        MenuLayoutPreview(
          studio: studio, monitor: studio.monitor, layout: menu, hoverEnabled: hoverPreview)
        Divider()
        Toggle(L("在菜单栏显示今日 Token 用量"), isOn: $menuUsage)
        Toggle(L("鼠标悬停时预览菜单栏面板"), isOn: $hoverPreview)
      }.padding(16).tile()
      Text(L("截图与贴图")).font(.title3.bold())
      VStack(spacing: 14) {
        row(L("截图后")) {
          Picker(L("截图后"), selection: $after) {
            Text(L("打开预览")).tag("preview")
            Text(L("复制图像")).tag("copy")
            Text(L("贴到桌面")).tag("pin")
          }.labelsHidden().fixedSize()
        }
        Divider()
        ShortcutEditor(keys: studio.keys)
        Divider()
        row(L("贴图操作")) {
          Text(L("拖动移动 · 滚轮缩放 · 右键调透明度 · 双击关闭")).foregroundStyle(.secondary).font(.caption)
        }
        row(L("桌面贴图")) { Button(L("关闭全部")) { studio.pins.closeAll() } }
        if #available(macOS 14, *) {
          Toggle(L("使用系统选择器截图"), isOn: $systemCapturePicker)
        }
        row(L("屏幕录制权限")) {
          Text(screenAllowed ? L("可直接截图") : L("需要授权")).foregroundStyle(.secondary)
          if !screenAllowed {
            Button(L("启用直接截图")) {
              screenAllowed = RegionSelection.directCaptureAllowed()
            }
          }
          Button(L("打开系统设置")) {
            NSWorkspace.shared.open(
              URL(
                string:
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
          }
        }
      }.padding(16).tile()
    }
    .onChange(of: menuUsage) { _ in studio.updateMenuPreferences() }
    .onChange(of: menu) { _ in studio.updateMenuPreferences() }
    .onChange(of: hoverPreview) { _ in studio.updateMenuPreferences() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      screenAllowed = CGPreflightScreenCaptureAccess()
    }
  }
  func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack {
        Text(label).fixedSize()
        Spacer(minLength: 12)
        value().labelsHidden().fixedSize(horizontal: true, vertical: false)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(label).fontWeight(.medium)
        HStack { value().labelsHidden() }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
