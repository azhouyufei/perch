import SwiftUI

struct Trend: View {
  let samples: [Reading]
  let metric: Metric
  var color: Color
  var grid = false
  var seconds: TimeInterval = 120
  var body: some View {
    Canvas { ctx, size in
      if grid {
        for i in 0...4 {
          var path = Path()
          let y = size.height * CGFloat(i) / 4
          path.move(to: CGPoint(x: 0, y: y))
          path.addLine(to: CGPoint(x: size.width, y: y))
          ctx.stroke(
            path, with: .color(color.opacity(0.14)),
            style: StrokeStyle(lineWidth: 0.8, dash: [3, 5]))
        }
      }
      guard let end = samples.last?.date else { return }
      let window = samples.filter { end.timeIntervalSince($0.date) <= seconds }
      let peak = metric.percent ? 100 : max(1, window.compactMap { $0.values[metric] }.max() ?? 1)
      var path = Path()
      var fill = Path()
      var first: CGPoint?
      var last: CGPoint?
      func finish() {
        guard let first, let last else { return }
        fill.addLine(to: CGPoint(x: last.x, y: size.height))
        fill.addLine(to: CGPoint(x: first.x, y: size.height))
        fill.closeSubpath()
      }
      for sample in window {
        guard let v = sample.values[metric] else {
          finish()
          first = nil
          last = nil
          continue
        }
        let p = CGPoint(
          x: size.width * (1 - end.timeIntervalSince(sample.date) / seconds),
          y: max(1, size.height - 2) * (1 - min(1, max(0, v / peak))) + 1)
        if first == nil {
          path.move(to: p)
          fill.move(to: p)
          first = p
        } else {
          path.addLine(to: p)
          fill.addLine(to: p)
        }
        last = p
      }
      finish()
      ctx.fill(
        fill,
        with: .linearGradient(
          Gradient(colors: [color.opacity(0.35), color.opacity(0.01)]), startPoint: .zero,
          endPoint: CGPoint(x: 0, y: size.height)))
      ctx.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
      if let last {
        ctx.fill(
          Path(ellipseIn: CGRect(x: last.x - 2.8, y: last.y - 2.8, width: 5.6, height: 5.6)),
          with: .color(color))
      }
    }.accessibilityHidden(true)
  }
}
struct Brand: View {
  var size: CGFloat = 36
  var body: some View {
    Image(nsImage:NSApp.applicationIconImage).resizable().interpolation(.high)
      .frame(width:size+5,height:size+5)
  }
}
extension View {
  func hoverInstruction(_ message: String, selection: Binding<String?>) -> some View {
    help(message).onHover { inside in
      if inside { selection.wrappedValue = message }
      else if selection.wrappedValue == message { selection.wrappedValue = nil }
    }
  }
  func tile(_ radius: CGFloat = 17) -> some View {
    self.modifier(TileSurface(radius: radius))
  }
}
struct ActivityCard: View {
  @ObservedObject var monitor: Monitor
  var metric: Metric
  var seconds: TimeInterval = 120
  var body: some View {
    let current = monitor.current
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(metric.title, systemImage: metric.symbol).font(.headline)
        Spacer()
        Circle().fill(monitor.paused ? ScopeTheme.upload : ScopeTheme.live).frame(width: 6, height: 6)
        Text(monitor.paused ? L("已暂停") : L("实时采样")).font(.caption)
      }.foregroundStyle(ScopeTheme.ink.opacity(0.83))
      HStack(alignment: .bottom, spacing: 16) {
        Text(metric.format(current.values[metric])).font(
          .system(size: 38, weight: .semibold, design: .rounded)
        ).monospacedDigit().foregroundStyle(ScopeTheme.ink)
        if metric == .cpu {
          Text(Lf("%@ 核", String(describing: ProcessInfo.processInfo.activeProcessorCount))).font(.callout).foregroundStyle(
            ScopeTheme.ink.opacity(0.65)
          ).padding(.bottom, 6)
        }
      }
      Trend(samples: monitor.samples, metric: metric, color: metric.color, grid: true, seconds: seconds)
        .frame(height: 65)
      HStack {
        Text(Lf("%@ 分钟前", String(describing: Int(seconds/60))))
        Spacer()
        Text(L("现在"))
      }.font(.caption2.monospacedDigit()).foregroundStyle(ScopeTheme.ink.opacity(0.63))
    }.padding(18).background(
      LinearGradient(
        colors: [
          ScopeTheme.raised, ScopeTheme.card,
        ], startPoint: .topLeading, endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 16))
  }
}

struct MemoryHistory: View {
  let samples: [Reading]
  private func pressure(_ code: Int) -> (String, Color) {
    switch code {
    case 1: return (L("正常"), ScopeTheme.live)
    case 2: return (L("警告"), ScopeTheme.yellow)
    case 4: return (L("危急"), ScopeTheme.upload)
    default: return ("—", ScopeTheme.raised)
    }
  }
  var body: some View {
    let state = pressure(samples.last?.pressure ?? 0)
    let maxSwap = max(1, samples.compactMap(\.swapUsed).max() ?? 1)
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(L("内存压力与交换空间"), systemImage: "memorychip").font(.headline)
        Spacer()
        Circle().fill(state.1).frame(width: 8, height: 8)
        Text(L("压力 ") + state.0)
      }
      Text(L("交换空间已用 ") + (samples.last?.swapUsed.map(bytes) ?? "—")).font(.callout.monospacedDigit())
      Canvas { ctx, size in
        guard let end = samples.last?.date else { return }
        let height = size.height - 14
        var line = Path()
        var prev: CGPoint?
        var lastDate: Date?
        for (i,r) in samples.enumerated() {
          let x = size.width * (1 + r.date.timeIntervalSince(end) / 600)
          if let used = r.swapUsed {
            let p = CGPoint(x: x, y: 2 + (height-4) * (1-used/maxSwap))
            if prev == nil || r.date.timeIntervalSince(lastDate ?? r.date) > 10 { line.move(to: p) } else { line.addLine(to: p) }
            prev = p
          } else { prev = nil }
          let next = i+1 < samples.count ? samples[i+1].date.timeIntervalSince(r.date) : 0
          let width = max(2, min(next, 5) * size.width / 600)
          ctx.fill(Path(CGRect(x: min(x, size.width-2), y: height+5, width: width, height: 7)), with: .color(pressure(r.pressure).1))
          lastDate = r.date
        }
        ctx.stroke(line, with: .color(ScopeTheme.download), lineWidth: 2)
        if let p = prev { ctx.fill(Path(ellipseIn: CGRect(x:p.x-2,y:p.y-2,width:4,height:4)), with:.color(ScopeTheme.download)) }
      }.frame(height: 73).accessibilityHidden(true)
      HStack { Text(L("10 分钟前")); Spacer(); Text(L("蓝线 · 已用交换空间　色带 · 内存压力")); Spacer(); Text(L("现在")) }
        .font(.caption2).foregroundStyle(.secondary)
    }.padding(14).tile()
  }
}
