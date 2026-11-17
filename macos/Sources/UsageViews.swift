import SwiftUI
import UniformTypeIdentifiers

private func inRange(_ rows: [UsageRow], _ days: Int) -> [UsageRow] {
  let cal = Calendar.current
  let today = Calendar.current.startOfDay(for: Date())
  let first = cal.date(byAdding: .day, value: 1 - days, to: today) ?? today
  return rows.filter { $0.date >= first && $0.date <= today }
}
private func sum(_ list: [UsageRow]) -> UsageAmount {
  list.reduce(UsageAmount()) { $0 + $1.amount }
}
private struct UsageToolPicker: View {
  @Binding var tool: UsageTool
  var body: some View {
    HStack(spacing: 2) {
      ForEach(UsageTool.allCases) { source in
        Button {
          tool = source
        } label: {
          Text(L(source.rawValue)).font(.system(size: 11, weight: .semibold))
            .lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 6)
            .foregroundStyle(source == tool ? ScopeTheme.canvas : ScopeTheme.ink.opacity(0.78))
            .background(source == tool ? ScopeTheme.ink : .clear, in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(tool == source ? .isSelected : [])
      }
    }.padding(3).background(ScopeTheme.raised, in: Capsule())
  }
}
struct UsageSummary: View {
  @ObservedObject var store: UsageStore
  let open: () -> Void
  var body: some View {
    let today = inRange(store.tool.filter(store.rows), 1)
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L("今日 Token")).font(.caption).foregroundStyle(.secondary)
        Spacer()

      }
      Text(shortTokens(sum(today).total)).font(
        .system(size: 32, weight: .semibold, design: .rounded)
      ).monospacedDigit()
      UsageToolPicker(tool: $store.tool)
      ForEach(Array(Set(today.map(\.tool))).sorted(), id: \.self) { tool in
        HStack {
          Text(tool)
          Spacer()
          Text(shortTokens(sum(today.filter { $0.tool == tool }).total))
        }
      }
      QuotaPanel(store: store, compact: true)
      Button(L("查看用量明细"), action: open)
      Text(store.status).font(.caption).foregroundStyle(.secondary)
    }.padding(12).tile().onAppear { store.start() }.onDisappear { store.stop() }
  }
}
private struct QuotaPanel: View {
  @ObservedObject var store: UsageStore
  var compact = false
  @State private var help = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach([UsageTool.codex, .claude].filter { store.tool == .all || store.tool == $0 }) {
        tool in
        let sample = tool == .codex ? store.quota : store.claudeQuota
        let windows = sample?.windows.filter { $0.reset > Date() } ?? []
        if let sample, !windows.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text(L(tool.rawValue) + L(" · 剩余额度")).font(.headline)
            ForEach(windows.indices, id: \.self) { i in
              let w = windows[i]
              HStack {
                Text(w.label); Spacer();
                Text(String(format: L("剩余 %.0f%%"), w.remaining)).monospacedDigit()
              }
              ProgressView(value: w.remaining, total: 100).tint(
                tool == .codex ? ScopeTheme.download : ScopeTheme.yellow)
              Text(L("重置 ") + w.reset.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                .foregroundStyle(.secondary)
            }
            Text(L("本机快照 · ") + sample.date.formatted(date: .abbreviated, time: .shortened)).font(
              .caption2
            ).foregroundStyle(.secondary)
          }.padding(compact ? 0 : 12).background(
            compact ? Color.clear : ScopeTheme.card, in: RoundedRectangle(cornerRadius: 12))
        } else if !compact {
          HStack {
            Text(
              tool == .claude && store.claudeRoute == .external
                ? L("Claude Code · 自定义服务，未提供可验证额度") : L(tool.rawValue) + L(" · 暂无有效额度快照")
            ).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if tool == .claude && store.claudeRoute == .direct { Button(L("接入状态行")) { help = true } }
          }.padding(10).tile()
        }
      }
    }.sheet(isPresented: $help) { ClaudeQuotaSetup() }
  }
}
private struct ClaudeQuotaSetup: View {
  @Environment(\.dismiss) private var dismiss
  @State private var existing = false
  @State private var copied = false
  var body: some View {
    let path = Bundle.main.executableURL?.path ?? "Perch"
    let executable = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    let command = executable + (existing ? " --capture-claude-quota | " : " --claude-statusline")
    VStack(alignment: .leading, spacing: 14) {
      Text(L("接入 Claude Code 额度")).font(.title2.bold())
      Picker(L("当前状态行"), selection: $existing) {
        Text(L("尚未配置")).tag(false); Text(L("已有命令")).tag(true)
      }.pickerStyle(.segmented)
      Text(
        existing
          ? L("在 Claude Code 的 settings.json 中，将下面的命令放在现有 statusLine.command 前面。原命令仍会收到完整输入。")
          : L("在 Claude Code 的 settings.json 中，将 statusLine.type 设为 command，并将下方命令填入 statusLine.command。")
      ).font(.callout)
      Text(command).font(.caption.monospaced()).textSelection(.enabled)
      Text(L("请先把Perch移到常用位置。Claude Code 下次返回限额数据后，这里会显示剩余比例和重置时间。")).font(.caption).foregroundStyle(
        .secondary)
      HStack {
        Button(copied ? L("已复制") : L("复制命令")) {
          NSPasteboard.general.clearContents();
          NSPasteboard.general.setString(command, forType: .string); copied = true
        }; Spacer(); Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.onChange(of: existing) { _ in copied = false }.padding(20).frame(width: 460)
  }
}
struct UsagePage: View {
  @ObservedObject var store: UsageStore
  @State private var days = 7
  @State private var group = L("工具")
  @State private var selected: String?
  @State private var exportError: String?
  var body: some View {
    let rows = inRange(store.tool.filter(store.rows), days)
    let total = sum(rows)
    let groups = Dictionary(grouping: rows) { r in
      group == L("工具")
        ? r.tool
        : group == L("模型")
          ? r.model
          : group == L("项目") ? (r.project.isEmpty ? L("未知项目") : r.project) : r.tool + "/" + r.session
    }
    let amounts = groups.mapValues(sum)
    let ranked = amounts.keys.sorted { a, b in
      let x = amounts[a]!.total
      let y = amounts[b]!.total
      return x == y ? a < b : x > y
    }
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        HStack(spacing: 3) {
          ForEach(UsageTool.allCases) { tool in
            Button {
              store.tool = tool
            } label: {
              Text(L(tool.rawValue)).font(.callout.weight(tool == store.tool ? .semibold : .regular))
                .foregroundStyle(tool == store.tool ? ScopeTheme.ink : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(tool == store.tool ? ScopeTheme.raised : .clear, in: Capsule())
                .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityLabel(L(tool.rawValue)).accessibilityAddTraits(tool == store.tool ? .isSelected : [])
          }
        }.padding(3).background(ScopeTheme.card, in: Capsule())
        Spacer()
        Menu(L("导出")) {
          Button("CSV") { export(rows, false) }
          Button("JSON") { export(rows, true) }
        }.fixedSize().disabled(rows.isEmpty)
      }
      HStack {
        Picker(L("周期"), selection: $days) {
          Text(L("今天")).tag(1)
          Text(L("7 天")).tag(7)
          Text(L("30 天")).tag(30)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 175)
        Spacer()
        Text(store.status).font(.caption).foregroundStyle(.secondary)
        Button {
          store.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.disabled(store.scanning).help(L("重新扫描会话"))

      }
      FittingColumns(minimum: 142, spacing: 12) {
        metric(
          L("Token 总量"), shortTokens(total.total), "square.stack.3d.up.fill", ScopeTheme.labelAccent)
        metric(L("输入"), shortTokens(total.input), "arrow.down.left", ScopeTheme.download)
        metric(L("输出"), shortTokens(total.output), "arrow.up.right", ScopeTheme.upload)
        metric(
          L("缓存命中"),
          total.input > 0
            ? String(format: "%.1f%%", 100 * Double(total.cached) / Double(total.input)) : "—",
          "bolt.fill", ScopeTheme.yellow)
      }
      FittingColumns(minimum: 168, spacing: 12) {
        smallStat(
          L("有用量的会话"), String(Set(rows.map { $0.tool + "/" + $0.session }).count),
          "bubble.left.and.bubble.right")
        smallStat(L("已记录推理"), total.reasoning.map(shortTokens) ?? "—", "brain")
        smallStat(L("已记录缓存写入"), total.cacheWrite.map(shortTokens) ?? "—", "square.and.arrow.down")
      }
      DailyTokenHistory(rows: rows, days: days)
      UsageCalendar(rows: store.tool.filter(store.rows))
      ModelShare(rows: rows)
      QuotaPanel(store: store)
      Picker(L("分组"), selection: $group) {
        ForEach(store.tool == .all ? [L("工具"), L("模型"), L("项目"), L("会话")] : [L("模型"), L("项目"), L("会话")], id: \.self) {
          Text($0)
        }
      }.pickerStyle(.segmented).labelsHidden().fixedSize().onChange(of: group) { _ in
        selected = nil
      }
      LazyVStack(spacing: 8) {
        if ranked.isEmpty {
          Text(
            store.scanning
              ? L("正在索引本机会话…")
              : (store.tool == .all ? L("此时段没有用量记录") : L(store.tool.rawValue) + L(" 在此时段没有用量记录"))
          ).foregroundStyle(.secondary).padding()
        }
        ForEach(ranked, id: \.self) { key in
          let amount = amounts[key]!
          Button {
            selected = selected == key ? nil : key
          } label: {
            HStack {
              Image(systemName: selected == key ? "chevron.down" : "chevron.right").font(.caption)
              Text(group == L("会话") ? groups[key]?.first?.title ?? L("未命名会话") : key).lineLimit(1)
              Spacer()
              Text(shortTokens(amount.total)).monospacedDigit()
            }
          }.buttonStyle(.plain)
          if selected == key {
            HStack {
              Text(L("输入 ") + shortTokens(amount.input))
              Text(L("缓存读取 ") + shortTokens(amount.cached))
              Text(L("输出 ") + shortTokens(amount.output))
              Spacer()
            }.font(.caption).foregroundStyle(ScopeTheme.labelAccent)
          }
          if key != ranked.last { Divider() }
        }
      }.padding(14).tile()
      if let exportError { Text(exportError).foregroundStyle(.red) }
    }
    .onChange(of: store.tool) { tool in
      selected = nil
      if tool != .all && group == L("工具") { group = L("模型") }
    }
    .onAppear { store.start(); if store.tool != .all && group == L("工具") { group = L("模型") } }.onDisappear { store.stop() }
  }
  private func smallStat(_ title: String, _ value: String, _ icon: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
      Text(value).monospacedDigit().font(.headline)
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).tile()
  }
  private func metric(_ title: String, _ value: String, _ symbol: String, _ color: Color)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
          .frame(width: 25, height: 25).background(color.opacity(0.15), in: Circle())
        Text(title).font(.caption).foregroundStyle(.secondary)
      }
      Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).tile()
  }
  private func export(_ rows: [UsageRow], _ json: Bool) {
    let p = NSSavePanel()
    p.allowedContentTypes = json ? [.json] : [.commaSeparatedText]
    p.nameFieldStringValue =
      "Perch-" + (store.tool == .all ? "Usage" : L(store.tool.rawValue)) + "."
      + (json ? "json" : "csv")
    guard p.runModal() == .OK, let url = p.url else { return }
    let keys = [
      "date", "tool", "model", "project", "session", "input", "cached", "output", "total",
      "reasoning_output", "cache_write", "session_title",
    ]
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    let lines = rows.sorted { $0.id < $1.id }.map { r in
      [
        f.string(from: r.date), r.tool, r.model, r.project, r.session, String(r.amount.input),
        String(r.amount.cached), String(r.amount.output), String(r.total),
        r.amount.reasoning.map(String.init) ?? "", r.amount.cacheWrite.map(String.init) ?? "",
        r.title,
      ]
    }
    do {
      let data: Data
      if json {
        data = try JSONSerialization.data(
          withJSONObject: lines.map { Dictionary(uniqueKeysWithValues: zip(keys, $0)) },
          options: [.prettyPrinted, .sortedKeys])
      } else {
        data = Data(
          ([keys] + lines).map {
            $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(
              separator: ",")
          }.joined(separator: "\n").utf8)
      }
      try data.write(to: url, options: .atomic)
      exportError = nil
    } catch { exportError = error.localizedDescription }
  }
}

private struct ModelShare: View {
  let rows: [UsageRow]
  private let colors = [ScopeTheme.download, ScopeTheme.yellow, ScopeTheme.upload, ScopeTheme.labelAccent]
  var body: some View {
    let totals = Dictionary(grouping: rows, by: \.model).mapValues { sum($0).total }
    let ranked = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    let segments = ranked.prefix(3).map { ($0.key, $0.value) } +
      (ranked.count > 3 ? [(L("其他模型"), ranked.dropFirst(3).reduce(0) { $0 + $1.value })] : [])
    let total = segments.reduce(0) { $0 + $1.1 }
    if total > 0 {
      VStack(alignment: .leading, spacing: 9) {
        Label(L("模型用量占比"), systemImage: "chart.bar.xaxis").font(.headline)
        GeometryReader { geo in
          HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { i in
              colors[i].frame(width: geo.size.width * Double(segments[i].1) / Double(total))
            }
          }.clipShape(Capsule())
        }.frame(height: 10).accessibilityHidden(true)
        ForEach(segments.indices, id: \.self) { i in
          HStack {
            Circle().fill(colors[i]).frame(width: 7, height: 7)
            Text(segments[i].0)
            Spacer()
            Text(shortTokens(segments[i].1))
            Text((Double(segments[i].1) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
              .frame(minWidth: 48, alignment: .trailing)
          }.font(.caption).monospacedDigit()
        }
      }.padding(14).tile()
    }
  }
}

enum TokenSplit: String, CaseIterable { case category = "输入输出", tool = "按工具", model = "按模型" }
struct TokenHistoryData {
  let names: [String], dates: [Date], values: [[Int]]
  init(rows: [UsageRow], days: Int, split: TokenSplit, today: Date = Date()) {
    let calendar = Calendar.current
    let end = calendar.startOfDay(for: today)
    let dates = (0..<days).compactMap { calendar.date(byAdding: .day, value: $0 - days + 1, to: end) }
    self.dates = dates
    let indices = Dictionary(uniqueKeysWithValues: dates.enumerated().map { ($0.element, $0.offset) })
    var buckets = Array(repeating: [String:Int](), count: days)
    var total: [String:Int] = [:]
    for row in rows {
      guard let i = indices[calendar.startOfDay(for: row.date)] else { continue }
      if split == .category {
        let cached = min(row.amount.input, max(0, row.amount.cached))
        buckets[i][L("未缓存输入"), default: 0] += row.amount.input - cached
        buckets[i][L("缓存读取"), default: 0] += cached
        buckets[i][L("输出"), default: 0] += row.amount.output
        continue
      }
      let key = split == .model ? row.model : row.tool
      buckets[i][key, default: 0] += row.total
      total[key, default: 0] += row.total
    }
    if split == .category {
      let series = rows.isEmpty ? [] : [L("未缓存输入"), L("缓存读取"), L("输出")]
      names = series
      values = buckets.map { b in series.map { b[$0] ?? 0 } }; return
    }
    let sorted = total.keys.sorted { total[$0] == total[$1] ? $0 < $1 : total[$0]! > total[$1]! }
    let top = Array(sorted.prefix(4))
    let extra = sorted.count > top.count
    names = top + (extra ? [L("其余模型")] : [])
    values = buckets.map { bucket in
      let parts = top.map { bucket[$0] ?? 0 }
      return parts + (extra ? [bucket.values.reduce(0,+) - parts.reduce(0,+)] : [])
    }
  }
}
private struct DailyTokenHistory: View {
  let rows: [UsageRow], days: Int
  @State private var split = TokenSplit.category
  private let colors = [ScopeTheme.download, ScopeTheme.upload, ScopeTheme.yellow, ScopeTheme.live, ScopeTheme.labelAccent]
  var body: some View {
    let data = TokenHistoryData(rows: rows, days: days, split: split)
    let palette =
      split == .category ? [ScopeTheme.download, ScopeTheme.yellow, ScopeTheme.upload] : colors
    let peak = max(1, data.values.map { $0.reduce(0, +) }.max() ?? 0)
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(L("每日 Token 用量"), systemImage: "chart.bar.fill").font(.headline)
        Spacer()
        Picker(L("拆分方式"), selection: $split) {
          ForEach(TokenSplit.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).fixedSize()
      }
      if data.names.isEmpty {
        Text(L("此时段没有用量记录")).font(.caption).foregroundStyle(.secondary)
      } else {
        HStack(alignment: .bottom, spacing: 4) {
          ForEach(data.dates.indices, id: \.self) { day in
            dayBar(data, day: day, peak: peak, palette: palette)

          }
        }
        HStack { Text(data.dates.first?.formatted(.dateTime.month().day()) ?? ""); Spacer(); Text(L("今天")) }.font(.caption2).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), alignment: .leading)], alignment: .leading) {
          ForEach(data.names.indices, id: \.self) { i in
            HStack {
              Circle().fill(palette[i]).frame(width: 7, height: 7);
              Text(data.names[i]).lineLimit(1).help(data.names[i])
            }.font(.caption)
          }
        }
      }
    }.padding(14).tile()
  }
  private func dayBar(_ data: TokenHistoryData, day: Int, peak: Int, palette: [Color]) -> some View
  {
    let amounts = data.values[day]
    let total = amounts.reduce(0, +)
    let parts = zip(data.names, amounts).filter { $0.1 > 0 }.map { $0.0 + " " + $0.1.formatted() }
    let date = data.dates[day].formatted(date: .abbreviated, time: .omitted)
    let hint = ([date, L("总量 ") + total.formatted()] + parts).joined(separator: " · ")
    return VStack(spacing: 0) {
      ForEach(amounts.indices.reversed(), id: \.self) { i in
        palette[i].frame(height: 74 * Double(amounts[i]) / Double(peak))
      }
      if total == 0 { ScopeTheme.raised.frame(height: 2) }
    }.frame(maxWidth: days == 1 ? 44 : .infinity).frame(height: 76, alignment: .bottom)
      .contentShape(Rectangle()).help(hint).accessibilityElement().accessibilityLabel(hint)
  }

}
