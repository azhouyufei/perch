using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Drawing;
using System.Reflection;
using System.Diagnostics;
using System.Runtime.InteropServices;

[assembly:AssemblyTitle("Perch")]
[assembly:AssemblyProduct("Perch for Windows")]
[assembly:AssemblyVersion("2.15.0.0")]
[assembly:AssemblyFileVersion("2.15.0.20")]
namespace DeskToys
{
public sealed class Settings
{
    public string RegisteredExecutable;
    public string Language = "system", Theme = "dark", Layout = "dual", Tool = "All", After = "preview";
    public bool Hover = true, Tokens = false, AutoPaste = false, PauseClipboard = false;
    public int Interval = 2, ClipLimit = 200, CustomMinutes = 45;
    public string IgnoreApps = "", IgnoreFormats = "";
    public Dictionary<string, int> Keys = new Dictionary<string, int>();
}
public class Todo
{
    public string Id = Guid.NewGuid().ToString("N"), Title = "", Detail = "", Note = "";
    public DateTime? Due, Remind;
    public bool Done, Notified;
}
public class Note
{
    public string Id = Guid.NewGuid().ToString("N"), Title = "";
    public bool Pinned = true;
    public int X = int.MinValue, Y, Width = 320, Height = 255;
}
public class TaskBook
{
    public List<Todo> Tasks = new List<Todo>();
    public List<Note> Notes = new List<Note>();
}
internal static class Data
{
    internal static string Root =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "perch");
    internal static void MigrateStorage(string destination)
    {
        string legacy = Path.Combine(Path.GetDirectoryName(destination), "DeskToys");
        if (Directory.Exists(destination) || !Directory.Exists(legacy)) return;
        try { Directory.Move(legacy, destination); }
        catch (IOException)
        {
            if (!Directory.Exists(destination) || Directory.Exists(legacy)) throw;
        }
    }
    internal static void LoadUserData()
    {
        MigrateStorage(Root);
        Load();
    }
    internal static Settings Pref;
    internal static TaskBook Book;
    internal static JavaScriptSerializer Json()
    {
        return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 128 };
    }
    internal static T Read<T>(string name)
        where T : class, new()
    {
        var path = Path.Combine(Root, name);
        if (!File.Exists(path))
            return new T();
        return Json().Deserialize<T>(File.ReadAllText(path)) ?? new T();
    }
    internal static void Write(string name, object value)
    {
        Directory.CreateDirectory(Root);
        var path = Path.Combine(Root, name);
        var tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(tmp, Json().Serialize(value), new UTF8Encoding(false));
            if (File.Exists(path))
                File.Replace(tmp, path, null);
            else
                File.Move(tmp, path);
        }
        finally
        {
            if (File.Exists(tmp))
                File.Delete(tmp);
        }
    }
    internal static void Load()
    {
        Pref = Read<Settings>("settings.json");
        Book = Read<TaskBook>("tasks.json");
        foreach (var t in Book.Tasks)
        {
            if(t.Due.HasValue)t.Due=t.Due.Value.ToLocalTime();
            if(t.Remind.HasValue)t.Remind=t.Remind.Value.ToLocalTime();
        }
    }
    internal static void Save()
    {
        Write("settings.json", Pref);
    }
    internal static void SaveTasks()
    {
        Write("tasks.json", Book);
    }
    internal static bool Chinese
    {
        get {
            var language = Pref == null ? "system" : Pref.Language;
            return language == "zh" ||
                   (language == "system" && CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh");
        }
    }
    internal const string AppName = "Perch";
    internal static string T(string zh, string en)
    {
        return Chinese ? zh : en;
    }
    internal static string Size(double value)
    {
        if (double.IsNaN(value))
            return "—";
        string[] u = { "B", "KB", "MB", "GB", "TB" };
        int n = 0;
        while (value >= 1000 && n < u.Length - 1)
        {
            value /= 1000;
            n++;
        }
        return value.ToString(n == 0 ? "0" : "0.#") + " " + u[n];
    }
    internal static string Count(long n)
    {
        return n >= 1000000000 ? (n / 1e9).ToString("0.##") + "B"
               : n >= 1000000  ? (n / 1e6).ToString("0.##") + "M"
               : n >= 1000     ? (n / 1000d).ToString("0.#") + "K"
                               : n.ToString();
    }
    internal static void Shell(string file, string args = "")
    {
        Process.Start(new ProcessStartInfo(file, args) { UseShellExecute = true });
    }
    internal static string Quote(string s)
    {
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }
    internal static void Error(Exception ex)
    {
        MessageBox.Show(ex.GetBaseException().Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
internal static class UI
{
    internal static bool Light
    {
        get {
            if (Data.Pref.Theme != "system")
                return Data.Pref.Theme == "light";
            return Convert.ToInt32(Microsoft.Win32.Registry.GetValue(
                       @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                       "AppsUseLightTheme", 1)) != 0;
        }
    }
    internal static Color Bg { get { return Light ? Color.FromArgb(242, 243, 245) : Color.FromArgb(14, 15, 17); } }
    internal static Color Card { get { return Light ? Color.White : Color.FromArgb(30, 31, 34); } }
    internal static Color Raised { get { return Light ? Color.FromArgb(227, 230, 234) : Color.FromArgb(48, 50, 55); } }
    internal static Color Ink { get { return Light ? Color.FromArgb(30, 32, 35) : Color.WhiteSmoke; } }
    internal static Color Sub { get { return Light ? Color.DimGray : Color.Silver; } }
    internal static readonly Color Blue = Color.FromArgb(34, 163, 246), Yellow = Color.FromArgb(252, 206, 67),
                                   Orange = Color.Coral, Green = Color.MediumSeaGreen;
    private static ToolTip tips;
    internal static ToolTip Tips { get { return tips ?? (tips=new ToolTip { ShowAlways=true,InitialDelay=280,ReshowDelay=90,AutoPopDelay=7000 }); } }
    internal static void Theme(Form f)
    {
        f.Font = SystemFonts.MessageBoxFont;
        f.BackColor = Bg;
        f.ForeColor = Ink;
        f.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        f.StartPosition = FormStartPosition.CenterScreen;
    }
    internal static Label Label(string text, int size = 10, Color? color = null)
    {
        return new Label { Text = text, ForeColor = color ?? Ink, AutoSize = true, Font = new Font("Segoe UI", size),
                           Margin = new Padding(5, 8, 5, 5) };
    }
    internal static Button Btn(string s, Action action, string tip = null)
    {
        var b = new RoundedButton { Text = s,
                             AutoSize = true,
                             AutoSizeMode = AutoSizeMode.GrowAndShrink,
                             FlatStyle = FlatStyle.Flat,
                             BackColor = Raised,
                             ForeColor = Ink,
                             Padding = new Padding(7, 3, 7, 3),
                             Margin = new Padding(3),
                             UseVisualStyleBackColor = false };
        b.FlatAppearance.BorderSize = 0;
        b.Cursor=Cursors.Hand;b.FlatAppearance.MouseOverBackColor=Light?Color.FromArgb(215,225,234):Color.FromArgb(55,61,70);

        b.Click += (o, e) =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                Data.Error(ex);
            }
        };
        if (tip != null)
            Tips.SetToolTip(b, tip);
        return b;
    }
    internal static Button IconButton(string symbol,Color color,Action action,string help){
        var b=Btn("",action,help);
        b.AutoSize=false;b.Size=new Size(Appearance.Px(b,36),Appearance.Px(b,34));b.Padding=Padding.Empty;
        b.AccessibleName=help;Appearance.ButtonIcon(b,symbol,color,18);return b;
    }
    internal static FlowLayoutPanel Row(params Control[] controls)
    {
        var p = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = true,
                                      Margin = new Padding(2) };
        p.Controls.AddRange(controls);
        return p;
    }
    internal static Button Select(string[] labels,int index,Action<int> change){
        int selected=Math.Max(0,Math.Min(index,labels.Length-1));
        Button button=null;
        button=Btn(labels[selected]+"  ▾",()=>{
            var menu=new ContextMenuStrip{BackColor=Card,ForeColor=Ink,ShowImageMargin=false,ShowCheckMargin=true};
            for(int i=0;i<labels.Length;i++){int item=i;
                var entry=new ToolStripMenuItem(labels[i]){Checked=i==selected,ForeColor=Ink,BackColor=Card};
                entry.Click+=delegate{if(item==selected)return;selected=item;button.Text=labels[item]+"  ▾";change(item);};menu.Items.Add(entry);
            }
            Appearance.RetireMenu(menu);menu.Show(button,0,button.Height);
        });
        return button;
    }
    internal static CheckBox Check(string s, bool on, Action<bool> change)
    {
        var c =
            new CheckBox { Text = s, Checked = on, AutoSize = true, ForeColor = Ink, Margin = new Padding(6, 9, 8, 4) };
        c.CheckedChanged += (o, e) => change(c.Checked);
        return c;
    }
    internal static void Clear(Control c)
    {
        var old = c.Controls.Cast<Control>().ToArray();
        c.Controls.Clear();
        foreach (var child in old)
            child.Dispose();
    }
    internal static string Prompt(string title, string initial = "", bool multiline = false)
    {
        using (var f = new Form { Text = title, ClientSize = new Size(420, multiline ? 230 : 115),
                                  FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false,
                                  MinimizeBox = false, TopMost = true })
        {
            Theme(f);
            var t = new TextBox { Text = initial, Multiline = multiline, Left = 12,
                                  Top = 14,       Width = 396,           Height = multiline ? 150 : 28 };
            var ok = Btn(Data.T("确定", "OK"), () => f.DialogResult = DialogResult.OK);
            ok.Location = new Point(328, f.ClientSize.Height - 42);
            f.Controls.AddRange(new Control[] { t, ok });
            f.AcceptButton = ok;
            f.Shown += (s, e) =>
            {
                t.Focus();
                t.SelectAll();
            };
            return f.ShowDialog() == DialogResult.OK ? t.Text : null;
        }
    }
    internal static void Reveal(string file)
    {
        Data.Shell("explorer.exe", "/select," + Data.Quote(file));
    }
}
internal static class Native
{
    [DllImport("user32.dll")]
    internal static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint key);
    [DllImport("user32.dll")]
    internal static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")]
    internal static extern bool AddClipboardFormatListener(IntPtr h);
    [DllImport("user32.dll")]
    internal static extern bool RemoveClipboardFormatListener(IntPtr h);
    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]
    internal static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    internal static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")]
    internal static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")]
    internal static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    internal static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    internal static void Drag(Form f)
    {
        ReleaseCapture();
        SendMessage(f.Handle, 0xA1, (IntPtr)2, IntPtr.Zero);
    }
    [DllImport("user32.dll")]
    internal static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    internal static extern bool SetProcessDPIAware();
}
}
