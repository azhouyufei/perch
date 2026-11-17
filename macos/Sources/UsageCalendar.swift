import SwiftUI

struct DayUsage {
  var amount = UsageAmount()
  var sessions = Set<String>()
  var models = Set<String>()
  var projects = Set<String>()

  static func grouped(_ rows: [UsageRow], in interval: DateInterval) -> [Date: DayUsage] {
    var result = [Date: DayUsage]()
    for r in rows where r.date >= interval.start && r.date < interval.end && r.total > 0 {
      let date = Calendar.current.startOfDay(for: r.date)
      result[date, default: DayUsage()].amount = result[date, default: DayUsage()].amount + r.amount
      result[date, default: DayUsage()].sessions.insert(r.tool + "/" + r.session)
      if r.model != "未记录" { result[date, default: DayUsage()].models.insert(r.model) }
      if !r.project.isEmpty { result[date, default: DayUsage()].projects.insert(r.project) }
    }
    return result
  }
  static func longestRun(_ dates: [Date], calendar: Calendar = .current) -> Int {
    var last: Date?
    var best = 0
    var run = 0
    for day in dates.sorted() {
      run =
        last.flatMap { calendar.dateComponents([.day], from: $0, to: day).day } == 1 ? run + 1 : 1
      best = max(best, run)
      last = day
    }
    return best
  }
}

private struct ActivityRings: View {
  let values: [Double]
  var body: some View {
    Canvas { context, size in
      let colors = [ScopeTheme.download, ScopeTheme.upload, ScopeTheme.yellow]
      let side = min(size.width, size.height)
      let width = side * 0.090
      for i in 0..<3 {
        let radius = side / 2 - width * (0.65 + Double(i) * 1.32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let circle = CGRect(
          x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        context.stroke(
          Path(ellipseIn: circle), with: .color(colors[i].opacity(0.16)), lineWidth: width)
        let fraction = max(0, min(1, values[i]))
        if fraction > 0 {
          var path = Path()
          path.addArc(
            center: center, radius: radius, startAngle: .degrees(-90),
            endAngle: .degrees(360 * fraction - 90), clockwise: false)
          context.stroke(
            path, with: .color(colors[i]), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
      }
    }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
  }
}

struct UsageCalendar: View {
  let rows: [UsageRow]
  private let calendar = Calendar.current
  @State private var selected = Calendar.current.startOfDay(for: Date())
  var body: some View {
    let month = calendar.dateInterval(of: .month, for: selected)!
    let today = calendar.startOfDay(for: Date())
    let grouped = DayUsage.grouped(rows, in: month)
    let days = calendar.range(of: .day, in: .month, for: selected)!.count
    let leading = (calendar.component(.weekday, from: month.start) + 5) % 7
    let chosen = grouped[selected] ?? DayUsage()
    let maxima = [
      grouped.values.map { $0.amount.input }.max() ?? 0,
      grouped.values.map { $0.amount.output }.max() ?? 0,
      grouped.values.map { $0.sessions.count }.max() ?? 0,
    ]
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(L("活动日历"), systemImage: "calendar").font(.headline)
        Spacer()
        Button {
          move(-1)
        } label: {
          Image(systemName: "chevron.left")
        }.help(L("上个月")).accessibilityLabel(L("上个月"))
        Text(selected.formatted(.dateTime.year().month(.wide))).font(.callout.bold())
        Button {
          move(1)
        } label: {
          Image(systemName: "chevron.right")
        }.disabled(month.end > today).help(L("下个月")).accessibilityLabel(L("下个月"))
        Button(L("今天")) { selected = today }
      }.buttonStyle(.plain)
      HStack(alignment: .top, spacing: 20) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 4
        ) {
          ForEach([L("一"), L("二"), L("三"), L("四"), L("五"), L("六"), L("日")], id: \.self) {
            Text($0).font(.caption2).foregroundStyle(.secondary)
          }
          ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 1) }
          ForEach(1...days, id: \.self) { n in
            let date = calendar.date(byAdding: .day, value: n - 1, to: month.start)!
            let stats = grouped[date] ?? DayUsage()
            Button {
              selected = date
            } label: {
              VStack(spacing: 2) {
                ActivityRings(values: progress(stats, maxima)).frame(width: 24, height: 24)
                Text(String(n)).font(.system(size: 9, weight: date == selected ? .bold : .regular))
                  .monospacedDigit()
              }.padding(3).frame(maxWidth: .infinity)
                .background(
                  date == selected ? ScopeTheme.raised : .clear,
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(date > today).opacity(date > today ? 0.4 : 1)
              .accessibilityLabel(
                date.formatted(date: .long, time: .omitted) + "，" + shortTokens(stats.amount.total)
                  + " Token"
              )
              .accessibilityAddTraits(selected == date ? .isSelected : [])
          }
        }.frame(maxWidth: .infinity)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text(selected.formatted(.dateTime.month().day())).font(.headline)
          HStack(spacing: 10) {
            ActivityRings(values: progress(chosen, maxima)).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
              ringLabel(L("输入"), chosen.amount.input.formatted(), ScopeTheme.download)
              ringLabel(L("输出"), chosen.amount.output.formatted(), ScopeTheme.upload)
              ringLabel(L("会话"), String(chosen.sessions.count), ScopeTheme.yellow)
            }
          }
          Text(L("各环以本月单日最高值为满环")).font(.caption2).foregroundStyle(.secondary)
          Divider()
          Text(L("当日模型 ") + String(chosen.models.count) + L(" · 项目 ") + String(chosen.projects.count))
            .font(.caption)
          Text(L("本月活跃 ") + String(grouped.count) + L(" 天")).font(.caption)
          Text(L("本月最长连续 ") + String(DayUsage.longestRun(Array(grouped.keys))) + L(" 天")).font(.caption)
        }.frame(width: 176, alignment: .leading)
      }
    }.padding(14).tile()
  }
  private func progress(_ d: DayUsage, _ maxes: [Int]) -> [Double] {
    zip([d.amount.input, d.amount.output, d.sessions.count], maxes).map {
      Double($0.0) / Double(max(1, $0.1))
    }
  }
  private func ringLabel(_ label: String, _ value: String, _ color: Color) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(label)
      Spacer()
      Text(value).monospacedDigit()
    }.font(.caption)
  }
  private func move(_ direction: Int) {
    let start = calendar.dateInterval(of: .month, for: selected)!.start
    if let date = calendar.date(byAdding: .month, value: direction, to: start) { selected = date }
  }
}
