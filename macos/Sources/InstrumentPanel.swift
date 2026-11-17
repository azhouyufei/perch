import SwiftUI

enum InstrumentTab: String, CaseIterable {
  case hardware = "硬件"
  case network = "网络"
  case usage = "用量"
}
final class PanelNavigation: ObservableObject {
  @Published var tab: InstrumentTab = .hardware
  @Published var pinned = false
}
private let ice = ScopeTheme.labelAccent
private let uploadColor = ScopeTheme.upload
private let downloadColor = ScopeTheme.download
func gaugeValue(_ v: Double?, _ format: String) -> String {
  guard let v, v.isFinite, v >= 0 else { return "—" }
  return String(format: format, v)
}
func rateNumber(_ v: Double?) -> (String, String) {
  guard let v, v.isFinite, v >= 0 else { return ("—", "") }
  let scale = v >= 1e9 ? 1e9 : v >= 1e6 ? 1e6 : v >= 1e3 ? 1e3 : 1
  return (
    String(format: scale > 1 && v / scale < 10 ? "%.1f" : "%.0f", v / scale),
    scale == 1e9 ? "GB/s" : scale == 1e6 ? "MB/s" : scale == 1e3 ? "KB/s" : "B/s"
  )
}
private func rateText(_ v: Double?) -> String {
  let (n, u) = rateNumber(v)
  return n + (u.isEmpty ? "" : " " + u)
}
private func temp(_ s: SBSensors?) -> Double? {
  [s?.pTemp, s?.eTemp].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }.max()
}
private func fanPercent(_ s: SBSensors?) -> Double? {
  guard let s else { return nil }
  let fans: [(Double, Double, Double)] = [(s.fan0, s.min0, s.max0), (s.fan1, s.min1, s.max1)]
  var values = [Double]()
  for (speed, minimum, maximum) in fans where speed.isFinite && maximum > minimum {
    let percent: Double = 100 * (speed - minimum) / (maximum - minimum)
    values.append(max(0, min(100, percent)))
  }
  return values.max()
}
struct GaugeDial: View {
  let name: String, value: String, detail: String, level: Double?, color: Color
  var body: some View {
    ZStack {
      Circle().stroke(ScopeTheme.ink.opacity(0.12), lineWidth: 3)
      if let level, level.isFinite {
        Circle().trim(from: 0, to: min(1, max(0, level / 100))).stroke(
          color, style: StrokeStyle(lineWidth: 3, lineCap: .round)
        ).rotationEffect(.degrees(-90))
      }
      VStack(spacing: 2) {
        Text(name).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(
          ScopeTheme.ink.opacity(0.65))
        Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
        Text(detail).font(.system(size: 9)).foregroundStyle(ScopeTheme.ink.opacity(0.67)).lineLimit(
          1)
      }
    }.frame(width: 74, height: 74).accessibilityElement(children: .combine)
  }
}
struct PanelGroup<Content: View>: View {
  let title: String
  var trailing: String = ""
  @ViewBuilder var content: () -> Content
  @State private var collapsed = false
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { collapsed.toggle() }
      } label: {
        HStack {
          Text(title).font(.system(size: 11, weight: .semibold))
          Spacer()
          Text(trailing).font(.caption2)
          Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(
            .system(size: 8, weight: .bold))
        }.foregroundStyle(ice).contentShape(Rectangle())
      }.buttonStyle(.plain).help(collapsed ? L("展开") + title : L("收起") + title)
      if !collapsed { content() }
    }.padding(.horizontal, 11).padding(.vertical, 8)
      .background(ScopeTheme.ink.opacity(0.052), in: RoundedRectangle(cornerRadius: 8))
  }
}
private struct Field: View {
  let name: String, value: String
  var dot: Double? = nil
  var body: some View {
    HStack(spacing: 6) {
      Text(name).foregroundStyle(ScopeTheme.ink.opacity(0.82))
      Spacer(minLength: 5)
      Text(value).monospacedDigit().fontWeight(.medium)
      if let dot, dot.isFinite {
        ZStack {
          Circle().stroke(ScopeTheme.ink.opacity(0.15), lineWidth: 1.5)
          Circle().trim(from: 0, to: max(0, min(1, dot / 100))).stroke(
            downloadColor, lineWidth: 1.5
          )
          .rotationEffect(.degrees(-90))
        }.frame(width: 10, height: 10)
      }
    }.font(.system(size: 12)).frame(minHeight: 15)
  }
}
struct DuplexChart: View {
  let samples: [Reading]
  @State private var hover: CGFloat?
  var body: some View {
    let window = samples.suffix(70)
    let peak = max(
      1, window.flatMap { [$0.values[.upload] ?? 0, $0.values[.download] ?? 0] }.max() ?? 1)
    VStack(spacing: 4) {
      Canvas { ctx, size in
        let mid = size.height / 2
        let step = size.width / 70
        var line = Path()
        line.move(to: CGPoint(x: 0, y: mid))
        line.addLine(to: CGPoint(x: size.width, y: mid))
        ctx.stroke(line, with: .color(ScopeTheme.ink.opacity(0.19)), lineWidth: 0.7)
        for (i, r) in window.enumerated() {
          let x = size.width - step * CGFloat(window.count - i)
          for (metric, up, c) in [
            (Metric.upload, true, uploadColor), (.download, false, downloadColor),
          ] {
            guard let v = r.values[metric] else { continue }
            let h = (mid - 2) * min(1, v / peak)
            ctx.fill(
              Path(
                CGRect(
                  x: x, y: up ? mid - h : mid, width: max(1, step - 1),
                  height: max(v > 0 ? 1 : 0, h))), with: .color(c))
          }
        }
        if let hover {
          var p = Path()
          p.move(to: .init(x: hover * size.width, y: 0))
          p.addLine(to: .init(x: hover * size.width, y: size.height))
          ctx.stroke(
            p, with: .color(ScopeTheme.ink.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
      }.frame(height: 59).overlay(
        GeometryReader { g in
          Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = max(0, min(0.999, p.x / g.size.width))
            case .ended: hover = nil
            }
          }
        })
      if let x = hover,
        let r = Array(window).dropFirst(max(0, Int(x * 70) - (70 - window.count))).first
      {
        HStack {
          Text(r.date.formatted(date: .omitted, time: .standard))
          Spacer()
          Text("↑ " + rateText(r.values[.upload]) + "   ↓ " + rateText(r.values[.download]))
        }.font(.system(size: 10, design: .monospaced))
      } else {
        HStack {
          Text(L("峰值 ↑ ") + rateText(window.compactMap { $0.values[.upload] }.max()))
          Spacer()
          Text("↓ " + rateText(window.compactMap { $0.values[.download] }.max()))
        }.font(.system(size: 10)).foregroundStyle(ScopeTheme.ink.opacity(0.62))
      }
    }
  }
}
struct HardwareBody: View {
  let r: Reading
  var body: some View {
    let s = r.sensors
    let cpu = temp(s)
    let gpu = s?.gpuTemp
    let fan = fanPercent(s)
    VStack(spacing: 5) {
      HStack {
        Spacer()
        GaugeDial(
          name: "CPU",
          value: cpu != nil ? gaugeValue(cpu, "%.0f°") : gaugeValue(r.values[.cpu], "%.0f%%"),
          detail: s?.pGHz.isFinite == true
            ? gaugeValue(s?.pGHz, "%.2f GHz") : cpu != nil ? L("核心温度") : L("使用率"),
          level: cpu ?? r.values[.cpu], color: downloadColor)
        Spacer()
        GaugeDial(
          name: "GPU",
          value: gpu?.isFinite == true
            ? gaugeValue(gpu, "%.0f°") : gaugeValue(s?.gpuLoad, "%.0f%%"),
          detail: s?.gpuGHz.isFinite == true
            ? gaugeValue(s?.gpuGHz, "%.2f GHz") : gpu?.isFinite == true ? L("核心温度") : L("使用率"),
          level: gpu?.isFinite == true ? gpu : s?.gpuLoad, color: ScopeTheme.yellow)
        Spacer()
        GaugeDial(
          name: "FANS", value: gaugeValue(fan, "%.0f%%"), detail: L("转速区间"), level: fan,
          color: ScopeTheme.download)
        Spacer()
      }.padding(.vertical, 8)
      SensorDashboard(r: r)
    }
  }
}
private struct SensorDashboard: View {
  let r: Reading
  @State private var selected = L("温度")
  private let categories = [L("温度"), L("功率"), L("电压"), L("风扇"), L("频率")]
  private var readings: [(String, Double)] {
    guard let s = r.sensors else { return [] }
    let values: [(String, Double)]
    switch selected {
    case L("温度"):
      values = [
        (L("CPU 性能核"), s.pTemp), (L("CPU 能效核"), s.eTemp), ("GPU", s.gpuTemp), ("SSD", s.ssd),
        (L("雷雳左侧"), s.thunderLeft), (L("雷雳右侧"), s.thunderRight), ("Wi-Fi", s.wifi), (L("显示屏"), s.display),
        (L("气流"), s.airflow), (L("电池"), s.batteryTemp),
      ]
    case L("功率"): values = [("CPU", s.cpuWatts), ("GPU", s.gpuWatts), (L("系统输入"), s.systemWatts)]
    case L("电压"): values = [(L("电池"), s.voltage)]
    case L("风扇"): values = [(L("风扇 1"), s.fan0), (L("风扇 2"), s.fan1)]
    default: values = [(L("CPU 性能核"), s.pGHz), (L("CPU 能效核"), s.eGHz), ("GPU", s.gpuGHz)]
    }
    return values.filter {
      $0.1.isFinite && $0.1 >= 0 && (selected != L("温度") || (0..<130).contains($0.1) && $0.1 > 0)
    }
  }
  private var format: String {
    switch selected {
    case L("温度"): return "%.0f °C"
    case L("功率"): return "%.2f W"
    case L("电压"): return "%.2f V"
    case L("风扇"): return "%.0f RPM"
    default: return "%.2f GHz"
    }
  }
  private var categoryPicker: some View {
    Picker(L("传感器类别"), selection: $selected) {
      ForEach(categories, id: \.self) { Text($0).tag($0) }
    }.controlSize(.small).labelsHidden()
  }
  private var sensorTitle: some View {
    Label(L("传感器明细"), systemImage: "thermometer.medium").font(.callout.bold())
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ViewThatFits(in: .horizontal) {
        HStack {
          sensorTitle.fixedSize()
          Spacer(minLength: 8)
          categoryPicker.pickerStyle(.segmented).fixedSize()
        }
        categoryPicker.pickerStyle(.segmented).fixedSize()
        HStack {
          sensorTitle
          Spacer(minLength: 8)
          categoryPicker.pickerStyle(.menu).fixedSize()
        }
      }
      let rows = readings
      if rows.isEmpty {
        Text(L("暂无") + selected + L("读数")).font(.caption).foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 158), spacing: 14)], alignment: .leading, spacing: 3
        ) {
          ForEach(rows, id: \.0) { name, value in
            HStack(spacing: 4) {
              Text(name).foregroundStyle(.secondary); Spacer(minLength: 2);
              Text(String(format: format, value)).monospacedDigit()
            }
            .font(.system(size: 11)).lineLimit(1).padding(.vertical, 3)
            .overlay(alignment: .bottom) {
              Rectangle().fill(Color.secondary.opacity(0.13)).frame(height: 0.5)
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }
}
struct NetworkBody: View {
  let samples: [Reading]
  @ObservedObject private var info = NetworkInfo.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(spacing: 10) {
        HStack {
          speed(L("上传"), .upload, uploadColor)
          speed(L("下载"), .download, downloadColor)
        }
        DuplexChart(samples: samples)
      }.padding(10).background(ScopeTheme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
      HStack {
        Image(systemName: info.interface.lowercased().contains("wi-fi") ? "wifi" : "network")
          .foregroundStyle(ice)
        Text(info.interface).font(.system(size: 12, weight: .medium))
        Spacer()
      }.padding(.horizontal, 10).padding(.vertical, 6)
      PanelGroup(title: L("网络地址")) {
        HStack {
          Text(L("公共 IP"))
          Spacer()
          Button(info.lookingUp ? L("查询中…") : info.publicAddress ?? L("查询公共 IP")) { info.lookup() }
            .buttonStyle(.plain).foregroundStyle(ice).help(L("向 ipify 查询当前公网地址")).disabled(
              info.lookingUp)
        }.font(.system(size: 12))
        Field(name: L("本机 IP"), value: info.local)
      }
      ProcessLedger(kind: .network, compact: true)
        .padding(9).tile(8)
    }
  }
  func speed(_ title: String, _ metric: Metric, _ color: Color) -> some View {
    let (n, u) = rateNumber(samples.last?.values[metric])
    return VStack(spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text(n).font(.system(size: 25, weight: .semibold, design: .rounded))
        Text(u).font(.system(size: 12, weight: .medium))
      }.monospacedDigit()
      HStack(spacing: 4) {
        Circle().fill(color).frame(width: 6, height: 6)
        Text(title).font(.caption).foregroundStyle(ScopeTheme.ink.opacity(0.72))
      }
    }.frame(maxWidth: .infinity)
  }
}
struct InstrumentPanel: View {
  @ObservedObject var studio: Studio
  @ObservedObject var monitor: Monitor
  @ObservedObject var nav: PanelNavigation
  var inline = false
  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Image(systemName: "waveform.path.ecg").foregroundStyle(ice)
        Text(L("Perch")).font(.system(size: 12, weight: .bold))
        Spacer()
        HStack(spacing: 1) {
          ForEach(InstrumentTab.allCases, id: \.self) { tab in
            Button {
              nav.tab = tab
            } label: {
              Text(L(tab.rawValue)).fixedSize().font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(nav.tab == tab ? ScopeTheme.canvas : ScopeTheme.ink.opacity(0.78))
                .background(nav.tab == tab ? ScopeTheme.ink : .clear, in: Capsule())
                .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(nav.tab == tab ? .isSelected : [])
          }
        }.padding(2).background(ScopeTheme.raised, in: Capsule())
        if !inline {
          Button {
            nav.pinned.toggle()
          } label: {
            Image(systemName: nav.pinned ? "pin.fill" : "pin")
          }.buttonStyle(.plain).help(nav.pinned ? L("取消保持面板") : L("保持面板打开"))
        }
      }.padding(.horizontal, 4)
      ScrollView(.vertical) {
        panelBody.frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
      }
      .id(nav.tab)
      .frame(minWidth: 0, maxWidth: .infinity)
      .frame(height: min(535, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 165)))
      .transaction { $0.animation = nil }
      Divider().overlay(ScopeTheme.ink.opacity(0.15))
      HStack(spacing: 8) {
        foot("viewfinder", L("区域截图")) { studio.take(.region) }
        foot("square.on.square", L("剪贴板贴图")) { studio.pinClipboard() }
        foot("photo.stack", L("截图库")) {
          studio.page = .gallery
          studio.open()
        }
        Spacer()
        foot("macwindow", L("工作台")) {
          studio.page = .overview
          studio.open()
        }
        foot("slider.horizontal.3", L("偏好设置")) {
          studio.page = .settings
          studio.open()
        }
      }.padding(.horizontal, 2)
    }.padding(10).frame(width: 364).foregroundStyle(ScopeTheme.ink)
      .background(
        ScopeTheme.panel
      )
      .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 13))
      .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ScopeTheme.ink.opacity(0.13)))
  }
  @ViewBuilder private var panelBody: some View {
    if nav.tab == .hardware {
      VStack(spacing: 6) {
        HardwareBody(r: monitor.current)
        ProcessLedger(kind: .resources, compact: true).padding(9).tile(8)
      }
    } else if nav.tab == .usage {
      UsageSummary(store: studio.usage) {
        studio.page = .usage
        studio.open()
      }
    } else {
      NetworkBody(samples: monitor.samples)
    }
  }
  private func foot(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
    PanelIcon(symbol: symbol, name: name, action: action)
  }
}
private struct PanelIcon: View {
  let symbol: String, name: String, action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(
        width: 28, height: 23
      ).background(
        ScopeTheme.ink.opacity(hover ? 0.16 : 0.055), in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.plain).onHover { hover = $0 }.help(name).accessibilityLabel(name)
  }
}
enum StatusInk {
  static func draw(_ first: String, _ second: String, width: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { r in
      let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
      let style = NSMutableParagraphStyle()
      style.alignment = .right
      let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style,
      ]
      (first as NSString).draw(
        in: NSRect(x: 0, y: 10, width: r.width, height: 12), withAttributes: attrs)
      (second as NSString).draw(
        in: NSRect(x: 0, y: 0, width: r.width, height: 12), withAttributes: attrs)
      return true
    }
    img.isTemplate = true
    return img
  }
  static func hardware(_ r: Reading?) -> String {
    let t = temp(r?.sensors)
    return t != nil ? gaugeValue(t, "%.0f°") : gaugeValue(r?.values[.cpu], "%.0f%%")
  }
}

struct ConsoleOverview: View {
  @ObservedObject var monitor: Monitor
  let inspect: (Metric) -> Void
  var body: some View {
    let r = monitor.current
    let sensors = r.sensors
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(L("系统活动"), systemImage: "waveform.path.ecg").font(.system(size: 14, weight: .semibold))
        Spacer()
        Circle().fill(monitor.paused ? ScopeTheme.upload : ScopeTheme.live).frame(
          width: 6, height: 6)
        Text(monitor.paused ? L("已暂停") : r.date.formatted(date: .omitted, time: .standard)).font(
          .system(size: 10, design: .monospaced)
        ).foregroundStyle(ScopeTheme.ink.opacity(0.63))
      }
      FittingColumns(minimum: metricCardWidth, spacing: 10) {
        metricCard(
          .cpu, L("处理器"),
          detail: Lf("%@ 核 · ", String(describing: ProcessInfo.processInfo.activeProcessorCount))
            + gaugeValue(temp(sensors), "%.0f °C"))
        metricCard(.memory, L("内存"), detail: bytes(r.used) + " / " + bytes(r.total))
        metricCard(.upload, L("网络上传"), detail: peak(.upload))
        metricCard(.download, L("网络下载"), detail: peak(.download))
      }
      FittingColumns(minimum: 310, spacing: 18) {
        ProcessLedger(kind: .resources, compact: true, paused: monitor.paused).frame(
          maxWidth: .infinity)
        ProcessLedger(kind: .network, compact: true, paused: monitor.paused).frame(
          maxWidth: .infinity)
      }.padding(14).tile()
      SensorDashboard(r: r).padding(.horizontal, 11).padding(.vertical, 8).tile()
    }.foregroundStyle(ScopeTheme.ink)
  }
  private var metricCardWidth: CGFloat {
    let titles = [L("处理器"), L("内存"), L("网络上传"), L("网络下载")]
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    return max(145, ceil(widest) + 82) // label, icon, arrow, spacing and card padding
  }
  private func peak(_ metric: Metric) -> String {
    let since = monitor.current.date.addingTimeInterval(-120)
    return L("2 分钟峰值 ") + rateText(monitor.samples.lazy.filter { $0.date >= since }.compactMap { $0.values[metric] }.max())
  }
  private func metricCard(_ metric: Metric, _ title: String, detail: String) -> some View {
    let color = metric.color
    return Button {
      inspect(metric)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Image(systemName: metric.symbol).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color).frame(width: 30, height: 30).background(
              color.opacity(0.16), in: Circle())
          Text(title).font(.callout).foregroundStyle(.secondary)
          Spacer(minLength: 1)
          Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.65)).accessibilityHidden(true)
        }
        Text(metric.format(monitor.current.values[metric])).font(
          .system(size: 30, weight: .medium, design: .rounded)
        )
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        Trend(samples: monitor.samples, metric: metric, color: color).frame(height: 29).padding(
          .horizontal, -12
        ).padding(.bottom, -12)
      }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(ScopeTheme.card, in: RoundedRectangle(cornerRadius: 19)).clipShape(
          RoundedRectangle(cornerRadius: 19))
    }.buttonStyle(.plain).help(L("查看") + title + L("趋势"))
  }
}

struct MenuLayoutPreview: View {
  let studio: Studio
  @ObservedObject var monitor: Monitor
  let layout: String
  let hoverEnabled: Bool
  @AppStorage("menuUsage") private var menuUsage = false
  @StateObject private var preview = PanelNavigation()
  @State private var visible = false

  var body: some View {
    HStack {
      Text(L("菜单栏预览")).font(.caption).foregroundStyle(.secondary)
      Spacer()
      if layout != "network" {
        badge(.hardware) {
          if layout == "icon" {
            Image(systemName: "waveform.path.ecg")
          } else {
            VStack(spacing: 0) {
              Text("CPU")
              Text(StatusInk.hardware(monitor.current))
            }
          }
        }
      }
      if layout == "dual" || layout == "network" {
        badge(.network) {
          VStack(alignment: .trailing, spacing: 0) {
            Text("↑ " + rateText(monitor.current.values[.upload]))
            Text("↓ " + rateText(monitor.current.values[.download]))
          }
        }
      }
      if menuUsage { badge(.usage) { Image(systemName: "chart.bar.xaxis") } }
    }.font(.system(size: 10, weight: .medium)).monospacedDigit()
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      .popover(isPresented: $visible, arrowEdge: .bottom) {
        InstrumentPanel(studio: studio, monitor: monitor, nav: preview, inline: true)
      }
      .onChange(of: hoverEnabled) { on in if !on { visible = false } }
  }
  private func badge<V: View>(_ tab: InstrumentTab, @ViewBuilder content: () -> V) -> some View {
    Button {
      preview.tab = tab
      visible = true
    } label: {
      content().padding(.horizontal, 5).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside && hoverEnabled {
        preview.tab = tab
        visible = true
      }
    }
    .accessibilityLabel(Lf("预览%@", L(tab.rawValue)))
  }
}
