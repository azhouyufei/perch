using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;
namespace DeskToys
{
sealed partial class Workspace
{
    readonly string[] zhPages = { "工作台", "系统监控", "AI 用量", "待办", "剪贴板", "截图库", "偏好设置" },
                      enPages = { "Dashboard", "System monitor", "AI usage", "Tasks",
                                  "Clipboard", "Screenshots",    "Settings" };
    readonly string[] metricZh = { "处理器",   "内存",     "网络上传", "网络下载",
                                   "磁盘读取", "磁盘写入", "GPU",      "已用交换空间" },
                      metricEn = { "CPU",       "Memory",     "Upload", "Download",
                                   "Disk read", "Disk write", "GPU",    "Page file" };
    readonly Color[] accents = { UI.Blue, UI.Yellow, UI.Orange, UI.Blue, UI.Green, UI.Orange, UI.Yellow, UI.Blue };
    List<Label> cardValues = new List<Label>();
    List<Plot> plots = new List<Plot>();
    Label awakeState, systemDetail, sensorDetail;
    DataGridView processes, networkGrid;
    TextBox procFilter;
    int metric, windowSeconds = 120, procSort = 2, netSort = 3, sensorIdx;
    bool procAsc, netAsc, allProcs, allNet, done, instruments=true;
    string[] sensorKeys = { "Temperature", "Power", "Voltage", "Fan", "Frequency" };
    ListBox clipList;
    TextBox clipSearch;
    int clipMode;
    FlowLayoutPanel usageArea;
    int days = 7, group, split;
    DateTime month = new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1), selectedDay = DateTime.Today;
    readonly List<Button> navButtons=new List<Button>();
    readonly List<Label> details=new List<Label>();
    Label activityClock, hardwareSummary, networkSummary;
    int D(int value){return Appearance.Px(this,value);}
    int innerWidth {get{return Math.Max(D(300),body.ClientSize.Width-SystemInformation.VerticalScrollBarWidth-D(8));}}
    internal static void RefreshRegisteredPaths()
    {
        var executable = Application.ExecutablePath;
        if (string.Equals(Data.Pref.RegisteredExecutable, executable, StringComparison.OrdinalIgnoreCase)) return;
        const string runKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        bool enabled;
        using (var key = Registry.CurrentUser.OpenSubKey(runKey))
            enabled = key != null && (key.GetValue("DeskToys") != null || key.GetValue("Perch") != null);
        if (enabled)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(runKey))
            {
                key.SetValue("Perch", Data.Quote(executable));
                key.DeleteValue("DeskToys", false);
            }
        }
        bool registered = true;
        foreach (var task in Data.Book.Tasks.Where(t => !t.Done && !t.Notified && t.Remind > DateTime.Now))
            registered &= Tasks.UpdateReminder(task);
        if (registered)
        {
            Data.Pref.RegisteredExecutable = executable;
            Data.Save();
        }
    }
    void BuildShell()
    {
        Controls.Clear();navButtons.Clear();
        sidebar=new FlowLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(D(9),D(14),D(9),0),FlowDirection=FlowDirection.TopDown,WrapContents=false,BackColor=UI.Card};
        var rail=new Panel{Dock=DockStyle.Left,Width=D(160),BackColor=UI.Card};
        Text = Data.AppName + " 2.15";
        var brand=UI.Label(Data.AppName,15);brand.Font=new Font(brand.Font,FontStyle.Bold);brand.AutoSize=false;brand.Size=new Size(D(135),D(46));
        brand.TextAlign=ContentAlignment.MiddleRight;brand.ImageAlign=ContentAlignment.MiddleLeft;brand.Image=new Bitmap(Icon.ToBitmap(),new Size(D(33),D(33)));brand.Margin=new Padding(D(4),0,0,D(17));sidebar.Controls.Add(brand);
        var symbols=new[]{"dashboard","activity","usage","tasks","clipboard","gallery","settings"};
        for(int i=0;i<zhPages.Length;i++){
            int pageIndex=i;var nav=UI.Btn(Data.T(zhPages[i],enPages[i]),()=>{if(pageIndex==1)instruments=true;Navigate(pageIndex);});
            nav.AutoSize=false;nav.Size=new Size(D(136),D(37));nav.Margin=new Padding(D(2),D(3),0,D(2));
            nav.TextImageRelation=TextImageRelation.ImageBeforeText;nav.ImageAlign=ContentAlignment.MiddleLeft;nav.TextAlign=ContentAlignment.MiddleLeft;
            nav.Padding=new Padding(D(10),0,0,0);Appearance.ButtonIcon(nav,symbols[i],UI.Sub,17);navButtons.Add(nav);
            if(i<6)sidebar.Controls.Add(nav);else{var footer=new Panel{Dock=DockStyle.Bottom,Height=D(58),Padding=new Padding(D(10),D(5),D(10),D(14))};nav.Dock=DockStyle.Fill;footer.Controls.Add(nav);rail.Controls.Add(footer);}
        }
        rail.Controls.Add(sidebar);sidebar.BringToFront();
        content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 12, 8, 8), BackColor = UI.Bg };
        heading = UI.Label("", 20);
        heading.AutoSize = false;
        heading.Dock = DockStyle.Top;
        heading.Height = D(53);heading.Font=new Font(heading.Font,FontStyle.Bold);
        body = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, WrapContents = false,
                                     FlowDirection = FlowDirection.TopDown };
        content.Controls.Add(body);
        content.Controls.Add(heading);
        Controls.Add(content);
        Controls.Add(rail);
        body.SizeChanged += (s, e) =>
        {
            if (content == null)
                return;
            foreach (Control c in body.Controls)
                if (Equals(c.Tag, "stretch"))
                    c.Width = innerWidth;
        };
    }
    void Navigate(int target)
    {
        page = target;
        body.SuspendLayout();
        try
        {
            cardValues.Clear();details.Clear();activityClock=hardwareSummary=networkSummary=null;
            plots.Clear();
            processes = networkGrid = null;
            systemDetail = sensorDetail = awakeState = null;
            procFilter = null;
            clipList = null;
            usageArea = null;
            UI.Clear(body);
            heading.Text = Data.T(zhPages[page], enPages[page]);
            for (int i = 0; i < zhPages.Length; i++)
            {
                var b = navButtons[i];
                b.ForeColor = i == page ? UI.Blue : UI.Ink;
                b.BackColor = i == page ? UI.Raised : UI.Card;
            }
            switch (page)
            {
            case 0:
                Dashboard();
                break;
            case 1:
                MonitorPage();
                break;
            case 2:
                UsagePage();
                break;
            case 3:
                TodosPage();
                break;
            case 4:
                ClipboardPage();
                break;
            case 5:
                GalleryPage();
                break;
            case 6:
                Preferences();
                break;
            }
        }
        finally
        {
            body.ResumeLayout(true);
        }
    }
    void Section(string title)
    {
        body.Controls.Add(UI.Label(title, 13));
    }
    FlowLayoutPanel Bar(params Control[] c)
    {
        var b = UI.Row(c);
        body.Controls.Add(b);
        return b;
    }
    TableLayoutPanel Columns(int count,int height){
        var grid=new TableLayoutPanel{Width=innerWidth,Height=D(height),Tag="stretch",ColumnCount=count,RowCount=1,Margin=new Padding(0,0,0,D(6)),Padding=Padding.Empty};
        for(int i=0;i<count;i++)grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100f/count));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent,100));body.Controls.Add(grid);return grid;
    }
    void Metrics(int count,int columns){
        for(int first=0;first<count;first+=columns){var grid=Columns(columns,count==4?122:92);
            for(int j=0;j<columns&&j+first<count;j++){
                int m=first+j;var card=new Panel{Dock=DockStyle.Fill,Margin=new Padding(D(3)),BackColor=UI.Card,Cursor=Cursors.Hand};
                Appearance.Round(card,14);var name=UI.Label(Data.T(metricZh[m],metricEn[m]),9,UI.Sub);name.Location=new Point(D(34),D(10));
                var icon=new PictureBox{SizeMode=PictureBoxSizeMode.Zoom,Size=new Size(D(18),D(18)),Location=new Point(D(11),D(10))};
                icon.Image=Appearance.Symbol(new[]{"activity","memory","up","down","save","pen","activity","memory"}[m],accents[m],D(24));icon.Disposed+=delegate{icon.Image.Dispose();};
                var value=UI.Label("—",count==4?19:15);value.Location=new Point(D(10),D(32));cardValues.Add(value);
                var plot=new Plot{Metric=m,Accent=accents[m],Samples=history,Dock=DockStyle.Bottom,Height=D(count==4?29:20),Seconds=page==1?windowSeconds:120};plots.Add(plot);
                card.Controls.AddRange(new Control[]{name,icon,value,plot});
                if(count==4){var detail=UI.Label("",8,UI.Sub);detail.Location=new Point(D(10),D(69));details.Add(detail);card.Controls.Add(detail);}
                EventHandler go=(o,e)=>{metric=m;instruments=false;Navigate(1);};card.Click+=go;foreach(Control child in card.Controls)child.Click+=go;
                if(page==1&&metric==m){card.Paint+=(o,e)=>{using(var pen=new Pen(accents[m],2))e.Graphics.DrawLine(pen,D(12),2,card.Width-D(12),2);};}
                grid.Controls.Add(card,j,0);
            }
        }
    }
    void Dashboard(){
        activityClock=UI.Label("",9,UI.Sub);Bar(UI.Label(Data.T("系统活动","System activity"),12),activityClock);
        Metrics(4,4);ProcessTables();Sensors();
        awakeState=UI.Label(AwakeText(),10,UI.Sub);
        Bar(UI.Label(Data.T("保持唤醒","Keep awake"),12),awakeState,UI.Btn(Data.T("选择时长","Duration"),()=>ShowMenu(true)));
        var hint=UI.Label("",9,UI.Sub);Bar(UI.Label(Data.T("截图工具","Capture tools"),12),hint);
        var strip=Columns(6,53);
        var keys=new[]{"region","window","display","pin","color","gallery"};
        var names=new[]{Data.T("区域截图","Capture region"),Data.T("窗口截图","Capture window"),Data.T("全屏截图","Capture display"),Data.T("剪贴板贴图","Pin clipboard"),Data.T("屏幕取色","Pick color"),Data.T("截图库","Gallery")};
        var colors=new[]{UI.Blue,UI.Yellow,UI.Orange,Appearance.Purple,UI.Green,Appearance.Teal};
        for(int i=0;i<keys.Length;i++){int k=i;var button=UI.Btn("",()=>{if(k==3)PinClipboard();else if(k==5)Navigate(5);else CaptureScreen(keys[k]);},names[k]);
            button.AutoSize=false;button.Dock=DockStyle.Fill;button.AccessibleName=names[k];button.BackColor=UI.Card;
            Appearance.ButtonIcon(button,keys[k],colors[k],27);button.MouseEnter+=delegate{hint.Text=names[k];};button.MouseLeave+=delegate{hint.Text="";};strip.Controls.Add(button,i,0);}
        Bar(UI.Label(Data.T("最近截图","Recent captures"),12),UI.Btn(Data.T("查看全部","View all"),()=>Navigate(5)));Thumbnails(3);RefreshMonitor();
    }
    void MonitorPage(){
        body.Controls.Add(Appearance.Segments(new[]{Data.T("仪表面板","Instruments"),Data.T("活动趋势","Trends")},instruments?0:1,i=>{instruments=i==0;Navigate(1);}));
        if(instruments){var pair=Columns(2,156);for(int i=0;i<2;i++){int m=i==0?0:3;
            var panel=new Panel{Dock=DockStyle.Fill,BackColor=UI.Card,Margin=new Padding(D(3))};Appearance.Round(panel,12);
            var title=UI.Label(i==0?Data.T("硬件","Hardware"):Data.T("网络与存储","Network and storage"),12,UI.Ink);title.Location=new Point(D(10),D(7));panel.Controls.Add(title);
            var values=UI.Label("",9,UI.Sub);values.AutoSize=false;values.AutoEllipsis=true;values.SetBounds(D(10),D(37),panel.Width-D(20),D(65));values.Anchor=AnchorStyles.Left|AnchorStyles.Right|AnchorStyles.Top;
            if(i==0)hardwareSummary=values;else networkSummary=values;panel.Controls.Add(values);
            var chart=new Plot{Metric=m,Accent=accents[m],Samples=history,Dock=DockStyle.Bottom,Height=D(55)};plots.Add(chart);panel.Controls.Add(chart);pair.Controls.Add(panel,i,0);}ProcessTables();}
        else{
            Bar(UI.Label(Data.T("活动趋势","Activity trend"),13),Appearance.Segments(new[]{Data.T("2 分钟","2 min"),Data.T("10 分钟","10 min")},windowSeconds==120?0:1,
                i=>{windowSeconds=i==0?120:600;Navigate(1);}),UI.Btn(paused?Data.T("继续采样","Resume"):Data.T("暂停采样","Pause"),()=>{paused=!paused;Navigate(1);}));
            Section(Data.T(metricZh[metric],metricEn[metric]));
            var graph=new Plot{Metric=metric,Samples=history,Seconds=windowSeconds,Accent=accents[metric],Width=innerWidth,Height=D(142),Tag="stretch"};
            plots.Add(graph);body.Controls.Add(graph);Metrics(8,3);ProcessTables();
        }
        systemDetail = UI.Label("", 10);
        body.Controls.Add(systemDetail);
        Section(Data.T("核心负载", "Core load"));
        var heat = new Plot { Heat = true,
                              Seconds = 120,
                              Samples = history,
                              Width = innerWidth,
                              Height = Math.Min(260, Math.Max(75, Environment.ProcessorCount * 11)),
                              Tag = "stretch" };
        plots.Add(heat);
        body.Controls.Add(heat);
        foreach (int index in new[] { 8, 7 })
        {
            Section(index == 8 ? Data.T("内存压力 · 10 分钟", "Memory pressure · 10 min")
                               : Data.T("分页文件占用 · 10 分钟", "Page file use · 10 min"));
            var line = new Plot { Samples = history,  Seconds = 600,
                                  Metric = index,     Accent = index == 8 ? UI.Yellow : UI.Orange,
                                  Width = innerWidth, Height = 72,
                                  Tag = "stretch" };
            plots.Add(line);
            body.Controls.Add(line);
        }
        Sensors();
        var pub = UI.Btn(Data.T("查询公共 IP", "Look up public IP"), () =>
                                                                {});
        pub.Click += async (s, e) =>
        {
            pub.Enabled = false;
            try
            {
                using (var w = new WebClient()) pub.Text =
                    (await w.DownloadStringTaskAsync("https://api.ipify.org")).Trim();
            }
            catch (Exception ex)
            {
                Report(ex.Message);
            }
            finally
            {
                pub.Enabled = true;
            }
        };
        body.Controls.Add(pub);
        RefreshMonitor();
    }
    void Sensors()
    {
        Section(Data.T("传感器明细", "Sensors"));
        body.Controls.Add(Appearance.Segments(new[]{Data.T("温度","Temperature"),Data.T("功率","Power"),Data.T("电压","Voltage"),Data.T("风扇","Fans"),Data.T("频率","Frequency")},sensorIdx,i=>{sensorIdx=i;Navigate(page);}));
        sensorDetail = UI.Label("", 10, UI.Sub);
        sensorDetail.MaximumSize = new Size(innerWidth, 0);
        body.Controls.Add(sensorDetail);
    }
    DataGridView Table(string[] columns, int height)
    {
        var g = new DataGridView { Width = innerWidth,
                                   Height = height,
                                   Tag = "stretch",
                                   ReadOnly = true,
                                   AllowUserToAddRows = false,
                                   AllowUserToDeleteRows = false,
                                   AllowUserToResizeRows = false,
                                   RowHeadersVisible = false,
                                   AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
                                   BackgroundColor = UI.Card,
                                   BorderStyle = BorderStyle.None,
                                   GridColor = UI.Raised,
                                   SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                                   MultiSelect = false,
                                   EnableHeadersVisualStyles = false };
        g.CellBorderStyle=DataGridViewCellBorderStyle.SingleHorizontal;g.ColumnHeadersBorderStyle=DataGridViewHeaderBorderStyle.None;
        g.ColumnHeadersDefaultCellStyle.SelectionBackColor=UI.Raised;g.ColumnHeadersDefaultCellStyle.SelectionForeColor=UI.Sub;
        g.ColumnHeadersHeight=D(24);g.RowTemplate.Height=D(23);
        g.DefaultCellStyle.BackColor = UI.Card;
        g.DefaultCellStyle.ForeColor = UI.Ink;
        g.DefaultCellStyle.SelectionBackColor = UI.Raised;
        g.DefaultCellStyle.SelectionForeColor = UI.Blue;
        g.ColumnHeadersDefaultCellStyle.BackColor = UI.Raised;
        g.ColumnHeadersDefaultCellStyle.ForeColor = UI.Ink;
        for (int i = 0; i < columns.Length; i++)
        {
            g.Columns.Add("col" + i, columns[i]);
            g.Columns[i].SortMode = DataGridViewColumnSortMode.Programmatic;
        }
        return g;
    }
    void ProcessTables()
    {
        if(allNet||allProcs){procFilter=new TextBox{Width=D(190),BackColor=UI.Raised,ForeColor=UI.Ink,BorderStyle=BorderStyle.FixedSingle};procFilter.TextChanged+=delegate{RefreshMonitor();};Bar(UI.Label(Data.T("筛选进程 / PID","Filter process / PID")),procFilter);}
        var grid=Columns(2,allProcs||allNet?278:211);
        for(int i=0;i<2;i++){bool net=i==1;
            var panel=new Panel{Dock=DockStyle.Fill,BackColor=UI.Card,Margin=new Padding(D(3)),Padding=new Padding(D(8))};Appearance.Round(panel,12);
            var header=new Panel{Dock=DockStyle.Top,Padding=new Padding(0,0,0,D(9))};
            var title=UI.Label(net?Data.T("网络分析","Network traffic"):Data.T("资源占用","Processes"),11);title.AutoSize=false;title.TextAlign=ContentAlignment.MiddleLeft;title.Dock=DockStyle.Fill;header.Controls.Add(title);
            var expand=UI.Btn((net?allNet:allProcs)?Data.T("收起","Less"):Data.T("展开","More"),()=>{if(net)allNet=!allNet;else allProcs=!allProcs;Navigate(page);});
            var preferred=expand.GetPreferredSize(Size.Empty);
            header.Height=Math.Max(D(30),preferred.Height)+header.Padding.Vertical;
            expand.AutoSize=false;expand.Width=Math.Max(D(52),preferred.Width);expand.Dock=DockStyle.Right;
            header.Controls.Add(expand);title.BringToFront();var table=Table(new[]{Data.T("进程","Process"),"PID",net?Data.T("上传","Upload"):"CPU",net?Data.T("下载","Download"):Data.T("内存","Memory")},140);
            if(net)networkGrid=table;else processes=table;
            table.Columns[0].FillWeight=155;table.Columns[1].FillWeight=47;table.Columns[2].FillWeight=64;table.Columns[3].FillWeight=72;
            table.Dock=DockStyle.Fill;table.ColumnHeaderMouseClick+=(o,e)=>{if(net){netAsc=netSort==e.ColumnIndex&&!netAsc;netSort=e.ColumnIndex;}else{procAsc=procSort==e.ColumnIndex&&!procAsc;procSort=e.ColumnIndex;}RefreshMonitor();};
            panel.Controls.Add(table);panel.Controls.Add(header);grid.Controls.Add(panel,i,0);
        }
    }
    void RefreshMonitor()
    {
        if (!Visible || page > 1)
            return;
        for (int i = 0; i < cardValues.Count; i++)
            cardValues[i].Text = Plot.Format(latest.Metric(i), i);
        if(hardwareSummary!=null){hardwareSummary.Text="CPU  "+Plot.Format(latest.Cpu,0)+"     GPU  "+Plot.Format(latest.Gpu,6)+Environment.NewLine+
            Data.T("内存   ","Memory   ")+Data.Size(latest.Used)+" / "+Data.Size(latest.Total)+Environment.NewLine+Data.T("内存压力   ","Memory pressure   ")+Plot.Format(latest.Pressure,8);}
        if(networkSummary!=null){networkSummary.Text="↑ "+Plot.Format(latest.Up,2)+"     ↓ "+Plot.Format(latest.Down,3)+Environment.NewLine+latest.Interfaces+Environment.NewLine+
            Data.T("磁盘可用   ","Disk available   ")+Data.Size(latest.FreeDisk);}
        if(activityClock!=null)activityClock.Text=paused?Data.T("已暂停","Paused"):latest.At.ToString("T");
        for(int i=0;i<details.Count;i++){int m=i;details[i].Text=i==0?Environment.ProcessorCount+Data.T(" 核"," cores"):i==1?Data.Size(latest.Used)+" / "+Data.Size(latest.Total):
            Data.T("2 分钟峰值 ","2 min peak ")+Plot.Format(history.Where(h=>h.At>=latest.At.AddMinutes(-2)).Select(h=>h.Metric(m)).Where(v=>!double.IsNaN(v)).DefaultIfEmpty(double.NaN).Max(),m);}
        foreach (var p in plots)
            p.Invalidate();
        if (systemDetail != null)
        {
            systemDetail.MaximumSize = new Size(innerWidth, 0);
            systemDetail.Text = Data.T(metricZh[metric], metricEn[metric]) + "  " +
                                Plot.Format(latest.Metric(metric), metric) + "    RAM " + Data.Size(latest.Used) +
                                " / " + Data.Size(latest.Total) + "    " + Data.T("磁盘可用 ", "Disk free ") +
                                Data.Size(latest.FreeDisk) + "\n" + latest.Interfaces + "   " + latest.Power;
        }
        List<string> sensor;
        if (sensorDetail != null)
            sensorDetail.Text = latest.Sensors.TryGetValue(sensorKeys[sensorIdx], out sensor)
                                    ? string.Join("       ", sensor)
                                    : Data.T("当前硬件未提供此类读数", "No readings available from this hardware");
        if (processes == null)
            return;
        var filter = procFilter==null?"":procFilter.Text;
        var procs = latest.Processes
                        .Where(x => x.Name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0 ||
                                    x.Pid.ToString().Contains(filter))
                        .ToList();
        foreach (bool net in new[] { false, true })
        {
            var g = net ? networkGrid : processes;
            if (g == null)
                continue;
            var data = net ? procs.Where(x => !double.IsNaN(x.Up)).ToList() : procs;
            int sort = net ? netSort : procSort;
            bool asc = net ? netAsc : procAsc;
            Func<ProcRow, IComparable> key = r => sort == 0   ? (IComparable)r.Name
                                                  : sort == 1 ? (IComparable)r.Pid
                                                  : sort == 2 ? (net ? r.Up : r.Cpu)
                                                              : (net ? r.Down : r.Memory);
            var rows = (asc ? data.OrderBy(key) : data.OrderByDescending(key))
                           .Take((net ? allNet : allProcs) ? int.MaxValue : 5);
            int first = g.FirstDisplayedScrollingRowIndex;
            g.Rows.Clear();
            foreach (var r in rows)
                g.Rows.Add(r.Name, r.Pid, net ? Plot.Format(r.Up, 2) : Plot.Format(r.Cpu, 0),
                           net ? Plot.Format(r.Down, 3) : Data.Size(r.Memory));
            if (net && g.Rows.Count == 0)
                g.Rows.Add(Data.T("暂未获得 TCP 连接速率", "No TCP rates available"), "—", "—", "—");
            if (first > 0 && first < g.Rows.Count)
                g.FirstDisplayedScrollingRowIndex = first;
            g.ClearSelection();
        }
    }
    void UpdateAwake()
    {
        if (awakeState != null && !awakeState.IsDisposed)
            awakeState.Text = AwakeText();
    }
    void RevealNote(Note note){
        if(note==null)return;
        NoteWindow window;
        if(!notes.TryGetValue(note.Id,out window)||window.IsDisposed)ShowNotes();
        if(notes.TryGetValue(note.Id,out window))window.Reveal();
    }
    void TodosPage()
    {
        var menu = UI.Btn(Data.T("桌面便签","Desktop notes"),()=>{
            var notesWithTasks=Data.Book.Notes.Where(n=>Data.Book.Tasks.Any(t=>!t.Done&&t.Note==n.Id)).ToArray();
            if(notesWithTasks.Length==0){MessageBox.Show(this,Data.T("点击待办旁的“贴到桌面”创建便签。","Use Pin to desktop beside a task to create a note."),Data.AppName);return;}
            int i=Tasks.Choose(this,Data.T("显示桌面便签","Show desktop note"),notesWithTasks.Select(n=>n.Title).ToArray());
            if(i>=0){var n=notesWithTasks[i];n.Pinned=true;Tasks.Commit();RevealNote(n);}
        });
        Bar(UI.Select(new[] { Data.T("待完成", "To do"), Data.T("已完成", "Completed") }, done ? 1 : 0,
                      i =>
                      {
                          done = i == 1;
                          Navigate(3);
                      }),
            menu, UI.Btn("＋ " + Data.T("新建待办", "New task"), () => Tasks.Edit(null)));
        foreach (var task in Data.Book.Tasks.Where(t => t.Done == done).OrderBy(t => t.Due ?? DateTime.MaxValue))
        {
            bool pinned=Data.Book.Notes.Any(n=>n.Id==task.Note&&n.Pinned);
            var pin=UI.Btn(pinned?Data.T("显示便签","Show note"):Data.T("贴到桌面","Pin to desktop"),
                           ()=>RevealNote(Tasks.PinToDesktop(task)));
            pin.AccessibleName=pin.Text;pin.TextImageRelation=TextImageRelation.ImageBeforeText;
            Appearance.ButtonIcon(pin,"pin",Appearance.Purple,17);pin.Enabled=!done;
            var move=UI.IconButton("more",UI.Sub,()=>{},Data.T("选择便签","Choose note"));move.Enabled=!done;move.Click+=(o,e)=>Tasks.ChooseNote(move,task);
            var title = UI.Label(task.Title + (string.IsNullOrEmpty(task.Detail) ? "" : "  ·  " + task.Detail) +
                                     (task.Due.HasValue ? "   ◷ " + task.Due.Value.ToString("g") : ""),
                                 11);
            title.MaximumSize = new Size(innerWidth - 215, 0);
            title.Click += (s, e) => Tasks.Edit(task);
            var row =
                Bar(UI.IconButton(done?"check":"circle",UI.Green,()=>Tasks.Check(task),done?Data.T("恢复待办","Reopen task"):Data.T("完成待办","Complete task")), title, pin, move, UI.IconButton("pen",UI.Blue,()=>Tasks.Edit(task),Data.T("编辑","Edit")),
                    UI.IconButton("trash",UI.Orange, () =>
                                {
                                    if (Confirm(Data.T("删除待办？", "Delete task?")))
                                        Tasks.Delete(task);
                                },Data.T("删除待办","Delete task")));
            row.BackColor = UI.Card;
        }
        if (!Data.Book.Tasks.Any(t => t.Done == done))
            body.Controls.Add(UI.Label(Data.T("暂无待办", "No tasks"), 11, UI.Sub));
    }
    static bool Confirm(string text)
    {
        return MessageBox.Show(text, Data.AppName, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) ==
               DialogResult.OK;
    }
    void ClipboardPage()
    {
        clipSearch = new TextBox { Width = 230 };
        clipSearch.TextChanged += (s, e) => FillClips();
        Bar(UI.Label(Data.T("搜索", "Search")), clipSearch,
            UI.Select(new[] { Data.T("包含", "Contains"), Data.T("模糊", "Fuzzy"), Data.T("正则", "Regex") }, clipMode,
                      i =>
                      {
                          clipMode = i;
                          FillClips();
                      }));
        Bar(UI.Btn(Data.T("快捷面板", "Quick panel"), QuickClipboard),
            UI.Btn(Data.Pref.PauseClipboard ? Data.T("恢复记录", "Resume") : Data.T("暂停记录", "Pause"),
                   () =>
                   {
                       Data.Pref.PauseClipboard = !Data.Pref.PauseClipboard;
                       Data.Save();
                       Navigate(4);
                   }),
            UI.Btn(clips.Skip ? Data.T("取消跳过", "Undo skip") : Data.T("跳过下一次", "Skip next copy"), () =>
                                                                                                {
                                                                                                    clips.Skip =
                                                                                                        !clips.Skip;
                                                                                                    Navigate(4);
                                                                                                }));
        clipList = new ListBox { Width = innerWidth,  Height = 330,       Tag = "stretch",
                                 BackColor = UI.Card, ForeColor = UI.Ink, IntegralHeight = false };
        body.Controls.Add(clipList);
        FillClips();
        Action<Action<Clip>> selected = act =>
        {
            var c = clipList.SelectedItem as Clip;
            if (c != null)
                act(c);
        };
        clipList.DoubleClick += (s, e) => selected(c => clips.Copy(c, false));
        Bar(UI.Btn(Data.T("预览", "Preview"), () => selected(c =>
                                                        {
                                                            using (var bitmap = clips.ImageOf(c))
                                                            {
                                                                if (bitmap != null)
                                                                    Pin(bitmap);
                                                                else
                                                                    UI.Prompt(Data.T("预览", "Preview"), c.Title, true);
                                                            }
                                                        })),
            UI.Btn(Data.T("复制", "Copy"), () => selected(c => clips.Copy(c, false))),
            UI.Btn(Data.T("复制纯文本", "Copy plain text"), () => selected(c => clips.Copy(c, true))),
            UI.IconButton("pin",Appearance.Purple,()=>selected(clips.Pin),Data.T("固定或取消固定","Pin or unpin")), UI.Btn(Data.T("删除", "Delete"), () => selected(clips.Delete)));
        Bar(UI.Btn(Data.T("清除未固定记录", "Clear unpinned"),
                   () =>
                   {
                       if (Confirm(Data.T("清除未固定记录？", "Clear unpinned items?")))
                           clips.Clear(false);
                   }),
            UI.Btn(Data.T("清空全部", "Clear all"), () =>
                                               {
                                                   if (Confirm(Data.T("清空所有记录？", "Clear all clipboard history?")))
                                                       clips.Clear(true);
                                               }));
    }
    void FillClips()
    {
        if (clipList == null || clipList.IsDisposed)
            return;
        string id = clipList.SelectedItem==null?null:((Clip)clipList.SelectedItem).Id;
        clipList.BeginUpdate();
        try
        {
            clipList.Items.Clear();
            var rows = clips.Rows().Where(c => Clips.Match(c, clipSearch.Text, clipMode)).ToArray();
            clipList.Items.AddRange(rows);
            if (rows.Length > 0)
                clipList.SelectedIndex = Math.Max(0, Array.FindIndex(rows, c => c.Id == id));
        }
        finally
        {
            clipList.EndUpdate();
        }
    }
    void GalleryPage()
    {
        Bar(UI.Btn(Data.T("打开文件夹", "Open folder"), () => Data.Shell(Gallery.Folder)),
            UI.Btn(Data.T("导入图片", "Import images"), () =>
                                                   {
                                                       using (var d = new OpenFileDialog {
                                                           Multiselect = true,
                                                           Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff"
                                                       }) if (d.ShowDialog() == DialogResult.OK)
                                                       {
                                                           foreach (var f in d.FileNames)
                                                               using (var b = Gallery.Read(f)) Gallery.Store(b);
                                                           Navigate(5);
                                                       }
                                                   }));
        Thumbnails(int.MaxValue);
    }
    void Thumbnails(int max)
    {
        var grid = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                                         MaximumSize = new Size(innerWidth, 0), WrapContents = true };
        body.Controls.Add(grid);
        var paths =
            Directory.GetFiles(Gallery.Folder, "*.png").OrderByDescending(File.GetLastWriteTimeUtc).Take(max).ToList();
        if (paths.Count == 0)
        {
            grid.Controls.Add(UI.Label(Data.T("暂无截图 · F1 截取区域", "No screenshots yet · F1 to capture"), 11, UI.Sub));
            return;
        }
        foreach (string path in paths)
        {
            try
            {
                var card = new FlowLayoutPanel { Width = 212,          Height = 166,
                                                 BackColor = UI.Card,  FlowDirection = FlowDirection.TopDown,
                                                 WrapContents = false, Margin = new Padding(4) };
                var pic = new PictureBox { Width = 203, Height = 92, SizeMode = PictureBoxSizeMode.Zoom,
                                           Cursor = Cursors.Hand };
                using (var img = Image.FromFile(path)) pic.Image = img.GetThumbnailImage(
                    Math.Max(1, (int)Math.Min(203, 203.0 * img.Width / img.Height)),
                    Math.Max(1, (int)Math.Min(92, 92.0 * img.Height / img.Width)), null, IntPtr.Zero);
                pic.Disposed += (s,e)=>{if(pic.Image!=null)pic.Image.Dispose();};
                pic.Click += (s, e) => PreviewShot(path);
                card.Controls.Add(pic);
                card.Controls.Add(UI.Label(File.GetLastWriteTime(path).ToString("g"), 9, UI.Sub));
                card.Controls.Add(UI.Row(UI.IconButton("pen",UI.Blue,
                                                () =>
                                                { using (var b = Gallery.Read(path)) EditShot(b); },
                                                Data.T("标注", "Annotate")),
                                         UI.IconButton("folder",UI.Yellow, () => UI.Reveal(path), Data.T("打开原文件位置", "Reveal original")),
                                         UI.IconButton("trash",UI.Orange,
                                                () =>
                                                {
                                                    if (Confirm(Data.T("删除截图？", "Delete screenshot?")))
                                                    {
                                                        File.Delete(path);
                                                        Navigate(page);
                                                    }
                                                },
                                                Data.T("删除", "Delete"))));
                grid.Controls.Add(card);
            }
            catch (IOException)
            {
            }
            catch (OutOfMemoryException)
            {
            }
        }
    }
    void SettingsChange()
    {
        Data.Save();
        UpdateTray();
    }
    void Preferences()
    {
        var lang = new[] { "system", "zh", "en" };
        var themes = new[] { "system", "light", "dark" };
        Bar(UI.Label(Data.T("界面语言", "Language")),
            UI.Select(new[] { Data.T("跟随系统", "System"), "简体中文", "English" }, Array.IndexOf(lang, Data.Pref.Language),
                      i =>
                      {
                          Data.Pref.Language = lang[i];
                          Data.Save();
                          RebuildShell();
                      }));
        Bar(UI.Label(Data.T("外观", "Theme")),
            UI.Select(new[] { Data.T("跟随系统", "System"), Data.T("浅色", "Light"), Data.T("深色", "Dark") },
                      Array.IndexOf(themes, Data.Pref.Theme),
                      i =>
                      {
                          Data.Pref.Theme = themes[i];
                          Data.Save();
                          RebuildShell();
                      }));
        bool startup;
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) startup =
            key!=null && key.GetValue("Perch")!=null;
        Bar(UI.Check(Data.T("登录 Windows 时自动启动", "Start at Windows sign-in"), startup,
                     on =>
                     {
                         using (var key =
                                    Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                         {
                             if (on)
                                 key.SetValue("Perch", Data.Quote(Application.ExecutablePath));
                             else
                                 key.DeleteValue("Perch", false);
                         }
                     }));
        Section(Data.T("系统监控与托盘", "Monitor and tray"));
        var layouts = new[] { "dual", "hardware", "network", "icon" };
        Bar(UI.Label(Data.T("采样间隔", "Sampling interval")),
            UI.Select(new[] { "1 s", "2 s", "5 s" }, Array.IndexOf(new[] { 1, 2, 5 }, Data.Pref.Interval),
                      i =>
                      {
                          Data.Pref.Interval = new[] { 1, 2, 5 }[i];
                          SettingsChange();
                      }),
            UI.Label(Data.T("任务栏读数", "Taskbar readout")),
            UI.Select(new[] { Data.T("硬件与网络", "Hardware + network"), Data.T("仅硬件", "Hardware"), Data.T("仅网络", "Network"),
                              Data.T("仅图标", "Icon only") },
                      Array.IndexOf(layouts, Data.Pref.Layout),
                      i =>
                      {
                          Data.Pref.Layout = layouts[i];
                          SettingsChange();
                      }));
        Bar(UI.Check(Data.T("悬停时预览面板", "Preview on hover"), Data.Pref.Hover,
                     on =>
                     {
                         Data.Pref.Hover = on;
                         if (!on && !manualPopup)
                             ClosePopup();
                         SettingsChange();
                     }),
            UI.Check(Data.T("显示今日 Token 用量", "Show today's tokens"), Data.Pref.Tokens,
                     on =>
                     {
                         Data.Pref.Tokens = on;
                         SettingsChange();
                         if (on)
                             RequestUsage();
                     }));
        Section(Data.T("截图与快捷键", "Capture and shortcuts"));
        var finish = new[] { "preview", "copy", "pin" };
        Bar(UI.Label(Data.T("截图后", "After capture")),
            UI.Select(new[] { Data.T("打开预览", "Preview"), Data.T("复制", "Copy"), Data.T("贴图", "Pin") },
                      Array.IndexOf(finish, Data.Pref.After),
                      i =>
                      {
                          Data.Pref.After = finish[i];
                          SettingsChange();
                      }));
        for (int i = 0; i < 4; i++)
        {
            int n = i;
            Keys k;
            var title =
                new[] { Data.T("区域截图", "Capture region"), Data.T("剪贴板贴图", "Pin clipboard"),
                        Data.T("隐藏或恢复全部贴图", "Toggle pinned images"), Data.T("剪贴板历史", "Clipboard history") }[i];
            Bar(UI.Label(title),
                UI.Btn(bound.TryGetValue(i, out k) ? new KeysConverter().ConvertToString(k) : "—",
                       () => RecordShortcut(n)),
                UI.Btn(Data.T("恢复默认", "Reset"), () =>
                                               {
                                                   Data.Pref.Keys.Remove(actions[n]);
                                                   Data.Save();
                                                   RegisterKeys();
                                                   Navigate(6);
                                               }));
        }
        Section(Data.T("剪贴板", "Clipboard"));
        Bar(UI.Check(Data.T("选择后自动粘贴", "Paste after choosing"), Data.Pref.AutoPaste,
                     on =>
                     {
                         Data.Pref.AutoPaste = on;
                         SettingsChange();
                     }),
            UI.Label(Data.T("历史上限", "History limit")),
            UI.Select(new[] { "25", "50", "100", "200", "500", "1000" },
                      Array.IndexOf(new[] { 25, 50, 100, 200, 500, 1000 }, Data.Pref.ClipLimit),
                      i =>
                      {
                          Data.Pref.ClipLimit = new[] { 25, 50, 100, 200, 500, 1000 }[i];
                          SettingsChange();
                          clips.Trim();
                      }));
        Bar(UI.Btn(Data.T("忽略来源应用…", "Ignore source apps…"),
                   () =>
                   {
                       var s = UI.Prompt(Data.T("进程名，逗号分隔", "Process names, comma-separated"), Data.Pref.IgnoreApps);
                       if (s != null)
                       {
                           Data.Pref.IgnoreApps = s;
                           SettingsChange();
                       }
                   }),
            UI.Btn(Data.T("忽略剪贴板格式…", "Ignore formats…"),
                   () =>
                   {
                       var s =
                           UI.Prompt(Data.T("格式名，逗号分隔", "Format names, comma-separated"), Data.Pref.IgnoreFormats);
                       if (s != null)
                       {
                           Data.Pref.IgnoreFormats = s;
                           SettingsChange();
                       }
                   }));
        Section(Data.T("本地数据", "Local data"));
        Bar(UI.Btn(Data.T("打开数据目录", "Open data folder"), () => Data.Shell(Data.Root)),
            UI.Label(Data.AppName+" 2.15 · Windows"));
    }
    void RebuildShell()
    {
        BeginInvoke((Action)(() =>
                             {
                                 foreach (Control c in Controls.Cast<Control>().ToArray())
                                 {
                                     Controls.Remove(c);
                                     c.Dispose();
                                 }
                                 UI.Theme(this);
                                 BuildShell();
                                 Navigate(6);
                                 UpdateTray();
                             }));
    }
    void RecordShortcut(int i)
    {
        using (var dlg = new Form { Text = Data.T("按下新的快捷键，Esc 取消", "Press shortcut · Esc cancels"),
                                    ClientSize = new Size(340, 70), KeyPreview = true })
        {
            UI.Theme(dlg);
            dlg.Controls.Add(
                UI.Label(Data.T("使用功能键或带 Ctrl、Alt、Shift 的组合", "Use a function key or a modifier"), 11));
            dlg.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Escape)
                {
                    dlg.Close();
                    return;
                }
                if (e.KeyCode == Keys.ControlKey || e.KeyCode == Keys.Menu || e.KeyCode == Keys.ShiftKey)
                    return;
                if (e.Modifiers == Keys.None && (e.KeyCode < Keys.F1 || e.KeyCode > Keys.F24))
                    return;
                var k = e.KeyData;
                int old;
                bool had = Data.Pref.Keys.TryGetValue(actions[i], out old);
                Data.Pref.Keys[actions[i]] = (int)k;
                RegisterKeys();
                Keys got;
                if (!bound.TryGetValue(i, out got) || got != k)
                {
                    if (had)
                        Data.Pref.Keys[actions[i]] = old;
                    else
                        Data.Pref.Keys.Remove(actions[i]);
                    RegisterKeys();
                    Report(Data.T("该快捷键已被占用", "Shortcut already taken"));
                }
                else
                    Data.Save();
                dlg.Close();
            };
            dlg.ShowDialog(this);
        }
        Navigate(6);
    }
}
}
