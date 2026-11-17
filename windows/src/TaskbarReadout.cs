using System;
using System.Collections;
using Microsoft.Win32;
using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeskToys
{
    internal sealed class TaskbarReadout : Form
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct WindowRect
        {
            public int Left, Top, Right, Bottom;
            public Rectangle Bounds { get { return Rectangle.FromLTRB(Left, Top, Right, Bottom); } }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string kind, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string kind, string title);
        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr window, out WindowRect rect);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr window);
        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr window, IntPtr order, int x, int y, int width, int height, uint flags);

        private Sample sample = new Sample();
        private string layout = "icon";
        private Font valueFont;
        private int dpi, hardwareWidth, networkWidth, lineHeight;
        private bool busy;
        private IntPtr lastBar;
        private Rectangle lastCandidate;
        private bool inline;
        private DateTime nextProbe;
        private readonly Action<int, MouseButtons> click;
        private readonly Action<int> hover;

        internal TaskbarReadout(Action<int, MouseButtons> click, Action<int> hover)
        {
            this.click = click;
            this.hover = hover;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
            DoubleBuffered = true;
            AccessibleRole = AccessibleRole.StaticText;
            ApplyTaskbarColors();
        }

        private void ApplyTaskbarColors()
        {
            bool light = Equals(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                                                  "SystemUsesLightTheme", 0), 1);
            BackColor = SystemInformation.HighContrast ? SystemColors.Window :
                        light ? Color.FromArgb(241, 243, 245) : Color.FromArgb(34, 36, 40);
            ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText :
                        light ? Color.FromArgb(30, 32, 35) : Color.White;
        }

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == 0x1A || m.Msg == 0x31A) ApplyTaskbarColors(); // settings/theme changed
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                var p = base.CreateParams;
                p.ExStyle |= 0x08000080; // WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                return p;
            }
        }

        internal static string[] Lines(Sample s)
        {
            return new[] { "CPU " + Plot.Format(s.Cpu, 0), "RAM " + Plot.Format(s.Memory, 1),
                           "↑ " + Plot.Format(s.Up, 2), "↓ " + Plot.Format(s.Down, 3) };
        }
        private string[] lines = Lines(new Sample());
        internal void UpdateValues(Sample latest, string mode)
        {
            bool changed = mode != layout;
            if (changed || latest != sample)
            {
                sample = latest;
                layout = mode;
                lines = Lines(latest);
                AccessibleName = layout == "network" ? lines[2] + ", " + lines[3] :
                    layout == "hardware" ? lines[0] + ", " + lines[1] : string.Join(", ", lines);
                Invalidate();
            }
            if (changed) { inline = false; nextProbe = DateTime.MinValue; }
            if (layout == "icon") Hide();
        }

        private void SetScale(int scale)
        {
            if (dpi == scale) return;
            dpi = scale;
            if (valueFont != null) valueFont.Dispose();
            valueFont = new Font("Segoe UI", 12f * dpi / 96, FontStyle.Regular, GraphicsUnit.Pixel);
            hardwareWidth = TextRenderer.MeasureText("RAM 100.0%", valueFont).Width + 4;
            networkWidth = TextRenderer.MeasureText("↓ 1000.0 MB/s", valueFont).Width + 4;
            lineHeight = TextRenderer.MeasureText("Ag", valueFont).Height;
        }
        private static bool IsHorizontal(Rectangle bar) { return bar.Width >= bar.Height; }

        internal static Rectangle Candidate(Rectangle bar, Rectangle tray, Size size)
        {
            if (!IsHorizontal(bar) || size.Height > bar.Height || tray.IsEmpty) return Rectangle.Empty;
            // Handle notification areas on either end (including right-to-left taskbars).
            int x = tray.Left - bar.Left > bar.Right - tray.Right ? tray.Left - size.Width : tray.Right;
            var spot = new Rectangle(x, bar.Top + (bar.Height - size.Height) / 2, size.Width, size.Height);
            return bar.Contains(spot) ? spot : Rectangle.Empty;
        }
        internal static Rectangle Beside(Rectangle screen, Rectangle bar, Rectangle tray, Size size)
        {
            int x, y;
            if (IsHorizontal(bar))
            {
                x = tray.IsEmpty || tray.Left - bar.Left >= bar.Right - tray.Right ? bar.Right - size.Width : bar.Left;
                y = bar.Top - screen.Top < screen.Bottom - bar.Bottom ? bar.Bottom : bar.Top - size.Height;
            }
            else
            {
                x = bar.Left - screen.Left < screen.Right - bar.Right ? bar.Right : bar.Left - size.Width;
                y = tray.IsEmpty || tray.Top - bar.Top >= bar.Bottom - tray.Bottom ? bar.Bottom - size.Height : bar.Top;
            }
            return new Rectangle(Math.Max(screen.Left, Math.Min(screen.Right - size.Width, x)),
                                 Math.Max(screen.Top, Math.Min(screen.Bottom - size.Height, y)), size.Width, size.Height);
        }

        internal void PositionReadout(bool capturing)
        {
            if (layout == "icon" || capturing) { if (Visible) Hide(); return; }
            IntPtr bar = FindWindow("Shell_TrayWnd", null);
            WindowRect bounds;
            if (bar == IntPtr.Zero || !IsWindowVisible(bar) || !GetWindowRect(bar, out bounds)) { Hide(); return; }
            var screen = Screen.FromHandle(bar).Bounds;
            var rect = Rectangle.Intersect(screen, bounds.Bounds);
            var front = Native.GetForegroundWindow();
            WindowRect frontRect;
            bool fullscreen = front != IntPtr.Zero && front != bar && !NoteWindow.DesktopIsForeground() &&
                GetWindowRect(front, out frontRect) && frontRect.Bounds.Contains(screen);
            // Auto-hide leaves at most a few pixels on screen.
            if (rect.Width < 8 || rect.Height < 8 || fullscreen) { Hide(); return; }
            int scale = 96;
            try { scale = (int)GetDpiForWindow(bar); } catch (EntryPointNotFoundException) { }
            SetScale(scale > 0 ? scale : 96);
            var size = new Size((layout == "network" ? 0 : hardwareWidth) + (layout == "hardware" ? 0 : networkWidth),
                                lineHeight * 2);
            WindowRect notifyRect;
            var notify = FindWindowEx(bar, IntPtr.Zero, "TrayNotifyWnd", null);
            var tray = notify != IntPtr.Zero && GetWindowRect(notify, out notifyRect) ? notifyRect.Bounds : Rectangle.Empty;
            var spot = Candidate(rect, tray, size);
            if (bar != lastBar || spot != lastCandidate)
            {
                lastBar = bar;
                lastCandidate = spot;
                inline = false;
                nextProbe = DateTime.MinValue;
            }
            if (!spot.IsEmpty && !busy && DateTime.UtcNow >= nextProbe) Probe(bar, spot, tray);
            var target = inline && !spot.IsEmpty ? spot : Beside(screen, rect, tray, size);
            if (Bounds != target) Bounds = target;
            if (!Visible) Show();
            if (front == bar) SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x13);
        }

        private async void Probe(IntPtr bar, Rectangle candidate, Rectangle tray)
        {
            busy = true;
            try
            {
                bool free = await Task.Run(() => TaskbarSpace.IsFree(bar, candidate, tray));
                if (!IsDisposed && bar == lastBar && candidate == lastCandidate) inline = free;
            }
            finally { busy = false; nextProbe = DateTime.UtcNow.AddSeconds(3); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (valueFont == null) return;
            int x = 0;
            if (layout != "network") { DrawColumn(e.Graphics, 0, x, hardwareWidth); x += hardwareWidth; }
            if (layout != "hardware") DrawColumn(e.Graphics, 2, x, networkWidth);
        }
        private void DrawColumn(Graphics g, int start, int x, int width)
        {
            for (int i = 0; i < 2; i++)
                TextRenderer.DrawText(g, lines[start + i], valueFont, new Rectangle(x + 3, i * lineHeight, width - 3, lineHeight),
                    ForeColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        }
        private int TabAt(int x) { return layout == "network" || (layout == "dual" && x >= hardwareWidth) ? 1 : 0; }
        protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); hover(TabAt(e.X)); }
        protected override void OnMouseClick(MouseEventArgs e) { base.OnMouseClick(e); click(TabAt(e.X), e.Button); }
        protected override void Dispose(bool disposing)
        {
            if (disposing && valueFont != null) valueFont.Dispose();
            base.Dispose(disposing);
        }
    }

    // Query Explorer's accessibility tree, independently of the overlay's own z-order.
    // Load the Windows framework provider on demand so an unavailable provider can use edge placement.
    internal static class TaskbarSpace
    {
        private static readonly Lazy<Assembly> Client = new Lazy<Assembly>(() => Assembly.Load(
            "UIAutomationClient, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"));
        internal static bool IsFree(IntPtr bar, Rectangle candidate, Rectangle tray)
        {
            try
            {
                var client = Client.Value;
                var element = client.GetType("System.Windows.Automation.AutomationElement", true);
                dynamic root = element.GetMethod("FromHandle").Invoke(null, new object[] { bar });
                var requestType = client.GetType("System.Windows.Automation.CacheRequest", true);
                dynamic request = Activator.CreateInstance(requestType);
                foreach (string field in new[] { "BoundingRectangleProperty", "ControlTypeProperty", "IsOffscreenProperty" })
                    request.Add((dynamic)element.GetField(field).GetValue(null));
                var find = element.GetMethod("FindAll");
                var scope = Enum.Parse(find.GetParameters()[0].ParameterType, "Descendants");
                object condition = client.GetType("System.Windows.Automation.Condition").GetField("TrueCondition").GetValue(null);
                using ((IDisposable)request.Activate())
                {
                    var descendants = (IEnumerable)find.Invoke(root, new object[] { scope, condition });
                    bool sawTaskButton = false;
                    foreach (dynamic item in descendants)
                    {
                        dynamic cached = item.Cached;
                        if ((bool)cached.IsOffscreen) continue;
                        string kind = cached.ControlType.ProgrammaticName;
                        if (kind == "ControlType.Pane" || kind == "ControlType.ToolBar" || kind == "ControlType.List" ||
                            kind == "ControlType.Group" || kind == "ControlType.Window") continue;
                        dynamic r = cached.BoundingRectangle;
                        if ((bool)r.IsEmpty) continue;
                        var bounds = Rectangle.FromLTRB((int)Math.Floor((double)r.Left), (int)Math.Floor((double)r.Top),
                                                        (int)Math.Ceiling((double)r.Right), (int)Math.Ceiling((double)r.Bottom));
                        // XAML hosts can expose a full-width Custom element around their controls.
                        if (kind == "ControlType.Custom" && bounds.Contains(candidate) && bounds.Width > candidate.Width * 2)
                            continue;
                        if (bounds.IntersectsWith(candidate)) return false;
                        if ((kind == "ControlType.Button" || kind == "ControlType.ListItem") &&
                            !bounds.IntersectsWith(tray) &&
                            bounds.Top < candidate.Bottom && bounds.Bottom > candidate.Top) sawTaskButton = true;
                    }
                    return sawTaskButton;
                }
            }
            catch (Exception) { return false; } // Shell is restarting or its accessibility provider is unavailable.
        }
    }
}
