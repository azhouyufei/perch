using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
namespace DeskToys
{
class Clip
{
    public string Id, Title, Kind, App;
    public bool Pinned;
    public long Time;
    public override string ToString()
    {
        return (Pinned ? "★  " : "") + Title.Replace('\n', ' ').Replace('\r', ' ');
    }
}
class Sql : IDisposable
{
    IntPtr db;
    const string Lib = "winsqlite3.dll";
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_open16([MarshalAs(UnmanagedType.LPWStr)] string path, out IntPtr db);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_prepare16_v2(IntPtr db, [MarshalAs(UnmanagedType.LPWStr)] string sql, int count,
                                           out IntPtr stmt, IntPtr tail);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr st);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr st);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_text16(IntPtr st, int i, [MarshalAs(UnmanagedType.LPWStr)] string text, int length,
                                          IntPtr free);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_blob(IntPtr st, int i, byte[] bytes, int length, IntPtr free);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_int64(IntPtr st, int i, long n);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern long sqlite3_column_int64(IntPtr st, int i);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text16(IntPtr st, int i);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr st, int i);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_errmsg16(IntPtr db);
    internal static string Text(IntPtr s, int i)
    {
        return Marshal.PtrToStringUni(sqlite3_column_text16(s, i)) ?? "";
    }
    internal static byte[] Blob(IntPtr s, int i)
    {
        int n = sqlite3_column_bytes(s, i);
        var b = new byte[n];
        if (n > 0)
            Marshal.Copy(sqlite3_column_blob(s, i), b, 0, n);
        return b;
    }
    public Sql(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        int code = sqlite3_open16(path, out db);
        if (code != 0)
        {
            if (db != IntPtr.Zero)
                sqlite3_close(db);
            throw new IOException("SQLite " + code);
        }
    }
    public void Run(string sql, Action<IntPtr> row = null, params object[] args)
    {
        IntPtr st;
        Check(sqlite3_prepare16_v2(db, sql, -1, out st, IntPtr.Zero));
        try
        {
            for (int i = 0; i < args.Length; i++)
            {
                var v = args[i];
                int r = v is byte[]   ? sqlite3_bind_blob(st, i + 1, (byte[])v, ((byte[])v).Length, (IntPtr)(-1))
                        : v is string ? sqlite3_bind_text16(st, i + 1, (string)v, -1, (IntPtr)(-1))
                                      : sqlite3_bind_int64(st, i + 1, Convert.ToInt64(v));
                Check(r);
            }
            int rc;
            while ((rc = sqlite3_step(st)) == 100)
                if(row!=null)row(st);
            if (rc != 101)
                Check(rc);
        }
        finally
        {
            sqlite3_finalize(st);
        }
    }
    void Check(int rc)
    {
        if (rc != 0)
            throw new IOException(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
    }
    public void Dispose()
    {
        if (db != IntPtr.Zero)
        {
            sqlite3_close(db);
            db = IntPtr.Zero;
        }
    }
}
class Clips : IDisposable
{
    readonly Sql db;
    uint handled;
    public bool Skip;
    public event Action Changed;
    public Clips()
    {
        db = new Sql(Path.Combine(Data.Root, "Clipboard.sqlite"));
        db.Run("CREATE TABLE IF NOT EXISTS clips(id TEXT PRIMARY KEY,title TEXT,kind TEXT,app TEXT,stamp INTEGER,pin " +
               "INTEGER,payload BLOB)");
        handled = Native.GetClipboardSequenceNumber();
    }
    public List<Clip> Rows()
    {
        var result = new List<Clip>();
        db.Run("SELECT id,title,kind,app,stamp,pin FROM clips ORDER BY pin DESC, stamp DESC",
               s => result.Add(new Clip { Id = Sql.Text(s, 0), Title = Sql.Text(s, 1), Kind = Sql.Text(s, 2),
                                          App = Sql.Text(s, 3), Time = Sql.sqlite3_column_int64(s, 4),
                                          Pinned = Sql.sqlite3_column_int64(s, 5) != 0 }));
        return result;
    }
    public static bool Match(Clip c, string q, int mode)
    {
        if (string.IsNullOrWhiteSpace(q))
            return true;
        var s = c.Title + " " + c.App + " " + c.Kind;
        if (mode == 2)
        {
            try
            {
                return Regex.IsMatch(s, q, RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(40));
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (RegexMatchTimeoutException)
            {
                return false;
            }
        }
        if (mode == 1)
        {
            int i = 0;
            foreach (char ch in s)
                if (char.ToUpperInvariant(ch) == char.ToUpperInvariant(q[i]) && ++i == q.Length)
                    return true;
            return false;
        }
        return s.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0;
    }
    static string Owner()
    {
        uint id;
        Native.GetWindowThreadProcessId(Native.GetClipboardOwner(), out id);
        try
        {
            using (var p = Process.GetProcessById((int)id)) return p.ProcessName;
        }
        catch
        {
            return "";
        }
    }
    static string[] Parts(string s)
    {
        return s.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries).Select(x => x.Trim()).ToArray();
    }
    public bool Record()
    {
        uint seq = Native.GetClipboardSequenceNumber();
        if (seq == handled)
            return true;
        if (Skip || Data.Pref.PauseClipboard)
        {
            handled = seq;
            Skip = false;
            return true;
        }
        try
        {
            var d = Clipboard.GetDataObject();
            if (d == null)
                return false;
            var formats = d.GetFormats(false);
            var app = Owner();
            var ignore = Parts(Data.Pref.IgnoreFormats);
            if (Parts(Data.Pref.IgnoreApps).Contains(app, StringComparer.OrdinalIgnoreCase) ||
                formats.Any(s => ignore.Contains(s, StringComparer.OrdinalIgnoreCase) ||
                                 s == "ExcludeClipboardContentFromMonitorProcessing" ||
                                 s.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                handled = seq;
                return true;
            }
            if (formats.Contains("CanIncludeInClipboardHistory"))
            {
                var flag = d.GetData("CanIncludeInClipboardHistory") as MemoryStream;
                if (flag != null && flag.ToArray().All(x => x == 0))
                {
                    handled = seq;
                    return true;
                }
            }
            var payload = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
            string title = "", kind = "Text";
            int total = 0;
            foreach (var format in new[] { DataFormats.UnicodeText, DataFormats.Text, DataFormats.Rtf, DataFormats.Html,
                                           DataFormats.FileDrop, DataFormats.Bitmap, "PNG", "application/pdf",
                                           "UniformResourceLocatorW" })
            {
                bool convert = format == DataFormats.Bitmap;
                if (!d.GetDataPresent(format, convert))
                    continue;
                var val = d.GetData(format, convert);
                byte[] b = null;
                if (val is string)
                {
                    var text = (string)val;
                    b = Encoding.UTF8.GetBytes(text);
                    if (title == "")
                        title = text;
                    if (format == DataFormats.Rtf || format == DataFormats.Html)
                        kind = "Rich text";
                }
                else if (val is string[])
                {
                    var files = (string[])val;
                    b = Encoding.UTF8.GetBytes(Data.Json().Serialize(files));
                    kind = "Files";
                    title = string.Join(" · ", files.Select(Path.GetFileName));
                }
                else if (val is Image)
                {
                    using (var stream = new MemoryStream())
                    {
                        ((Image)val).Save(stream, ImageFormat.Png);
                        b = stream.ToArray();
                    }
                    kind = "Image";
                    title = "PNG · " + ((Image)val).Width + " × " + ((Image)val).Height;
                }
                else if (val is MemoryStream)
                {
                    b = ((MemoryStream)val).ToArray();
                    if (format == "PNG")
                    {
                        kind = "Image";
                        if (title == "")
                            title = "PNG";
                    }
                    if (format == "application/pdf")
                    {
                        kind = "PDF";
                        title = "PDF";
                    }
                }
                if (b == null)
                    continue;
                total += b.Length;
                if (total > 32 * 1024 * 1024)
                {
                    handled = seq;
                    return true;
                }
                payload[format] = b;
            }
            if (Native.GetClipboardSequenceNumber() != seq)
                return false;
            if (payload.Count == 0)
            {
                handled = seq;
                return true;
            }
            byte[] packed;
            using (var mem = new MemoryStream())
            {
                using (var writer = new BinaryWriter(mem, Encoding.UTF8, true))
                {
                    foreach (var p in payload)
                    {
                        writer.Write(p.Key);
                        writer.Write(p.Value.Length);
                        writer.Write(p.Value);
                    }
                }
                packed = mem.ToArray();
            }
            string id;
            using (var hash = SHA256.Create()) id = BitConverter.ToString(hash.ComputeHash(packed)).Replace("-", "");
            db.Run("INSERT OR REPLACE INTO clips VALUES(?,?,?,?,?,COALESCE((SELECT pin FROM clips WHERE id=?),0),?)",
                   null, id, new string(title.Take(32768).ToArray()), kind, app, DateTime.UtcNow.Ticks, id, packed);
            Trim();
            handled = seq;
            if(Changed!=null)Changed();
            return true;
        }
        catch (ExternalException)
        {
            return false;
        }
    }
    public void Trim()
    {
        db.Run("DELETE FROM clips WHERE pin=0 AND id NOT IN (SELECT id FROM clips WHERE pin=0 ORDER BY stamp DESC " +
               "LIMIT ?)",
               null, Data.Pref.ClipLimit);
        long total = 0;
        db.Run("SELECT COALESCE(SUM(length(payload)),0) FROM clips WHERE pin=0",
               s => total = Sql.sqlite3_column_int64(s, 0));
        while (total > 128L * 1024 * 1024)
        {
            string id = "";
            long n = 0;
            db.Run("SELECT id,length(payload) FROM clips WHERE pin=0 ORDER BY stamp LIMIT 1",
                   s =>
                   {
                       id = Sql.Text(s, 0);
                       n = Sql.sqlite3_column_int64(s, 1);
                   });
            if (id == "")
                break;
            db.Run("DELETE FROM clips WHERE id=?", null, id);
            total -= n;
        }
    }
    Dictionary<string, byte[]> Payload(Clip c)
    {
        byte[] bytes = null;
        db.Run("SELECT payload FROM clips WHERE id=?", s => bytes = Sql.Blob(s, 0), c.Id);
        var p = new Dictionary<string, byte[]>();
        if (bytes == null)
            return p;
        using (var r = new BinaryReader(new MemoryStream(bytes))) while (r.BaseStream.Position < r.BaseStream.Length)
        {
            string k = r.ReadString();
            p[k] = r.ReadBytes(r.ReadInt32());
        }
        return p;
    }
    public Bitmap ImageOf(Clip c)
    {
        var p = Payload(c);
        byte[] b;
        if (!p.TryGetValue(DataFormats.Bitmap, out b) && !p.TryGetValue("PNG", out b))
            return null;
        using (var m = new MemoryStream(b)) using (var image = Image.FromStream(m)) return new Bitmap(image);
    }
    public void Copy(Clip c, bool plain)
    {
        var p = Payload(c);
        if (p.Count == 0)
            return;
        var data = new DataObject();
        Bitmap owned = null;
        try
        {
            if (plain)
            {
                byte[] value;
                if (p.TryGetValue(DataFormats.UnicodeText, out value) || p.TryGetValue(DataFormats.Text, out value))
                    data.SetText(Encoding.UTF8.GetString(value));
                else if (p.ContainsKey(DataFormats.FileDrop))
                    data.SetText(string.Join(
                        Environment.NewLine,
                        Data.Json().Deserialize<string[]>(Encoding.UTF8.GetString(p[DataFormats.FileDrop]))));
                else if (p.ContainsKey(DataFormats.Rtf))
                {
                    using (var r = new RichTextBox())
                    {
                        r.Rtf = Encoding.UTF8.GetString(p[DataFormats.Rtf]);
                        data.SetText(r.Text);
                    }
                }
                else if (p.ContainsKey(DataFormats.Html))
                    data.SetText(System.Net.WebUtility.HtmlDecode(
                        Regex.Replace(Encoding.UTF8.GetString(p[DataFormats.Html]), "<[^>]*>", "")));
                else
                    throw new InvalidOperationException(Data.T("此记录没有纯文本", "No plain text in this item"));
            }
            else
                foreach (var pair in p)
                {
                    var k = pair.Key;
                    var b = pair.Value;
                    if (k == DataFormats.Bitmap)
                    {
                        using (var m = new MemoryStream(b)) using (var img = Image.FromStream(m)) owned =
                            new Bitmap(img);
                        data.SetImage(owned);
                    }
                    else if (k == DataFormats.FileDrop)
                    {
                        var list = new StringCollection();
                        list.AddRange(Data.Json().Deserialize<string[]>(Encoding.UTF8.GetString(b)));
                        data.SetFileDropList(list);
                    }
                    else if (k == "PNG" || k == "application/pdf" || k == "UniformResourceLocatorW")
                        data.SetData(k, new MemoryStream(b));
                    else
                        data.SetData(k, Encoding.UTF8.GetString(b));
                }
            Clipboard.SetDataObject(data, true, 5, 40);
            handled = Native.GetClipboardSequenceNumber();
        }
        finally
        {
            if(owned!=null)owned.Dispose();
        }
    }
    public void Pin(Clip c)
    {
        db.Run("UPDATE clips SET pin=1-pin WHERE id=?", null, c.Id);
        Trim();
        if(Changed!=null)Changed();
    }
    public void Delete(Clip c)
    {
        db.Run("DELETE FROM clips WHERE id=?", null, c.Id);
        if(Changed!=null)Changed();
    }
    public void Clear(bool all)
    {
        db.Run(all ? "DELETE FROM clips" : "DELETE FROM clips WHERE pin=0");
        if(Changed!=null)Changed();
    }
    public void Dispose()
    {
        db.Dispose();
    }
}
class ClipPicker : Form
{
    readonly Clips clips;
    readonly ListBox list = new ListBox();
    readonly TextBox search = new TextBox();
    readonly IntPtr previous;
    public ClipPicker(Clips c, IntPtr target)
    {
        clips = c;
        previous = target;
        UI.Theme(this);
        Text = Data.T("剪贴板历史", "Clipboard history");
        Size = new Size(565, 390);
        TopMost = true;
        KeyPreview = true;
        search.Dock = DockStyle.Top;
        list.Dock = DockStyle.Fill;
        list.BackColor = UI.Card;
        list.ForeColor = UI.Ink;
        Controls.Add(list);
        Controls.Add(search);
        search.TextChanged += (s, e) => Fill();
        list.DoubleClick += (s, e) => Choose(Data.Pref.AutoPaste, false);
        Fill();
        Shown += (s, e) => search.Focus();
    }
    void Fill()
    {
        list.Items.Clear();
        list.Items.AddRange(clips.Rows().Where(c => Clips.Match(c, search.Text, 0)).ToArray());
        if (list.Items.Count > 0)
            list.SelectedIndex = 0;
    }
    void Choose(bool paste, bool plain)
    {
        var c = list.SelectedItem as Clip;
        if (c == null)
            return;
        clips.Copy(c, plain);
        Close();
        if (previous != IntPtr.Zero && Native.SetForegroundWindow(previous) && paste)
            SendKeys.SendWait("^v");
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys k)
    {
        var key = k & Keys.KeyCode;
        bool alt = (k & Keys.Alt) != 0;
        if (key == Keys.Escape)
        {
            Close();
            return true;
        }
        if (key == Keys.Enter)
        {
            Choose(alt || Data.Pref.AutoPaste, (k & Keys.Shift) != 0);
            return true;
        }
        if (key >= Keys.D1 && key <= Keys.D9 && (alt || (k & Keys.Control) != 0))
        {
            int i = (int)key - (int)Keys.D1;
            if (i < list.Items.Count)
            {
                list.SelectedIndex = i;
                Choose(alt, false);
            }
            return true;
        }
        if (key == Keys.Up || key == Keys.Down)
        {
            if (list.Items.Count > 0)
                list.SelectedIndex =
                    Math.Max(0, Math.Min(list.Items.Count - 1, list.SelectedIndex + (key == Keys.Up ? -1 : 1)));
            return true;
        }
        var selected = list.SelectedItem as Clip;
        if (selected != null && alt && (key == Keys.P || key == Keys.Delete || key == Keys.Back))
        {
            if (key == Keys.P)
                clips.Pin(selected);
            else
                clips.Delete(selected);
            Fill();
            return true;
        }
        return base.ProcessCmdKey(ref msg, k);
    }
}
}
