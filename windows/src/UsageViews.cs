using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace DeskToys
{
sealed partial class Workspace
{
    void UsagePage()
    {
        Bar(UI.Select(new[] { Data.T("全部工具", "All tools"), "Codex", "Claude Code", "OpenClaw" },
                      Array.IndexOf(Usage.Tools, Data.Pref.Tool), SetUsageTool),
            UI.Select(new[] { Data.T("近 7 天", "7 days"), Data.T("近 30 天", "30 days"), Data.T("近 90 天", "90 days"),
                              Data.T("全部历史", "All history") },
                      Array.IndexOf(new[] { 7, 30, 90, 0 }, days),
                      i =>
                      {
                          days = new[] { 7, 30, 90, 0 }[i];
                          UsageContent();
                      }),
            UI.Btn(Data.T("刷新", "Refresh"), () => RequestUsage(true)), UI.Btn(Data.T("导出", "Export"), ExportUsage),
            UI.Btn(Data.T("接入状态行", "Connect status line"), ConnectStatusLine));
        usageArea = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false,
                                          Margin = Padding.Empty };
        body.Controls.Add(usageArea);
        UsageContent();
        RequestUsage();
    }
    List<UsageRow> PeriodRows()
    {
        string cutoff = days == 0 ? "" : DateTime.Today.AddDays(1 - days).ToString("yyyy-MM-dd");
        return FilteredUsage().Where(r => string.CompareOrdinal(r.Day, cutoff) >= 0).ToList();
    }
    void UsageContent()
    {
        if (usageArea == null || usageArea.IsDisposed)
            return;
        usageArea.SuspendLayout();
        try
        {
            UI.Clear(usageArea);
            var items = usageArea.Controls;
            var rows = PeriodRows();
            var total = Amount.Sum(rows.Select(r => r.Value));
            items.Add(UI.Label(Data.Count(total.Total) + " tokens", 22));
            items.Add(UI.Label(Data.T("输入", "Input") + "  " + Data.Count(total.Input) + "     " + Data.T("输出", "Output") +
                                   "  " + Data.Count(total.Output) + "     " + Data.T("缓存命中", "Cache hits") + "  " +
                                   Data.Count(total.Cached) + "     " + Data.T("推理", "Reasoning") + "  " +
                                   Data.Count(total.Reason),
                               10, UI.Sub));
            items.Add(UI.Label(QuotaText(), 10));
            if (scanError != "")
                items.Add(UI.Label(scanError, 10, UI.Orange));
            items.Add(UI.Row(
                UI.Label(Data.T("每日用量", "Daily tokens"), 14),
                UI.Select(new[] { Data.T("按输入/输出", "By token type"), Data.T("按工具", "By tool"), Data.T("按模型", "By model") },
                          split,
                          i =>
                          {
                              split = i;
                              UsageContent();
                          })));
            var models = rows.GroupBy(r => r.Model)
                             .OrderByDescending(g => g.Sum(r => r.Value.Total))
                             .Select(g => g.Key)
                             .ToArray();
            int top = Math.Min(4, models.Length);
            var modelLabels = models.Take(top).ToList();
            if (models.Length > top)
                modelLabels.Add(Data.T("其他模型", "Other models"));
            string[] keys =
                split == 0 ? new[] { Data.T("非缓存输入", "Other input"), Data.T("缓存命中", "Cache hits"), Data.T("输出", "Output") }
                : split == 1 ? Usage.Tools.Skip(1).ToArray()
                             : modelLabels.ToArray();
            var legend = UI.Row();
            for (int i = 0; i < keys.Length; i++)
                legend.Controls.Add(UI.Label("● " + keys[i], 9, UsageGraph.Colors[i]));
            items.Add(legend);
            var end = DateTime.Today;
            var start = days == 0 && rows.Count > 0
                            ? DateTime.ParseExact(rows.Min(r => r.Day), "yyyy-MM-dd", CultureInfo.InvariantCulture)
                            : end.AddDays(1 - Math.Max(1, days));
            var points =
                rows.GroupBy(r => r.Day)
                    .ToDictionary(
                        g => g.Key,
                        g =>
                        {
                            var a = Amount.Sum(g.Select(x => x.Value));
                            return split == 0 ? new long[] { Math.Max(0, a.Input - a.Cached), a.Cached, a.Output }
                                   : split == 1
                                       ? Usage.Tools.Skip(1)
                                             .Select(k => g.Where(r => r.Tool == k).Sum(r => r.Value.Total))
                                             .ToArray()
                                       : Enumerable.Range(0, keys.Length)
                                             .Select(n => g.Where(r => n < top ? r.Model == models[n]
                                                                               : !models.Take(top).Contains(r.Model))
                                                              .Sum(r => r.Value.Total))
                                             .ToArray();
                        });
            items.Add(new UsageGraph(start, end, points) { Width = innerWidth, Height = 148 });
            var monthly =
                FilteredUsage().GroupBy(r => r.Day).ToDictionary(g => g.Key, g => Amount.Sum(g.Select(x => x.Value)));
            items.Add(UI.Row(UI.Label(Data.T("活动日历", "Activity calendar"), 14), UI.Btn("‹", () => ShiftMonth(-1)),
                             UI.Label(month.ToString("yyyy / MM")), UI.Btn("›", () => ShiftMonth(1)),
                             UI.Btn(Data.T("今天", "Today"), () =>
                                                        {
                                                            selectedDay = DateTime.Today;
                                                            month =
                                                                new DateTime(selectedDay.Year, selectedDay.Month, 1);
                                                            UsageContent();
                                                        })));
            items.Add(new RingCalendar(month, selectedDay, monthly,
                                       d =>
                                       {
                                           selectedDay = d;
                                           UsageContent();
                                       }) { Width = innerWidth, Height = 245 });
            Amount day;
            monthly.TryGetValue(selectedDay.ToString("yyyy-MM-dd"), out day);
            day = day ?? new Amount();
            items.Add(UI.Label(selectedDay.ToString("yyyy-MM-dd") + "    " + Data.T("输入", "Input") + " " +
                                   Data.Count(day.Input) + "   " + Data.T("缓存命中", "Cache hits") + " " +
                                   Data.Count(day.Cached) + "   " + Data.T("输出", "Output") + " " + Data.Count(day.Output),
                               10, UI.Sub));
            var modes = new[] { Data.T("会话", "Session"), Data.T("模型", "Model"), Data.T("项目", "Project"), Data.T("工具", "Tool") };
            items.Add(UI.Row(UI.Label(Data.T("用量明细", "Usage breakdown"), 14), UI.Select(modes, group,
                                                                                       i =>
                                                                                       {
                                                                                           group = i;
                                                                                           UsageContent();
                                                                                       })));
            var table = Table(new[] { modes[group], Data.T("输入", "Input"), Data.T("缓存命中", "Cache hits"),
                                      Data.T("输出", "Output"), Data.T("合计", "Total") },
                              215);
            var groups = rows.GroupBy(r => group == 0   ? r.Tool + "|" + r.Session
                                           : group == 1 ? r.Model
                                           : group == 2 ? r.Project
                                                        : r.Tool)
                             .Select(g => new { Name = group == 0 ? g.First().Title : g.Key,
                                                Value = Amount.Sum(g.Select(r => r.Value)) })
                             .OrderByDescending(g => g.Value.Total);
            foreach (var g in groups)
                table.Rows.Add(g.Name, Data.Count(g.Value.Input), Data.Count(g.Value.Cached),
                               Data.Count(g.Value.Output), Data.Count(g.Value.Total));
            items.Add(table);
        }
        finally
        {
            usageArea.ResumeLayout(true);
        }
    }
    void ShiftMonth(int step)
    {
        if (month.Year == 1 && step < 0 || month.Year == 9999 && step > 0)
            return;
        month = month.AddMonths(step);
        selectedDay = month;
        UsageContent();
    }
    void ConnectStatusLine()
    {
        using (var f = new Form { Text = Data.T("接入 Claude Code 状态行", "Connect Claude Code status line"),
                                  ClientSize = new Size(520, 195) })
        {
            UI.Theme(f);
            var row = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(10),
                                            FlowDirection = FlowDirection.TopDown };
            var help = UI.Label(
                Data.T("将以下配置合并到 Claude Code 的 settings.json。已有状态行可复制管道前缀。",
                  "Merge this into Claude Code settings.json. For an existing status line, copy the pipeline prefix."));
            help.MaximumSize = new Size(480, 0);
            row.Controls.Add(help);
            var exe = Data.Quote(Application.ExecutablePath.Replace('\\', '/'));
            var json = Data.Json().Serialize(
                new { statusLine = new { type = "command", command = exe + " --claude-statusline" } });
            row.Controls.Add(new TextBox { Width = 475, Height = 58, Multiline = true, ReadOnly = true, Text = json });
            row.Controls.Add(UI.Row(UI.Btn(Data.T("复制配置", "Copy configuration"), () => Clipboard.SetText(json)),
                                    UI.Btn(Data.T("复制管道前缀", "Copy pipeline prefix"),
                                           () => Clipboard.SetText(exe + " --capture-claude-quota | "))));
            f.Controls.Add(row);
            f.ShowDialog(this);
        }
    }
    static string Csv(string v)
    {
        return "\"" + (v ?? "").Replace("\"", "\"\"") + "\"";
    }
    void ExportUsage()
    {
        using (var d = new SaveFileDialog { Filter = "CSV|*.csv|JSON|*.json", FileName = "Perch-usage" })
        {
            if (d.ShowDialog(this) != DialogResult.OK)
                return;
            var rows = PeriodRows();
            if (d.FilterIndex == 2)
            {
                File.WriteAllText(d.FileName, Data.Json().Serialize(rows), Encoding.UTF8);
                return;
            }
            using (var w = new StreamWriter(d.FileName, false, new UTF8Encoding(true)))
            {
                w.WriteLine("Day,Tool,Session,Title,Project,Model,Input,CacheRead,CacheWrite,Output,Reasoning,Total");
                foreach (var r in rows.OrderBy(x => x.Day))
                {
                    var a = r.Value;
                    w.WriteLine(
                        string.Join(",", new[] { r.Day, r.Tool, r.Session, r.Title, r.Project, r.Model }.Select(Csv)) +
                        "," + string.Join(",", new[] { a.Input, a.Cached, a.Write, a.Output, a.Reason, a.Total }));
                }
            }
        }
    }
}
class UsageGraph : Control
{
    internal static readonly Color[] Colors = { UI.Blue, UI.Yellow, UI.Orange, UI.Green, Color.MediumOrchid };
    readonly DateTime from, to;
    readonly Dictionary<string, long[]> values;
    internal UsageGraph(DateTime start, DateTime end, Dictionary<string, long[]> data)
    {
        from = start;
        to = end;
        values = data;
        BackColor = UI.Card;
        DoubleBuffered = true;
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        int days = (to - from).Days + 1;
        int n = Math.Min(days, Math.Max(1, (Width - 65) / 4));
        var bins = new double[n, Colors.Length];
        foreach (var kv in values)
        {
            DateTime date;
            if (!DateTime.TryParseExact(kv.Key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None,
                                        out date))
                continue;
            int x = (date - from).Days;
            if (x < 0 || x >= days)
                continue;
            int b = (int)((long)x * n / days);
            for (int i = 0; i < kv.Value.Length; i++)
                bins[b, i] += kv.Value[i];
        }
        double max = Enumerable.Range(0, n).Max(i => Enumerable.Range(0, Colors.Length).Sum(j => bins[i, j]));
        var g = e.Graphics;
        var box = new RectangleF(47, 14, Math.Max(1, Width - 58), Height - 41);
        float dx = box.Width / n;
        using (var pen = new Pen(UI.Raised)) for (int y = 0; y < 3; y++)
        {
            float h = box.Bottom - y * box.Height / 2;
            g.DrawLine(pen, box.Left, h, box.Right, h);
            TextRenderer.DrawText(g, Data.Count((long)(max * y / 2)), Font, new Point(1, (int)h - 7), UI.Sub);
        }
        if (max > 0)
            for (int x = 0; x < n; x++)
            {
                float bottom = box.Bottom;
                for (int i = 0; i < Colors.Length; i++)
                {
                    float h = (float)(bins[x, i] / max * box.Height);
                    using (var brush = new SolidBrush(Colors[i]))
                        g.FillRectangle(brush, box.Left + x * dx + 1, bottom - h, Math.Max(1, dx - 2), h);
                    bottom -= h;
                }
            }
        TextRenderer.DrawText(g, from.ToString("yyyy-MM-dd"), Font, new Point(43, Height - 21), UI.Sub);
        TextRenderer.DrawText(g, to.ToString("yyyy-MM-dd"), Font, new Rectangle(0, Height - 21, Width - 5, 21), UI.Sub,
                              TextFormatFlags.Right);
    }
}
class RingCalendar : Control
{
    readonly DateTime month, selected;
    readonly Dictionary<string, Amount> amounts;
    readonly Action<DateTime> pick;
    int offset { get { return (6 + (int)month.DayOfWeek) % 7; } }
    public RingCalendar(DateTime m, DateTime sel, Dictionary<string, Amount> map, Action<DateTime> choose)
    {
        month = m;
        selected = sel;
        amounts = map;
        pick = choose;
        BackColor = UI.Card;
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Y < 22 || e.X < 0 || e.X >= Width)
            return;
        int d = (e.Y - 22) / 37 * 7 + e.X * 7 / Width - offset + 1;
        if (d > 0 && d <= DateTime.DaysInMonth(month.Year, month.Month))
            pick(month.AddDays(d - 1));
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var fmt = Data.Chinese ? new CultureInfo("zh-CN") : new CultureInfo("en-US");
        var period = month.ToString("yyyy-MM-");
        var peak = new double[] { 1, 1, 1 };
        foreach (var v in amounts.Where(p => p.Key.StartsWith(period, StringComparison.Ordinal)).Select(p => p.Value))
        {
            peak[0] = Math.Max(peak[0], v.Input);
            peak[1] = Math.Max(peak[1], v.Cached);
            peak[2] = Math.Max(peak[2], v.Output);
        }
        float cw = Width / 7f;
        for (int i = 0; i < 7; i++)
            TextRenderer.DrawText(g, fmt.DateTimeFormat.AbbreviatedDayNames[(i + 1) % 7], Font,
                                  new Point((int)(i * cw + 5), 3), UI.Sub);
        for (int d = 1; d <= DateTime.DaysInMonth(month.Year, month.Month); d++)
        {
            int pos = offset + d - 1;
            float x = (pos % 7) * cw + 4, y = 22 + pos / 7 * 37;
            DateTime date = month.AddDays(d - 1);
            if (date == selected)
                using (var b = new SolidBrush(UI.Raised)) g.FillRectangle(b, x - 3, y - 1, cw - 2, 34);
            Amount v;
            amounts.TryGetValue(date.ToString("yyyy-MM-dd"), out v);
            v = v ?? new Amount();
            var a = new[] { v.Input, v.Cached, v.Output };
            for (int i = 0; i < 3; i++)
            {
                var r = new RectangleF(x + 2 + i * 4, y + 2 + i * 4, 28 - 8 * i, 28 - 8 * i);
                using (var p = new Pen(Color.FromArgb(60, UsageGraph.Colors[i]), 3)) g.DrawEllipse(p, r);
                if (a[i] > 0)
                    using (var p = new Pen(UsageGraph.Colors[i], 3))
                        g.DrawArc(p, r, -90, (float)Math.Min(360, 360 * a[i] / peak[i]));
            }
            TextRenderer.DrawText(g, d.ToString(), Font, new Point((int)x + 35, (int)y + 8),
                                  date == selected ? UI.Blue : UI.Ink);
        }
    }
}
}
