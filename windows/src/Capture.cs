using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeskToys
{
enum Tool
{
    Move,
    Pen,
    Arrow,
    Rectangle,
    Cover,
    Circle,
    Ellipse,
    Text,
    Mosaic
}
class Mark
{
    public Tool Tool;
    public Color Ink;
    public int Width;
    public string Text;
    public List<Point> Points = new List<Point>();
    public Rectangle Box { get { return CaptureCanvas.Between(Points[0], Points.Last()); } }
    public void Paint(Graphics g, Bitmap underneath)
    {
        if (Points.Count == 0)
            return;
        var a = Points[0];
        var b = Points.Last();
        var r = Box;
        using (var pen = new Pen(Ink, Width) { StartCap = LineCap.Round, EndCap = LineCap.Round,
                                               LineJoin = LineJoin.Round }) using (var brush = new SolidBrush(Ink))
        {
            switch (Tool)
            {
            case Tool.Pen:
                if (Points.Count > 1)
                    g.DrawLines(pen, Points.ToArray());
                else
                    g.FillEllipse(brush, a.X, a.Y, Width, Width);
                break;
            case Tool.Arrow:
                using (var cap = new AdjustableArrowCap(4, 6))
                {
                    pen.CustomEndCap = cap;
                    g.DrawLine(pen, a, b);
                }
                break;
            case Tool.Rectangle:
                g.DrawRectangle(pen, r);
                break;
            case Tool.Cover:
                g.FillRectangle(brush, r);
                break;
            case Tool.Circle:
            case Tool.Ellipse:
                g.DrawEllipse(pen, r);
                break;
            case Tool.Text:
                using (var f = new Font("Segoe UI", 10 + Width * 2, FontStyle.Regular, GraphicsUnit.Pixel))
                    g.DrawString(Text, f, brush, a);
                break;
            case Tool.Mosaic:
                int block = Math.Max(4, Width * 3);
                r.Intersect(new Rectangle(Point.Empty, underneath.Size));
                for (int y = r.Y; y < r.Bottom; y += block)
                    for (int x = r.X; x < r.Right; x += block)
                        using (var tile = new SolidBrush(underneath.GetPixel(Math.Min(x + block / 2, r.Right - 1),
                                                                             Math.Min(y + block / 2, r.Bottom - 1))))
                            g.FillRectangle(tile, x, y, Math.Min(block, r.Right - x), Math.Min(block, r.Bottom - y));
                break;
            }
        }
    }
}
class CaptureCanvas : Form
{
    public static Rectangle Between(Point a, Point b)
    {
        return Rectangle.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X) + 1,
                                  Math.Max(a.Y, b.Y) + 1);
    }
    readonly Bitmap image;
    readonly bool editor;
    readonly string mode;
    readonly Rectangle desktop;
    readonly List<Rectangle> windows = new List<Rectangle>();
    readonly List<Mark> marks = new List<Mark>();
    readonly Stack<Action> undo = new Stack<Action>();
    readonly ToolStrip tools = new ToolStrip();
    readonly Action<Bitmap, string> finish;
    Rectangle selection, oldSelection;
    Point start, last;
    Mark draft, moving;
    List<Point> oldPoints;
    Tool tool = Tool.Move;
    Color ink = Color.OrangeRed;
    int width = 4, handle = -1;
    bool dragging, creating;
    static readonly string[] icons = { "move", "pen", "arrow", "rect", "cover", "circle", "ellipse", "text", "mosaic" };
    static readonly string[] zh = { "移动", "画笔", "箭头", "矩形", "遮盖", "圆形", "椭圆", "文字", "马赛克" };
    static readonly string[] en = { "Move",   "Pen",     "Arrow", "Rectangle", "Cover",
                                    "Circle", "Ellipse", "Text",  "Mosaic" };
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumProc proc, IntPtr l);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr h, out BoundsRect r);
    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
    struct BoundsRect
    {
        public int L, T, R, B;
    }
    internal Action<Bitmap, List<Mark>> EditSelection;
    public CaptureCanvas(string mode, Bitmap source, Action<Bitmap, string> finish, List<Mark> existing = null)
    {
        if (existing != null)
            foreach (var mark in existing)
            {
                marks.Add(mark);
                var current = mark;
                undo.Push(() => marks.Remove(current));
            }
        this.mode = mode;
        this.finish = finish;
        editor = source != null;
        desktop = mode == "display" ? Screen.PrimaryScreen.Bounds : SystemInformation.VirtualScreen;
        image = source ?? new Bitmap(desktop.Width, desktop.Height, PixelFormat.Format32bppArgb);
        if (!editor)
        {
            using (var g = Graphics.FromImage(image)) g.CopyFromScreen(desktop.Location, Point.Empty, desktop.Size);
            EnumWindows(
                (h, l) =>
                {
                    BoundsRect r;
                    int cloaked;
                    if (IsWindowVisible(h) && !IsIconic(h) && DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 &&
                        cloaked == 0 && GetWindowRect(h, out r) && r.R > r.L && r.B > r.T)
                        windows.Add(new Rectangle(r.L - desktop.X, r.T - desktop.Y, r.R - r.L, r.B - r.T));
                    return true;
                },
                IntPtr.Zero);
        }
        UI.Theme(this);
        KeyPreview = true;
        DoubleBuffered = true;
        BackColor = Color.FromArgb(24, 24, 24);
        Text = Data.T("标注截图", "Annotate screenshot");
        StartPosition = FormStartPosition.Manual;
        if (mode == "display")
            selection = new Rectangle(Point.Empty, image.Size);
        if (editor)
        {
            Bounds = Screen.FromPoint(Cursor.Position).WorkingArea;
            selection = new Rectangle(Point.Empty, image.Size);
        }
        else
        {
            FormBorderStyle = FormBorderStyle.None;
            Bounds = desktop;
            TopMost = true;
            ShowInTaskbar = false;
        }
        tools.GripStyle = ToolStripGripStyle.Hidden;
        tools.Dock = DockStyle.None;
        tools.AutoSize = true;
        tools.BackColor = CaptureRenderer.Background;tools.ForeColor=Color.WhiteSmoke;tools.Renderer=new CaptureRenderer();
        tools.Padding=new Padding(4);tools.ShowItemToolTips=true;tools.ImageScalingSize=new Size(Appearance.Px(this,25),Appearance.Px(this,25));
        Controls.Add(tools);
        for (int i = 0; i < icons.Length; i++)
        {
            var k = (Tool)i;
            Add(icons[i], Data.T(zh[i], en[i]), () => Choose(k));
        }
        var widths = new ToolStripDropDownButton() { ToolTipText = Data.T("线宽", "Stroke width") };
        foreach (int n in new[] { 1, 2, 4, 6, 8, 12, 16 })
            widths.DropDownItems.Add(n + " px", null, (s, e) => width = n);
        SetToolImage(widths,"width",UI.Blue);tools.Items.Add(widths);
        var colors = new ToolStripDropDownButton() { ForeColor = ink, ToolTipText = Data.T("颜色", "Color") };
        SetToolImage(colors,"paint",ink);tools.Items.Add(colors);
        foreach (var c in new[] { Color.Black, Color.Gray, Color.White, Color.Red, Color.Orange, Color.Gold,
                                  Color.Green, Color.Cyan, Color.SkyBlue, Color.Blue, Color.Indigo, Color.Purple,
                                  Color.Magenta, Color.Pink, Color.Brown, Color.DarkGreen })
        {
            var swatch = new Bitmap(14, 14);
            using (var g = Graphics.FromImage(swatch)) g.Clear(c);
            colors.DropDownItems.Add(c.Name, swatch,
                                     (s, e) =>
                                     {
                                         ink = c;
                                         SetToolImage(colors,"paint",c);
                                     });
        }
        colors.DropDownItems.Add(
            Data.T("自定义颜色…", "Custom color…"), null,
            (s, e) =>
            {
                using (var p =
                           new ColorDialog { FullOpen = true, Color = ink }) if (p.ShowDialog(this) == DialogResult.OK)
                {
                    ink = p.Color;
                    SetToolImage(colors,"paint",ink);
                }
            });
        Add("undo", Data.T("撤销", "Undo"), Undo);
        Add("copy", Data.T("复制", "Copy"), () => Accept("copy"));
        Add("pin", Data.T("贴图", "Pin"), () => Accept("pin"));
        Add("save", Data.T("保存", "Save"), () => Accept(editor ? "store" : "save"));
        Add("check", Data.T("完成", "Done"), () => Accept(editor ? "store" : "preferred"));
        Add("close", "Esc", Close);
        tools.Visible = editor;
        Choose(Tool.Move);
        Resize += (s, e) =>
        {
            PositionTools();
            Invalidate();
        };
        Shown += (s, e) =>
        {
            Activate();
            PositionTools();
            if (mode == "display")
                BeginInvoke((Action)(() => Accept("preferred")));
        };
    }
    void Add(string sign, string help, Action run)
    {
        var button=new ToolStripButton { ToolTipText=help,AccessibleName=help,AutoSize=false,
            Width=Appearance.Px(this,36),Height=Appearance.Px(this,36),DisplayStyle=ToolStripItemDisplayStyle.Image };
        Color color=sign=="close"||sign=="cover"?UI.Orange:sign=="check"||sign=="pen"?UI.Green:
                    sign=="pin"||sign=="text"?Appearance.Purple:sign=="mosaic"||sign=="arrow"?UI.Yellow:UI.Blue;
        SetToolImage(button,sign,color);button.Click+=(s,e)=>run();tools.Items.Add(button);
    }
    static void SetToolImage(ToolStripItem item,string key,Color color){
        var old=item.Image;item.Image=Appearance.SymbolOn(key,color,48,CaptureRenderer.Background);if(old!=null)old.Dispose();
    }
    sealed class CaptureRenderer:ToolStripProfessionalRenderer{
        internal static readonly Color Background=Color.FromArgb(28,32,39);
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e){e.Graphics.Clear(Background);}
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e){
            e.TextColor=Color.WhiteSmoke;base.OnRenderItemText(e);
        }
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e){
            using(var brush=new SolidBrush(e.Item.Selected?Color.FromArgb(57,67,80):Background))e.Graphics.FillRectangle(brush,new Rectangle(Point.Empty,e.Item.Size));
        }
        protected override void OnRenderButtonBackground(ToolStripItemRenderEventArgs e){
            var item=e.Item as ToolStripButton;
            if(e.Item.Selected||(item!=null&&item.Checked)){
                using(var brush=new SolidBrush(Color.FromArgb(57,67,80)))e.Graphics.FillRectangle(brush,new Rectangle(Point.Empty,e.Item.Size));
                if(item!=null&&item.Checked)using(var pen=new Pen(UI.Blue,2))e.Graphics.DrawLine(pen,4,item.Height-3,item.Width-4,item.Height-3);
            }
        }
    }
    void Choose(Tool t)
    {
        tool = t;
        for (int i = 0; i < icons.Length; i++)
            ((ToolStripButton)tools.Items[i]).Checked = i == (int)t;
        Cursor = t == Tool.Move ? Cursors.Cross : Cursors.Cross;
    }
    RectangleF View
    {
        get {
            if (!editor)
                return new RectangleF(0, 0, image.Width, image.Height);
            float scale = Math.Min((float)Math.Max(1, ClientSize.Width - 16) / image.Width,
                                   (float)Math.Max(1, ClientSize.Height - 59) / image.Height);
            return new RectangleF((ClientSize.Width - image.Width * scale) / 2,
                                  44 + (ClientSize.Height - 46 - image.Height * scale) / 2, image.Width *scale,
                                  image.Height *scale);
        }
    }
    Point ImagePoint(Point p)
    {
        var v = View;
        return new Point(Math.Max(0, Math.Min(image.Width - 1, (int)((p.X - v.X) * image.Width / v.Width))),
                         Math.Max(0, Math.Min(image.Height - 1, (int)((p.Y - v.Y) * image.Height / v.Height))));
    }
    Rectangle WindowAt(Point p)
    {
        return windows.FirstOrDefault(r => r.Contains(p));
    }
    void PositionTools()
    {
        if (!tools.Visible)
            return;
        int x = editor ? 8 : selection.X, y = editor ? 5 : selection.Bottom + 5;
        if (!editor && y + tools.Height > ClientSize.Height)
            y = Math.Max(0, selection.Top - tools.Height - 4);
        tools.Location = new Point(Math.Max(0, Math.Min(x, ClientSize.Width - tools.Width)), y);
    }
    static Point[] Handles(Rectangle r)
    {
        return new[] { new Point(r.Left, r.Top),     new Point(r.Left + r.Width / 2, r.Top),
                       new Point(r.Right, r.Top),    new Point(r.Right, r.Top + r.Height / 2),
                       new Point(r.Right, r.Bottom), new Point(r.Left + r.Width / 2, r.Bottom),
                       new Point(r.Left, r.Bottom),  new Point(r.Left, r.Top + r.Height / 2) };
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        var v = View;
        var saved = g.Save();
        g.TranslateTransform(v.X, v.Y);
        g.ScaleTransform(v.Width / image.Width, v.Height / image.Height);
        g.DrawImageUnscaled(image, 0, 0);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var crop = selection.IsEmpty ? WindowAt(last) : selection;
        var before = g.Save();
        if (!selection.IsEmpty)
            g.SetClip(selection);
        foreach (var m in marks)
            m.Paint(g, image);
        if (draft != null)
            draft.Paint(g, image);
        g.Restore(before);
        if (!editor)
        {
            using (var shade = new SolidBrush(Color.FromArgb(105, 0, 0, 0))) using (
                var region = new Region(new Rectangle(Point.Empty, image.Size)))
            {
                region.Exclude(crop);
                g.FillRegion(shade, region);
            }
            if (!crop.IsEmpty)
            {
                g.DrawRectangle(Pens.DeepSkyBlue, crop);
                foreach (var p in Handles(crop))
                    g.FillRectangle(Brushes.White, p.X - 3, p.Y - 3, 6, 6);
            }
            if (!dragging && selection.IsEmpty)
            {
                var loc = ImagePoint(PointToClient(Cursor.Position));
                int x = Math.Min(image.Width - 125, Math.Max(0, loc.X + 16)),
                    y = Math.Min(image.Height - 78, Math.Max(0, loc.Y + 15));
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.DrawImage(image, new Rectangle(x, y, 118, 52), new Rectangle(loc.X - 12, loc.Y - 5, 24, 10),
                            GraphicsUnit.Pixel);
                g.FillRectangle(Brushes.Black, x, y + 52, 118, 22);
                g.DrawString(ColorTranslator.ToHtml(image.GetPixel(loc.X, loc.Y)) + "  ·  C", Font, Brushes.White,
                             x + 2, y + 53);
            }
        }
        g.Restore(saved);
    }
    Mark TextAt(Point p)
    {
        foreach (var m in marks.AsEnumerable().Reverse().Where(x => x.Tool == Tool.Text))
        {
            using (var f =
                       new Font("Segoe UI", 10 + m.Width * 2, FontStyle.Regular,
                                GraphicsUnit.Pixel)) if (new Rectangle(m.Points[0], TextRenderer.MeasureText(m.Text, f))
                                                             .Contains(p)) return m;
        }
        return null;
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Right)
        {
            Close();
            return;
        }
        if (e.Button != MouseButtons.Left)
            return;
        start = last = ImagePoint(e.Location);
        if (mode == "color")
        {
            Clipboard.SetText(ColorTranslator.ToHtml(image.GetPixel(start.X, start.Y)));
            Close();
            return;
        }
        dragging = true;
        Capture = true;
        oldSelection = selection;
        handle = -1;
        creating = false;
        if (!editor && tool == Tool.Move && !selection.IsEmpty)
        {
            var hs = Handles(selection);
            handle = Array.FindIndex(hs, p => Math.Abs(p.X - start.X) < 8 && Math.Abs(p.Y - start.Y) < 8);
            if (handle >= 0)
                return;
        }
        if (!selection.IsEmpty && selection.Contains(start) && (tool == Tool.Move || tool == Tool.Text))
        {
            moving = TextAt(start);
            if (moving != null)
            {
                oldPoints = moving.Points.ToList();
                return;
            }
        }
        if (!editor && (selection.IsEmpty || !selection.Contains(start)))
        {
            creating = true;
            selection = Rectangle.Empty;
            tools.Visible = false;
            return;
        }
        if (tool == Tool.Text)
        {
            dragging = false;
            Capture = false;
            var text = UI.Prompt(Data.T("文字", "Text"), "", true);
            if (!string.IsNullOrWhiteSpace(text))
            {
                var m =
                    new Mark { Tool = tool, Ink = ink, Width = width, Text = text, Points = new List<Point> { start } };
                marks.Add(m);
                undo.Push(() => marks.Remove(m));
            }
            Invalidate();
            return;
        }
        if (tool != Tool.Move)
            draft = new Mark { Tool = tool, Ink = ink, Width = width, Points = new List<Point> { start, start } };
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        last = ImagePoint(e.Location);
        if (dragging)
        {
            if (moving != null)
                moving.Points =
                    oldPoints.Select(p => new Point(p.X + last.X - start.X, p.Y + last.Y - start.Y)).ToList();
            else if (draft != null)
            {
                var b = last;
                if (draft.Tool == Tool.Circle)
                {
                    int n = Math.Min(Math.Abs(last.X - start.X), Math.Abs(last.Y - start.Y));
                    b = new Point(start.X + Math.Sign(last.X - start.X) * n, start.Y + Math.Sign(last.Y - start.Y) * n);
                }
                if (draft.Tool == Tool.Pen)
                    draft.Points.Add(b);
                else
                    draft.Points[1] = b;
            }
            else if (creating)
                selection = Between(start, last);
            else if (handle >= 0)
            {
                var a = oldSelection.Location;
                var b = new Point(oldSelection.Right - 1, oldSelection.Bottom - 1);
                if (handle == 0 || handle == 6 || handle == 7)
                    a.X = last.X;
                if (handle == 0 || handle == 1 || handle == 2)
                    a.Y = last.Y;
                if (handle == 2 || handle == 3 || handle == 4)
                    b.X = last.X;
                if (handle == 4 || handle == 5 || handle == 6)
                    b.Y = last.Y;
                selection = Between(a, b);
            }
            else if (!editor)
                selection.Location = new Point(
                    Math.Max(0, Math.Min(image.Width - selection.Width, oldSelection.X + last.X - start.X)),
                    Math.Max(0, Math.Min(image.Height - selection.Height, oldSelection.Y + last.Y - start.Y)));
            PositionTools();
        }
        Invalidate();
    }
    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (!dragging)
            return;
        dragging = false;
        Capture = false;
        if (moving != null)
        {
            var m = moving;
            var pts = oldPoints;
            undo.Push(() => m.Points = pts);
            moving = null;
        }
        if (draft != null)
        {
            var m = draft;
            marks.Add(m);
            undo.Push(() => marks.Remove(m));
            draft = null;
        }
        if (creating && (mode == "window" || Math.Abs(last.X - start.X) + Math.Abs(last.Y - start.Y) < 4))
            selection = Rectangle.Intersect(new Rectangle(Point.Empty, image.Size), WindowAt(start));
        if (mode == "window" && !selection.IsEmpty)
        {
            Accept("preferred");
            return;
        }
        tools.Visible = !selection.IsEmpty;
        PositionTools();
        Invalidate();
    }
    void Undo()
    {
        if (undo.Count > 0)
        {
            undo.Pop()();
            Invalidate();
        }
    }
    internal void PinSelection()
    {
        Accept("pin");
    }
    void Accept(string action)
    {
        if (selection.IsEmpty)
            return;
        using (var full = new Bitmap(image))
        {
            using (var g = Graphics.FromImage(full))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                foreach (var m in marks)
                    m.Paint(g, image);
            }
            var result = full.Clone(Rectangle.Intersect(selection, new Rectangle(Point.Empty, full.Size)),
                                    PixelFormat.Format32bppArgb);
            Hide();
            try
            {
                finish(result, action);
            }
            finally
            {
                result.Dispose();
                Close();
            }
        }
    }
    protected override void OnDoubleClick(EventArgs e)
    {
        base.OnDoubleClick(e);
        if (!editor && !selection.IsEmpty)
            Accept("preferred");
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys k)
    {
        if (k == Keys.Escape)
        {
            Close();
            return true;
        }
        if (k == (Keys.Control | Keys.Z))
        {
            Undo();
            return true;
        }
        if (k == Keys.C && !editor)
        {
            Clipboard.SetText(ColorTranslator.ToHtml(image.GetPixel(last.X, last.Y)));
            return true;
        }
        if (k == (Keys.Control | Keys.A) && !editor)
        {
            var r = Screen.FromPoint(Cursor.Position).Bounds;
            r.Offset(-desktop.X, -desktop.Y);
            selection = r;
            tools.Visible = true;
            PositionTools();
            Invalidate();
            return true;
        }
        if (k == Keys.Space && !editor && !selection.IsEmpty && EditSelection != null)
        {
            var crop = Rectangle.Intersect(selection, new Rectangle(Point.Empty, image.Size));
            var editable =
                marks
                    .Select(
                        m => new Mark { Tool = m.Tool, Ink = m.Ink, Width = m.Width, Text = m.Text,
                                        Points = m.Points.Select(p => new Point(p.X - crop.X, p.Y - crop.Y)).ToList() })
                    .ToList();
            using (var source = image.Clone(crop, PixelFormat.Format32bppArgb))
            {
                Hide();
                try
                {
                    EditSelection(source, editable);
                }
                finally
                {
                    Close();
                }
            }
            return true;
        }
        if (k == Keys.Enter || k == (Keys.Control | Keys.C))
        {
            Accept(editor && k == Keys.Enter ? "store" : "copy");
            return true;
        }
        if (k == Keys.F3 || k == (Keys.Control | Keys.T))
        {
            Accept("pin");
            return true;
        }
        if (k == (Keys.Control | Keys.S))
        {
            Accept("save");
            return true;
        }
        var key = k & Keys.KeyCode;
        if (key >= Keys.D1 && key <= Keys.D9)
        {
            Choose((Tool)((int)key - (int)Keys.D1));
            return true;
        }
        int step = (k & Keys.Shift) != 0 ? 10 : 1;
        if (!editor && !selection.IsEmpty &&
            (key == Keys.Left || key == Keys.Right || key == Keys.Up || key == Keys.Down))
        {
            selection.X = Math.Max(0, Math.Min(image.Width - selection.Width, selection.X + (key == Keys.Left    ? -step
                                                                                             : key == Keys.Right ? step
                                                                                                                 : 0)));
            selection.Y =
                Math.Max(0, Math.Min(image.Height - selection.Height, selection.Y + (key == Keys.Up     ? -step
                                                                                     : key == Keys.Down ? step
                                                                                                        : 0)));
            PositionTools();
            Invalidate();
            return true;
        }
        return base.ProcessCmdKey(ref msg, k);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing){
            image.Dispose();
            foreach(ToolStripItem item in tools.Items){var owned=item.Image;item.Image=null;if(owned!=null)owned.Dispose();}
        }
        base.Dispose(disposing);
    }
}
class ImagePin : Form
{
    readonly Bitmap content;
    double zoom;
    public ImagePin(Bitmap bitmap)
    {
        content = new Bitmap(bitmap);
        UI.Theme(this);
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = false;
        BackgroundImage = content;
        BackgroundImageLayout = ImageLayout.Zoom;
        KeyPreview = true;
        zoom = Math.Min(1, Math.Min(800d / content.Width, 650d / content.Height));
        ResizePin();
        MouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Left)
                Native.Drag(this);
            if (e.Button == MouseButtons.Right)
                Opacity = Opacity == 1 ? 0.55 : 1;
        };
        MouseWheel += (s, e) =>
        {
            zoom = Math.Max(0.05, Math.Min(4, zoom * (e.Delta > 0 ? 1.1 : 1 / 1.1)));
            ResizePin();
        };
        DoubleClick += (s, e) => Close();
        KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Escape)
                Close();
        };
    }
    void ResizePin()
    {
        ClientSize = new Size(Math.Max(12, (int)(content.Width * zoom)), Math.Max(12, (int)(content.Height * zoom)));
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            BackgroundImage = null;
            content.Dispose();
        }
        base.Dispose(disposing);
    }
}
static class Gallery
{
    internal static string Folder
    {
        get {
            var d = Path.Combine(Data.Root, "Captures");
            Directory.CreateDirectory(d);
            return d;
        }
    }
    internal static string Store(Bitmap b)
    {
        var path = Path.Combine(Folder, DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + "-" +
                                            Guid.NewGuid().ToString("N").Substring(0, 6) + ".png");
        b.Save(path, ImageFormat.Png);
        return path;
    }
    internal static Bitmap Read(string path)
    {
        using (var b = Image.FromFile(path)) return new Bitmap(b);
    }
    internal static async Task<string> Ocr(string path)
    {
        string ps = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".ps1");
        try
        {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("DeskToys.Ocr.ps1")) using (
                var f = File.Create(ps)) stream.CopyTo(f);
            var info = new ProcessStartInfo(
                "powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Data.Quote(ps) + " " +
                                      Data.Quote(path)) { CreateNoWindow = true, UseShellExecute = false,
                                                          RedirectStandardOutput = true, RedirectStandardError = true,
                                                          StandardOutputEncoding = Encoding.UTF8 };
            using (var p = Process.Start(info))
            {
                var output = p.StandardOutput.ReadToEndAsync();
                var errors = p.StandardError.ReadToEndAsync();
                await Task.WhenAll(output, errors);
                await Task.Run(() => p.WaitForExit());
                if (p.ExitCode != 0)
                    throw new Exception(errors.Result);
                return output.Result.Trim();
            }
        }
        finally
        {
            File.Delete(ps);
        }
    }
}
}
