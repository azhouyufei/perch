using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;
namespace DeskToys
{
static class Program
{
    private static bool OlderInstanceRunning()
    {
        using(var self=Process.GetCurrentProcess()){
            var current = self.MainModule.FileVersionInfo;
            var currentVersion = new Version(current.FileMajorPart, current.FileMinorPart, current.FileBuildPart, current.FilePrivatePart);
            foreach(var other in Process.GetProcessesByName(self.ProcessName).Concat(Process.GetProcessesByName("DeskToys"))){
                using(other){
                    try {
                        if(other.Id==self.Id || other.SessionId!=self.SessionId)continue;
                        var v=other.MainModule.FileVersionInfo;
                        if(v.ProductName=="DeskToys for Windows" || (v.ProductName=="Perch for Windows" && new Version(v.FileMajorPart,v.FileMinorPart,v.FileBuildPart,v.FilePrivatePart)<currentVersion))return true;
                    }catch(System.ComponentModel.Win32Exception){}catch(InvalidOperationException){}
                }
            }
        }
        return false;
    }
    [STAThread]
    static void Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && (args[0] == "--claude-statusline" || args[0] == "--capture-claude-quota"))
            {
                var input = Console.In.ReadToEnd();
                try
                {
                    Data.LoadUserData();
                    var text = Usage.StatusLine(input);
                    Console.Write(args[0] == "--capture-claude-quota" ? input : text);
                }
                catch
                {
                    Console.Write(args[0] == "--capture-claude-quota" ? input : "Claude Code");
                }
                return;
            }
            try
            {
                Native.SetProcessDpiAwarenessContext((IntPtr)(-4));
            }
            catch (EntryPointNotFoundException)
            {
                Native.SetProcessDPIAware();
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 3 && args[0] == "--remind")
            {
                Data.LoadUserData();
                Tasks.Deliver(args[1], args[2]);
                return;
            }
            bool owner;
            using (var mutex = new Mutex(true, @"Local\DeskToys.Workspace", out owner)) using (
                var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\DeskToys.Show"))
            {
                if (!owner)
                {
                    if (OlderInstanceRunning()){
                        MessageBox.Show(Data.T("旧版桌面工具正在运行。请先从系统托盘退出旧版，再打开 Perch。","An older version of the app is running. Quit it from the system tray, then open Perch."),Data.AppName+" 2.15");
                        return;
                    }
                    reopen.Set();
                    return;
                }
                Data.LoadUserData();
                Application.ThreadException += (s, e) => Data.Error(e.Exception);
                try { Workspace.RefreshRegisteredPaths(); }
                catch (UnauthorizedAccessException ex) { Data.Error(ex); }
                catch (System.Security.SecurityException ex) { Data.Error(ex); }
                catch (IOException ex) { Data.Error(ex); }
                using (var window = new Workspace())
                {
                    var handle = window.Handle;
                    var wait = ThreadPool.RegisterWaitForSingleObject(reopen,
                                                                      (a, b) =>
                                                                      {
                                                                          if (!window.IsDisposed)
                                                                              window.BeginInvoke(
                                                                                  (Action)(() => window.Open(0)));
                                                                      },
                                                                      null, -1, false);
                    try
                    {
                        Application.Run(window);
                    }
                    finally
                    {
                        wait.Unregister(null);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Data.Error(ex);
        }
    }
}
sealed partial class Workspace : Form
{
    readonly Timer clock = new Timer { Interval = 1000 }, hover = new Timer { Interval = 130 },
                   retry = new Timer { Interval = 90 };
    readonly Sampler sampler = new Sampler();
    readonly List<Sample> history = new List<Sample>();
    Sample latest = new Sample();
    bool sampling, scanning, exiting, paused, preparingCapture, released;
    int page, clipRetries;
    DateTime nextSample, nextScan;
    string scanError = "";
    List<UsageRow> usage = new List<UsageRow>();
    Dictionary<string, FileUsage> files = new Dictionary<string, FileUsage>();
    readonly List<NotifyIcon> icons = new List<NotifyIcon>();
    readonly List<Icon> dynamicIcons = new List<Icon>();
    Clips clips;
    readonly List<ImagePin> pins = new List<ImagePin>();
    readonly Dictionary<string, NoteWindow> notes = new Dictionary<string, NoteWindow>();
    readonly Dictionary<int, Keys> bound = new Dictionary<int, Keys>();
    static readonly string[] actions = { "capture", "paste", "toggle", "clipboard" };
    static readonly Keys[] defaults = { Keys.F1, Keys.F3, Keys.Shift | Keys.F3, Keys.Control | Keys.Shift | Keys.C };
    readonly Stopwatch awakeWatch = new Stopwatch();
    TimeSpan? awakeDuration;
    bool awake;
    Form popup;
    Point hoverPoint;
    int hoverTab = -1, popupTab = -1;
    DateTime entered, lastInside;
    bool fixedPopup, manualPopup;
    ClipPicker chooser;
    CaptureCanvas capture;
    FlowLayoutPanel sidebar, body;
    Label heading;
    Panel content;
    public Workspace()
    {
        UI.Theme(this);
        Text = Data.AppName+" 2.15";
        MinimumSize = new Size(800, 580);
        Size = new Size(1030, 764);
        AutoScaleMode = AutoScaleMode.Dpi;
        clips = new Clips();
        BuildShell();
        BuildTray();
        RegisterKeys();
        Native.AddClipboardFormatListener(Handle);
        Tasks.Changed += TasksChanged;
        clips.Changed += ClipsChanged;
        clock.Tick += (s, e) => Tick();
        hover.Tick += (s, e) => HoverTick();
        retry.Tick += (s, e) =>
        {
            try
            {
                if (clips.Record() || ++clipRetries > 5)
                    retry.Stop();
            }
            catch (Exception ex)
            {
                retry.Stop();
                Report(ex.Message);
            }
        };
        Shown += (s, e) =>
        {
            ShowNotes();
            Navigate(0);
            Tick();
            clock.Start();
        };
        FormClosing += (s, e) =>
        {
            if (!exiting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
            }
        };
    }
    internal void Open(int target)
    {
        ClosePopup();
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        Navigate(target);
    }
    void Report(string message)
    {
        var entry = icons.FirstOrDefault(i => i.Visible);
        if (entry != null)
        {
            entry.BalloonTipTitle = Data.AppName;
            entry.BalloonTipText = message;
            entry.ShowBalloonTip(3000);
        }
    }
    void TasksChanged()
    {
        ShowNotes();
        if (Visible && page == 3)
            BeginInvoke((Action)(() =>
                                 {
                                     if (page == 3)
                                         Navigate(3);
                                 }));
    }
    void ShowNotes()
    {
        var active =
            Data.Book.Notes.Where(n => n.Pinned && Data.Book.Tasks.Any(t => !t.Done && t.Note == n.Id)).ToList();
        foreach (var key in notes.Keys.ToList())
            if (!active.Any(n => n.Id == key))
            {
                var old = notes[key];
                notes.Remove(key);
                old.Peel();
            }
        foreach (var n in active)
        {
            NoteWindow window;
            if (notes.TryGetValue(n.Id, out window)&&!window.IsDisposed){
                window.RefreshRows();
                if(!window.Visible)window.Show();
                if(window.WindowState==FormWindowState.Minimized)window.WindowState=FormWindowState.Normal;
            }
            else
            {
                window = new NoteWindow(n);
                notes[n.Id] = window;
                window.FormClosed+=delegate {NoteWindow current;if(notes.TryGetValue(n.Id,out current)&&current==window)notes.Remove(n.Id);};
                window.Show();window.BringToFront();
            }
        }
    }
    void ClipsChanged()
    {
        if (Visible && page == 4)
            FillClips();
    }
    void RegisterKeys()
    {
        for (int i = 0; i < actions.Length; i++)
        {
            Native.UnregisterHotKey(Handle, 400 + i);
            int pref;
            var preferred = Data.Pref.Keys.TryGetValue(actions[i], out pref) ? (Keys)pref : defaults[i];
            bound.Remove(i);
            foreach (Keys k in new[] { preferred, defaults[i],
                                       Keys.Control | Keys.Alt |
                                           (i == 0   ? Keys.D4
                                            : i == 1 ? Keys.V
                                            : i == 2 ? Keys.B
                                                     : Keys.C),
                                       Keys.Control | Keys.Alt | Keys.Shift | (Keys)((int)Keys.F5 + i) }
                         .Distinct())
            {
                uint mods = ((k & Keys.Alt) != 0 ? 1u : 0) | ((k & Keys.Control) != 0 ? 2u : 0) |
                            ((k & Keys.Shift) != 0 ? 4u : 0) | 0x4000;
                if (Native.RegisterHotKey(Handle, 400 + i, mods, (uint)(k & Keys.KeyCode)))
                {
                    bound[i] = k;
                    break;
                }
            }
        }
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x031D && clips != null)
        {
            clipRetries = 0;
            retry.Start();
        }
        if (m.Msg == 0x0312)
        {
            switch (m.WParam.ToInt32() - 400)
            {
            case 0:
                if (capture != null)
                    capture.Close();
                else
                    CaptureScreen("region");
                break;
            case 1:
                if (capture != null)
                    capture.PinSelection();
                else
                    PinClipboard();
                break;
            case 2:
                bool show = pins.All(x => !x.Visible);
                foreach (var p in pins)
                    p.Visible = show;
                break;
            case 3:
                QuickClipboard();
                break;
            }
            return;
        }
        base.WndProc(ref m);
    }
    void QuickClipboard()
    {
        if (capture != null)
            return;
        var target = Native.GetForegroundWindow();
        ClosePopup();
        if (chooser != null && !chooser.IsDisposed)
        {
            chooser.Activate();
            return;
        }
        chooser = new ClipPicker(clips, target);
        chooser.Show();
        chooser.Activate();
    }
    void PinClipboard()
    {
        var b = Clipboard.GetImage();
        if (b != null)
        {
            using (b) using (var image = new Bitmap(b)) Pin(image);
            return;
        }
        var text = Clipboard.GetText();
        if (text == "")
        {
            Report(Data.T("剪贴板没有图像或文本", "No image or text on clipboard"));
            return;
        }
        using (var f = new Font("Segoe UI", 13))
        {
            var size = TextRenderer.MeasureText(text, f, new Size(650, 1200), TextFormatFlags.WordBreak);
            using (var canvas = new Bitmap(Math.Max(65, size.Width + 22), Math.Max(36, size.Height + 20))) using (
                var g = Graphics.FromImage(canvas))
            {
                g.Clear(Color.LemonChiffon);
                g.DrawString(text, f, Brushes.Black, new RectangleF(9, 9, canvas.Width - 18, canvas.Height - 18));
                Pin(canvas);
            }
        }
    }
    void Pin(Bitmap b)
    {
        var p = new ImagePin(b);
        pins.Add(p);
        p.FormClosed += (s, e) => pins.Remove(p);
        p.Show();
    }
    void CaptureScreen(string mode)
    {
        if (capture != null || preparingCapture)
            return;
        preparingCapture = true;
        readout.Hide();
        ClosePopup();
        bool restore = Visible;
        if (restore)
            Hide();
        var t = new Timer { Interval = 160 };
        t.Tick += (s, e) =>
        {
            t.Stop();
            t.Dispose();
            preparingCapture = false;
            try
            {
                var canvas = new CaptureCanvas(mode, null, (bmp, action) => Output(bmp, action));
                capture = canvas;
                canvas.EditSelection = EditShot;
                canvas.FormClosed += (o, ev) =>
                {
                    if (capture == canvas)
                        capture = null;
                    if (restore && !Visible && capture == null)
                        Show();
                };
                canvas.Show();
            }
            catch (Exception ex)
            {
                if (restore)
                    Show();
                Data.Error(ex);
            }
        };
        t.Start();
    }
    void EditShot(Bitmap b, List<Mark> existing = null)
    {
        ClosePopup();
        var ed = new CaptureCanvas("editor", new Bitmap(b), (img, a) => Output(img, a), existing);
        capture = ed;
        ed.FormClosed += (s, e) =>
        {
            if (capture == ed)
                capture = null;
        };
        ed.Show();
        ed.Activate();
    }
    void Output(Bitmap image, string action)
    {
        if (action == "edit")
        {
            EditShot(image);
            return;
        }
        string path = Gallery.Store(image);
        if (action == "preferred")
            action = Data.Pref.After;
        if (action == "pin")
            Pin(image);
        else if (action == "copy")
            Clipboard.SetImage(image);
        else if (action == "save")
            ExportPng(path);
        else if (action == "preview")
            PreviewShot(path);
        if (Visible && page == 5)
            BeginInvoke((Action)(() => Navigate(5)));
    }
    void ExportPng(string path)
    {
        using (var d =
                   new SaveFileDialog {
                       Filter = "PNG|*.png", FileName = Path.GetFileName(path)
                   }) if (d.ShowDialog() == DialogResult.OK &&
                          !string.Equals(path, d.FileName, StringComparison.OrdinalIgnoreCase))
            File.Copy(path, d.FileName, true);
    }
    void PreviewShot(string path)
    {
        using (var img = Gallery.Read(path))
        {
            var f = new Form { Text = Path.GetFileName(path), Size = new Size(740, 530) };
            UI.Theme(f);
            var pic =
                new PictureBox { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Image = new Bitmap(img) };
            var bar =
                UI.Row(UI.Btn(Data.T("标注", "Annotate"), () =>
                                                     { using (var b = Gallery.Read(path)) EditShot(b); }),
                       UI.Btn(Data.T("复制", "Copy"), () => Clipboard.SetImage(pic.Image)),
                       UI.Btn(Data.T("贴图", "Pin"), () => Pin((Bitmap)pic.Image)), UI.Btn("PNG ↓", () => ExportPng(path)),
                       UI.Btn("OCR", () => Recognize(path)), UI.Btn(Data.T("定位", "Reveal"), () => UI.Reveal(path)));
            bar.Dock = DockStyle.Bottom;
            f.Controls.Add(pic);
            f.Controls.Add(bar);
            f.FormClosed += (s, e) => pic.Image.Dispose();
            f.Show();
            f.Activate();
        }
    }
    async void Recognize(string path)
    {
        try
        {
            string text = await Gallery.Ocr(path);
            if (text == "")
            {
                Report(Data.T("未识别到文字", "No text recognized"));
                return;
            }
            var result = UI.Prompt("OCR", text, true);
            if (result != null)
                Clipboard.SetText(result);
        }
        catch (Exception ex)
        {
            Data.Error(ex);
        }
    }
    void StartAwake(TimeSpan? duration)
    {
        if (Native.SetThreadExecutionState(0x80000001) == 0)
        {
            Report(Data.T("系统未能开启保持唤醒", "Could not prevent idle sleep"));
            return;
        }
        awakeDuration = duration;
        awake = true;
        awakeWatch.Restart();
        UpdateTray();
        UpdateAwake();
    }
    void EndAwake()
    {
        Native.SetThreadExecutionState(0x80000000);
        awake = false;
        awakeWatch.Reset();
        UpdateTray();
        UpdateAwake();
    }
    string AwakeText()
    {
        return !awake ? Data.T("未开启", "Off")
               : !awakeDuration.HasValue
                   ? Data.T("直到手动结束", "Until turned off")
                   : TimeSpan
                         .FromSeconds(
                             Math.Max(0, Math.Ceiling((awakeDuration.Value - awakeWatch.Elapsed).TotalSeconds)))
                         .ToString("g");
    }
    void AwakeItems(ToolStripItemCollection items)
    {
        if (awake)
        {
            items.Add(AwakeText()).Enabled = false;
            items.Add(Data.T("立即结束", "End now"), null, (s, e) => EndAwake());
            items.Add(new ToolStripSeparator());
        }
        foreach (int n in new[] { 15, 30, 60, 120 })
            items.Add(n + " " + Data.T("分钟", "min"), null, (s, e) => StartAwake(TimeSpan.FromMinutes(n)));
        items.Add(Data.T("自定义时长…", "Custom duration…"), null,
                  (s, e) =>
                  {
                      var raw = UI.Prompt(Data.T("时长（分钟）", "Duration (minutes)"), Data.Pref.CustomMinutes.ToString());
                      if (raw == null)
                          return;
                      int minutes;
                      if (!int.TryParse(raw, out minutes) || minutes < 1 || minutes > 525600)
                      {
                          Report(Data.T("请输入 1–525600 分钟", "Enter 1–525,600 minutes"));
                          return;
                      }
                      Data.Pref.CustomMinutes = minutes;
                      Data.Save();
                      StartAwake(TimeSpan.FromMinutes(minutes));
                  });
        items.Add(Data.T("直到手动结束", "Until turned off"), null, (s, e) => StartAwake(null));
    }
    void ShowMenu(bool onlyAwake)
    {
        ClosePopup();
        hover.Stop();
        hoverTab = -1;
        var menu = CreateTrayMenu(onlyAwake);
        Appearance.RetireMenu(menu);
        menu.Show(Cursor.Position);
    }
    ContextMenuStrip CreateTrayMenu(bool onlyAwake)
    {
        var m = new ContextMenuStrip();
        if (onlyAwake)
            AwakeItems(m.Items);
        else
        {
            m.Items.Add(Data.T("打开工作台", "Open dashboard"), null, (s, e) => Open(0));
            m.Items.Add(Data.T("新建待办", "New task"), null, (s, e) => Tasks.Edit(null));
            m.Items.Add(Data.T("剪贴板历史", "Clipboard history"), null, (s, e) => QuickClipboard());
            var a = new ToolStripMenuItem(Data.T("保持唤醒", "Keep awake"));
            AwakeItems(a.DropDownItems);
            m.Items.Add(a);
            m.Items.Add(Data.T("设置", "Settings"), null, (s, e) => Open(6));
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add(Data.T("退出 Perch", "Quit Perch"), null,
                        (s, e) =>
                        {
                            exiting = true;
                            Close();
                        });
        }
        return m;
    }
    void BuildTray()
    {
        for (int i = 0; i < 4; i++)
        {
            int tab = i;
            var ni = new NotifyIcon { Text = Data.AppName, Icon = Icon };
            icons.Add(ni);
            dynamicIcons.Add(null);
            ni.MouseClick += (s, e) => TrayClick(tab, e.Button);
            ni.MouseMove += (s, e) => TrayHover(tab);
        }
        readout = new TaskbarReadout(TrayClick, TrayHover);
        UpdateTray();
    }
    TaskbarReadout readout;
    void TrayClick(int tab, MouseButtons button)
    {
        if (button == MouseButtons.Right)
        {
            ShowMenu(false);
            return;
        }
        if (tab == 3)
        {
            ShowMenu(true);
            return;
        }
        if ((ModifierKeys & Keys.Alt) != 0)
        {
            if ((ModifierKeys & Keys.Shift) != 0)
                clips.Skip = !clips.Skip;
            else
            {
                Data.Pref.PauseClipboard = !Data.Pref.PauseClipboard;
                Data.Save();
            }
            return;
        }
        if (popup != null && popupTab == tab)
        {
            if (!manualPopup)
            {
                manualPopup = true;
                return;
            }
            ClosePopup();
        }
        else
            ShowPopup(tab, true);
    }
    void TrayHover(int tab)
    {
        if (!Data.Pref.Hover || tab == 3 || fixedPopup)
            return;
        if (hoverTab != tab)
        {
            entered = DateTime.UtcNow;
            hoverTab = tab;
        }
        hoverPoint = Cursor.Position;
        lastInside = DateTime.UtcNow;
        hover.Start();
    }
    readonly string[] lastIcon = new string[4];
    int trayPixels;
    void SetIcon(int index, string glyph, string tooltip, bool active=false)
    {
        var entry=icons[index];string label=tooltip.Length>63?tooltip.Substring(0,63):tooltip;
        if(entry.Text!=label)entry.Text=label;
        string key=glyph+"/"+trayPixels+"/"+active;
        if(lastIcon[index]==key)return;
        using(var pixels=TrayArtwork.Draw(trayPixels,glyph,active)){
            IntPtr handle=pixels.GetHicon();
            try{
                using(var borrowed=Icon.FromHandle(handle)){
                    var next=(Icon)borrowed.Clone();var old=dynamicIcons[index];entry.Icon=next;dynamicIcons[index]=next;
                    if(old!=null)old.Dispose();lastIcon[index]=key;
                }
            }finally{Native.DestroyIcon(handle);}
        }
    }
    void UpdateTray()
    {
        if(icons.Count<4)return;
        trayPixels=TrayArtwork.PixelSize();
        readout.UpdateValues(latest, Data.Pref.Layout);
        icons[0].Visible=Data.Pref.Layout=="icon";
        icons[2].Visible=Data.Pref.Tokens;icons[3].Visible=true;
        if(icons[0].Visible) SetIcon(0,"cpu",Data.AppName+" CPU "+Plot.Format(latest.Cpu,0));
        if(Data.Pref.Tokens){
            long total=FilteredUsage().Where(x=>x.Day==DateTime.Today.ToString("yyyy-MM-dd")).Sum(x=>x.Value.Total);
            SetIcon(2,TrayArtwork.TokenBadge(total),Data.Pref.Tool+" · "+total.ToString("N0")+" tokens",true);
        }
        SetIcon(3,"awake",Data.T("保持唤醒","Keep awake")+" · "+AwakeText(),awake);
    }
    void HoverTick()
    {
        if (!Data.Pref.Hover)
        {
            hover.Stop();
            return;
        }
        var pos = Cursor.Position;
        var now = DateTime.UtcNow;
        bool atIcon = Math.Abs(pos.X - hoverPoint.X) <= 5 && Math.Abs(pos.Y - hoverPoint.Y) <= 5;
        if (atIcon && hoverTab >= 0)
        {
            lastInside = now;
            if ((now - entered).TotalMilliseconds >= 300 &&
                (popup == null || (!manualPopup && !fixedPopup && popupTab != hoverTab)))
                ShowPopup(hoverTab, false);
        }
        else if (popup != null && popup.Bounds.Contains(pos))
            lastInside = now;
        else if ((now - lastInside).TotalMilliseconds > 460)
        {
            if (!fixedPopup && !manualPopup)
                ClosePopup();
            hoverTab = -1;
            hover.Stop();
        }
    }
    void ClosePopup()
    {
        var f = popup;
        popup = null;
        popupTab = -1;
        fixedPopup = false;
        manualPopup = false;
        if (f != null)
            f.Close();
    }
    FlowLayoutPanel popupBody;
    void ShowPopup(int tab, bool manual)
    {
        bool keep = fixedPopup;
        ClosePopup();
        popupTab = tab;
        fixedPopup = keep;
        manualPopup = manual;
        var f = new Form { FormBorderStyle = FormBorderStyle.None, ShowInTaskbar = false, TopMost = true,
                           Size = new Size(390, 330) };
        UI.Theme(f);
        popup = f;
        var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
                                         WrapContents = false, Padding = new Padding(7), AutoScroll = true };
        f.Controls.Add(flow);
        var tabs = UI.Row();
        for (int i = 0; i < 3; i++)
        {
            int t = i;
            var b = UI.Btn(new[] { Data.T("硬件", "Hardware"), Data.T("网络", "Network"), Data.T("用量", "Usage") }[i],
                           () => ShowPopup(t, true));
            if (i == tab)
                b.ForeColor = UI.Blue;
            tabs.Controls.Add(b);
        }
        tabs.Controls.Add(UI.IconButton("pin",Appearance.Purple,
                                 () =>
                                 {
                                     fixedPopup = !fixedPopup;
                                     manualPopup = fixedPopup;
                                     hover.Start();
                                 },
                                 Data.T("固定或取消固定面板", "Pin or unpin panel")));
        flow.Controls.Add(tabs);
        if (tab == 2)
            flow.Controls.Add(UI.Select(Usage.Tools, Array.IndexOf(Usage.Tools, Data.Pref.Tool),
                                        i =>
                                        {
                                            SetUsageTool(i);
                                            FillPopup();
                                        }));
        popupBody = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, Width = 356,
                                          Height = 182 };
        flow.Controls.Add(popupBody);
        flow.Controls.Add(UI.Row(UI.Btn(Data.T("工作台", "Dashboard"), () => Open(0)),
                                 UI.Btn(Data.T("详情", "Details"), () => Open(tab == 2 ? 2 : 1)),
                                 UI.Btn(Data.T("设置", "Settings"), () => Open(6))));
        var p = Cursor.Position;
        var area = Screen.FromPoint(p).WorkingArea;
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(Math.Max(area.Left, Math.Min(area.Right - f.Width, p.X - 180)),
                               p.Y > area.Top + area.Height / 2 ? Math.Max(area.Top, p.Y - f.Height - 7)
                                                                : Math.Min(area.Bottom - f.Height, p.Y + 12));
        f.Deactivate += (s, e) =>
        {
            if (popup == f && !fixedPopup && manualPopup && !f.ContainsFocus)
                BeginInvoke((Action)(() =>
                                     {
                                         if (popup == f && !fixedPopup && !f.ContainsFocus)
                                             ClosePopup();
                                     }));
        };
        FillPopup();
        if (!manual)
            ShowWindowNoFocus(f);
        else
            f.Show();
        if (tab == 2)
            RequestUsage();
    }

    static void ShowWindowNoFocus(Form f)
    {
        IntPtr prev = Native.GetForegroundWindow();
        f.Show();
        if (prev != IntPtr.Zero)
            Native.SetForegroundWindow(prev);
    }
    void FillPopup()
    {
        if (popup == null || popupBody == null)
            return;
        UI.Clear(popupBody);
        if (popupTab == 2)
        {
            var today = FilteredUsage().Where(x => x.Day == DateTime.Today.ToString("yyyy-MM-dd"));
            var amt = Amount.Sum(today.Select(r => r.Value));
            popupBody.Controls.Add(UI.Label(Data.Count(amt.Total) + " tokens", 23));
            popupBody.Controls.Add(UI.Label(Data.T("输入 / 输出", "Input / output") + "   " + Data.Count(amt.Input) + " / " +
                                            Data.Count(amt.Output)));
            popupBody.Controls.Add(UI.Label(QuotaText(), 9));
        }
        else
        {
            int m = popupTab == 0 ? 0 : 3;
            popupBody.Controls.Add(
                UI.Label(popupTab == 0 ? "CPU " + Plot.Format(latest.Cpu, 0) + "   RAM " + Plot.Format(latest.Memory, 1)
                                       : "↑ " + Plot.Format(latest.Up, 2) + "    ↓ " + Plot.Format(latest.Down, 3),
                         14));
            popupBody.Controls.Add(new Plot { Samples = history, Metric = m, Width = 345, Height = 100 });
        }
    }
    bool desktopActive;
    void RestoreDesktopNotes(){
        if(notes.Count==0){desktopActive=false;return;}
        bool active=NoteWindow.DesktopIsForeground();
        if(active&&!desktopActive)foreach(var noteWindow in notes.Values)noteWindow.ShowOnDesktop();
        desktopActive=active;
    }
    async void Tick()
    {
        if (exiting)
            return;
        readout.PositionReadout(preparingCapture || capture != null);
        RestoreDesktopNotes();
        if (awake && awakeDuration.HasValue && awakeWatch.Elapsed >= awakeDuration)
            EndAwake();
        UpdateAwake();
        if ((Visible && page == 2) || popupTab == 2 || Data.Pref.Tokens)
            RequestUsage();
        if (paused || sampling || DateTime.UtcNow < nextSample)
            return;
        sampling = true;
        nextSample = DateTime.UtcNow.AddSeconds(Data.Pref.Interval);
        bool detail = (Visible && (page == 0 || page == 1)) || popupTab == 0 || popupTab == 1;
        try
        {
            var s = await Task.Run(() => sampler.Read(detail));
            if (IsDisposed || exiting)
                return;
            latest = s;
            history.Add(s);
            history.RemoveAll(x => x.At < s.At.AddMinutes(-10));
            UpdateTray();
            RefreshMonitor();
            FillPopup();
        }
        catch (Exception ex)
        {
            if (!IsDisposed)
                Text = Data.AppName+" · " + ex.GetBaseException().Message;
        }
        finally
        {
            sampling = false;
        }
    }
    IEnumerable<UsageRow> FilteredUsage()
    {
        return usage.Where(x => Data.Pref.Tool == "All" || x.Tool == Data.Pref.Tool);
    }
    void SetUsageTool(int i)
    {
        Data.Pref.Tool = Usage.Tools[i];
        Data.Save();
        UpdateTray();
        if (page == 2 && Visible)
            UsageContent();
    }
    async void RequestUsage(bool force = false)
    {
        if (scanning || (!force && DateTime.UtcNow < nextScan))
            return;
        scanning = true;
        nextScan = DateTime.UtcNow.AddSeconds(30);
        try
        {
            var result = await Task.Run(() =>
                                        {
                                            var f = Usage.Scan();
                                            return Tuple.Create(f, Usage.Rows(f));
                                        });
            if (exiting || IsDisposed)
                return;
            files = result.Item1;
            usage = result.Item2;
            scanError = "";
        }
        catch (Exception ex)
        {
            scanError = ex.GetBaseException().Message;
        }
        finally
        {
            scanning = false;
            if (!exiting && !IsDisposed)
            {
                UpdateTray();
                if (page == 2 && Visible)
                    UsageContent();
                FillPopup();
            }
        }
    }
    string QuotaText()
    {
        var lines = new List<string>();
        if (Data.Pref.Tool == "All" || Data.Pref.Tool == "Codex")
        {
            var f = files.Values.Where(x => x.Tool == "Codex" && Usage.Valid(x.Limits).Any())
                        .OrderByDescending(x => x.Modified)
                        .FirstOrDefault();
            if (f != null)
                lines.AddRange(Usage.Valid(f.Limits).Select(q => "Codex " + Limit(q)));
        }
        if (Data.Pref.Tool == "All" || Data.Pref.Tool == "Claude Code")
        {
            if (!Usage.DirectClaude())
                lines.Add(
                    Data.T("Claude Code · 自定义服务，无可验证额度", "Claude Code · custom provider, no verified quota"));
            else
                try
                {
                    lines.AddRange(Usage.Valid(Data.Read<List<Quota>>("claude-quota.json"))
                                       .Select(q => "Claude Code " + Limit(q)));
                }
                catch (IOException)
                {
                }
        }
        return lines.Count == 0 ? Data.T("暂无有效额度快照", "No valid quota snapshot")
                                : string.Join(Environment.NewLine, lines);
    }
    string Limit(Quota q)
    {
        return q.Minutes / 60.0 + "h · " + (100 - q.Used).ToString("0") + "%  " + Data.T("重置 ", "resets ") +
               DateTimeOffset.FromUnixTimeSeconds(q.Reset).LocalDateTime.ToString("g");
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing && !released)
        {
            released = true;
            exiting = true;
            clock.Dispose();
            hover.Dispose();
            retry.Dispose();
            if (readout != null) readout.Dispose();
            Tasks.Changed -= TasksChanged;
            for (int i = 0; i < 4; i++)
                if (IsHandleCreated)
                    Native.UnregisterHotKey(Handle, 400 + i);
            if (IsHandleCreated)
                Native.RemoveClipboardFormatListener(Handle);
            if (awake)
                Native.SetThreadExecutionState(0x80000000);
            foreach (var i in icons)
                i.Dispose();
            foreach (var i in dynamicIcons)
                if(i!=null)i.Dispose();
            foreach (var p in notes.Values.ToArray())
                p.Dispose();
            foreach (var p in pins.ToArray())
                p.Dispose();
            if(clips!=null)clips.Dispose();
        }
        base.Dispose(disposing);
    }
}
}
