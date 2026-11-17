using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Globalization;
using System.Security.Cryptography;

namespace DeskToys
{
public class Amount
{
    public long Input, Cached, Output, Reason, Write;
    public long Total
    {
        get {
            return Input + Output;
        }
    }
    public void Accumulate(Amount v, int sign = 1)
    {
        Input += v.Input * sign;
        Cached += v.Cached * sign;
        Output += v.Output * sign;
        Reason += v.Reason * sign;
        Write += v.Write * sign;
    }
    public static Amount Sum(IEnumerable<Amount> values)
    {
        var a = new Amount();
        foreach (var v in values)
            a.Accumulate(v);
        return a;
    }
}
public class Receipt
{
    public string Key;
    public Amount Amount;
}
public class Quota
{
    public double Used;
    public int Minutes;
    public long Reset;
}
public class FileUsage
{
    public string Tool = "", Session = "", Project = "", Title = "", Prompt = "", Model = "—", Prefix = "";
    public long Offset, Modified;
    public Amount Previous;
    public List<Quota> Limits = new List<Quota>();
    public Dictionary<string, Amount> Days = new Dictionary<string, Amount>();
    public Dictionary<string, Receipt> Seen = new Dictionary<string, Receipt>();
}
public class UsageRow
{
    public string Tool, Session, Title, Model, Project, Day;
    public Amount Value;
}
static class Usage
{
    internal static readonly string[] Tools = { "All", "Codex", "Claude Code", "OpenClaw" };
    static Dictionary<string, object> Obj(object o)
    {
        return o as Dictionary<string, object> ?? new Dictionary<string, object>();
    }
    static object Get(object o, params string[] path)
    {
        foreach (var key in path)
        {
            object v;
            if (!Obj(o).TryGetValue(key, out v))
                return null;
            o = v;
        }
        return o;
    }
    static string Str(object o, params string[] path)
    {
        return Get(o, path) as string ?? "";
    }
    static long N(object o, string k)
    {
        long n;
        return long.TryParse(Convert.ToString(Get(o, k), CultureInfo.InvariantCulture), out n) ? Math.Max(0, n) : 0;
    }
    static string Home { get { return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); } }
    internal static string Base(string env, string fallback)
    {
        return Environment.GetEnvironmentVariable(env) ?? Path.Combine(Home, fallback);
    }
    static string FolderName(string s)
    {
        return (s ?? "").TrimEnd('/', '\\').Split('/', '\\').Last();
    }
    static string Clean(string s)
    {
        return string.IsNullOrWhiteSpace(s)
                   ? ""
                   : new string(s.Trim().Take(110).Select(c => char.IsControl(c) ? ' ' : c).ToArray());
    }
    static string Prompt(object value)
    {
        if (value is string)
            return Clean((string)value);
        var list = value as IEnumerable;
        if (list != null)
            foreach (var p in list)
            {
                if (Str(p, "type") == "text" && Clean(Str(p, "text")) != "")
                    return Clean(Str(p, "text"));
            }
        return "";
    }
    static Amount Codex(object d)
    {
        return new Amount { Input = N(d, "input_tokens"), Cached = N(d, "cached_input_tokens"),
                            Output = N(d, "output_tokens"), Reason = N(d, "reasoning_output_tokens") };
    }
    static Quota Window(object o, int mins, string usedKey, string resetKey, double factor = 1)
    {
        double pct, reset;
        if (!double.TryParse(Convert.ToString(Get(o, usedKey), CultureInfo.InvariantCulture), NumberStyles.Float,
                             CultureInfo.InvariantCulture, out pct) ||
            !double.TryParse(Convert.ToString(Get(o, resetKey), CultureInfo.InvariantCulture), NumberStyles.Float,
                             CultureInfo.InvariantCulture, out reset))
            return null;
        pct *= factor;
        return mins <= 0 || pct < 0 || pct > 100 || reset <= 0
                   ? null
                   : new Quota { Minutes = mins, Used = pct, Reset = (long)reset };
    }
    internal static void Line(FileUsage f, string line)
    {
        if (string.IsNullOrWhiteSpace(line))
            return;
        object o;
        try
        {
            o = Data.Json().DeserializeObject(line);
        }
        catch (ArgumentException)
        {
            return;
        }
        catch (InvalidOperationException)
        {
            return;
        }
        string type = Str(o, "type");
        object p = Get(o, "payload"), m = Get(o, "message");
        if (type == "session_meta")
        {
            f.Session = Str(p, "id");
            f.Project = FolderName(Str(p, "cwd"));
            f.Title = Clean(Str(p, "thread_name"));
            return;
        }
        if (type == "turn_context")
        {
            f.Model = Str(p, "model");
            return;
        }
        if (type == "custom-title" || type == "thread_name_updated")
        {
            f.Title = Clean(Str(o, "customTitle"));
            return;
        }
        if (type == "ai-title" && f.Title == "")
        {
            f.Title = Clean(Str(o, "aiTitle"));
            return;
        }
        if (type == "session")
        {
            f.Session = Str(o, "id");
            f.Project = FolderName(Str(o, "cwd"));
            return;
        }
        if (type == "session_info")
        {
            f.Title = Clean(Str(o, "name"));
            return;
        }
        if (Str(p, "type") == "thread_name_updated")
        {
            f.Title = Clean(Str(p, "thread_name"));
            return;
        }
        if (f.Prompt == "")
        {
            if (Str(p, "type") == "user_message")
                f.Prompt = Prompt(Get(p, "message"));
            else if ((type == "user" && !Equals(Get(o, "isMeta"), true)) || Str(m, "role") == "user")
                f.Prompt = Prompt(Get(m, "content"));
        }
        DateTimeOffset date;
        if (!DateTimeOffset.TryParse(Str(o, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal,
                                     out date))
            return;
        Amount a;
        string id = "";
        if (f.Tool == "Codex")
        {
            if (Str(p, "type") != "token_count")
                return;
            var rates = Get(p, "rate_limits");
            if (rates != null && (Str(rates, "limit_id") == "" || Str(rates, "limit_id") == "codex"))
            {
                var qs = new List<Quota>();
                foreach (var name in new[] { "primary", "secondary" })
                {
                    var w = Get(rates, name);
                    var q = Window(w, (int)Math.Max(N(w, "window_minutes"), N(w, "window_duration_mins")),
                                   "used_percent", "resets_at");
                    if (q != null)
                        qs.Add(q);
                }
                if (qs.Count > 0)
                    f.Limits = qs;
            }
            var counts = Get(p, "info", "total_token_usage");
            if (counts == null)
                return;
            var total = Codex(counts);
            var last = Get(p, "info", "last_token_usage");
            a = Codex(counts);
            if (f.Previous != null)
            {
                a.Accumulate(f.Previous, -1);
                if (a.Input < 0 || a.Output < 0 || a.Cached < 0)
                    a = last == null ? Codex(counts) : Codex(last);
            }
            else if (last != null)
                a = Codex(last);
            f.Previous = total;
        }
        else
        {
            bool claude = f.Tool == "Claude Code";
            var u = Get(m, "usage");
            if (u == null || (claude ? type != "assistant" : type != "message" || Str(m, "role") != "assistant"))
                return;
            if (claude)
            {
                f.Project = FolderName(Str(o, "cwd"));
                if (Str(o, "sessionId") != "")
                    f.Session = Str(o, "sessionId");
            }
            f.Model = Str(m, "model");
            id = claude ? Str(m, "id") : Str(o, "id");
            long hit = N(u, claude ? "cache_read_input_tokens" : "cacheRead"),
                 write = N(u, claude ? "cache_creation_input_tokens" : "cacheWrite");
            a = new Amount { Input = N(u, claude ? "input_tokens" : "input") + hit + write,
                             Output = N(u, claude ? "output_tokens" : "output"), Cached = hit, Write = write };
        }
        if (a.Total == 0)
            return;
        string key = date.LocalDateTime.ToString("yyyy-MM-dd") + "|" + f.Model;
        Receipt previous;
        if (id != "" && f.Seen.TryGetValue(id, out previous))
            f.Days[previous.Key].Accumulate(previous.Amount, -1);
        if (id != "")
            f.Seen[id] = new Receipt { Key = key, Amount = a };
        if (!f.Days.ContainsKey(key))
            f.Days[key] = new Amount();
        f.Days[key].Accumulate(a);
    }
    static IEnumerable<string> Logs(string root)
    {
        var todo = new Stack<string>();
        if (Directory.Exists(root))
            todo.Push(root);
        while (todo.Count > 0)
        {
            var dir = todo.Pop();
            string[] files, dirs;
            try
            {
                files = Directory.GetFiles(dir, "*.jsonl");
                dirs = Directory.GetDirectories(dir);
            }
            catch (IOException)
            {
                continue;
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }
            foreach (var f in files)
                yield return f;
            foreach (var d in dirs)
            {
                try
                {
                    if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) == 0)
                        todo.Push(d);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
    }
    internal static Dictionary<string, FileUsage> Scan()
    {
        var cache = Data.Read<Dictionary<string, FileUsage>>("usage-v1.json");
        bool dirty = false;
        var codex = Base("CODEX_HOME", ".codex");
        var dirs = new[] { Tuple.Create("Codex", Path.Combine(codex, "sessions")),
                           Tuple.Create("Codex", Path.Combine(codex, "archived_sessions")),
                           Tuple.Create("Claude Code", Path.Combine(Base("CLAUDE_CONFIG_DIR", ".claude"), "projects")),
                           Tuple.Create("OpenClaw", Path.Combine(Base("OPENCLAW_STATE_DIR", ".openclaw"), "agents")) };
        foreach (var d in dirs)
            foreach (var path in Logs(d.Item2))
            {
                try
                {
                    var info = new FileInfo(path);
                    FileUsage f;
                    cache.TryGetValue(path, out f);
                    if (f != null && f.Modified == info.LastWriteTimeUtc.Ticks && f.Offset == info.Length)
                        continue;
                    using (var input = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                      FileShare.ReadWrite | FileShare.Delete))
                    {
                        byte[] first = new byte[256];
                        int n = input.Read(first, 0, first.Length);
                        string prefix = n == 256 ? Convert.ToBase64String(first) : "";
                        if (f == null || input.Length < f.Offset || (f.Prefix != "" && f.Prefix != prefix))
                            f = new FileUsage { Tool = d.Item1, Session = Path.GetFileNameWithoutExtension(path) };
                        f.Prefix = prefix;
                        input.Position = f.Offset;
                        long committed = f.Offset;
                        byte[] buf = new byte[65536];
                        using (var line = new MemoryStream())
                        {
                            bool over = false;
                            while ((n = input.Read(buf, 0, buf.Length)) > 0)
                            {
                                int start = 0;
                                for (int i = 0; i < n; i++)
                                {
                                    if (buf[i] != 10)
                                        continue;
                                    if (!over && line.Length + i - start <= 32 * 1024 * 1024)
                                    {
                                        line.Write(buf, start, i - start);
                                        Line(f, Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length));
                                    }
                                    line.SetLength(0);
                                    over = false;
                                    committed = input.Position - n + i + 1;
                                    start = i + 1;
                                }
                                if (line.Length + n - start > 32 * 1024 * 1024)
                                    over = true;
                                if (!over)
                                    line.Write(buf, start, n - start);
                            }
                        }
                        f.Offset = committed;
                        f.Modified = info.LastWriteTimeUtc.Ticks;
                        cache[path] = f;
                        dirty = true;
                    }
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        if (dirty)
            Data.Write("usage-v1.json", cache);
        return cache;
    }
    internal static List<UsageRow> Rows(Dictionary<string, FileUsage> cache)
    {
        var rows = new List<UsageRow>();
        var names = new Dictionary<string, string>();
        var index = Path.Combine(Base("CODEX_HOME", ".codex"), "session_index.jsonl");
        try
        {
            if (File.Exists(index))
                foreach (var line in File.ReadLines(index))
                {
                    object o;
                    try
                    {
                        o = Data.Json().DeserializeObject(line);
                    }
                    catch (ArgumentException)
                    {
                        continue;
                    }
                    var id = Str(o, "id");
                    var title = Clean(Str(o, "thread_name"));
                    if (id != "" && title != "")
                        names[id] = title;
                }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        foreach (var grp in cache.Values.GroupBy(f => f.Tool + "|" + f.Session))
        {
            var f = grp.OrderByDescending(x => x.Offset).First();
            string title;
            if (f.Tool != "Codex" || !names.TryGetValue(f.Session, out title))
                title = new[] { f.Title, f.Prompt, f.Project, f.Tool }.First(s => !string.IsNullOrWhiteSpace(s));
            foreach (var d in f.Days.Where(k => k.Value.Total > 0))
            {
                var key = d.Key.Split(new[] { '|' }, 2);
                rows.Add(new UsageRow { Day = key[0], Model = key[1], Tool = f.Tool, Project = f.Project,
                                        Session = f.Session, Title = title, Value = d.Value });
            }
        }
        return rows;
    }
    internal static bool DirectClaude(string workspace = null)
    {
        var dir = Base("CLAUDE_CONFIG_DIR", ".claude");
        var paths = new List<string> { Path.Combine(dir, "settings.json"), Path.Combine(dir, "settings.local.json"),
                                       Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                                    "ClaudeCode", "managed-settings.json") };
        if (!string.IsNullOrWhiteSpace(workspace))
        {
            paths.Add(Path.Combine(workspace, ".claude", "settings.json"));
            paths.Add(Path.Combine(workspace, ".claude", "settings.local.json"));
        }
        var environment = new Dictionary<string,object>(StringComparer.OrdinalIgnoreCase);
        foreach(DictionaryEntry variable in Environment.GetEnvironmentVariables())environment[(string)variable.Key]=variable.Value;
        var layers = new List<Dictionary<string, object>> {environment};
        try
        {
            foreach (var path in paths.Where(File.Exists))
            {
                var cfg = Data.Json().DeserializeObject(File.ReadAllText(path));
                var provider = Str(cfg, "modelProvider");
                if (provider != "" && provider != "anthropic")
                    return false;
                layers.Add(Obj(Get(cfg, "env")));
            }
        }
        catch
        {
            return false;
        }
        foreach (var layer in layers)
        {
            foreach (var flag in new[] { "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                                         "CLAUDE_CODE_USE_FOUNDRY" })
                if (new[] { "1", "true" }.Contains(Str(layer, flag), StringComparer.OrdinalIgnoreCase))
                    return false;
            var endpoint = Str(layer, "ANTHROPIC_BASE_URL");
            Uri uri;
            if (endpoint != "" && (!Uri.TryCreate(endpoint, UriKind.Absolute, out uri) || uri.Scheme != "https" ||
                                   uri.Host != "api.anthropic.com" || uri.Port != 443))
                return false;
        }
        return true;
    }
    internal static List<Quota> Valid(IEnumerable<Quota> qs)
    {
        return qs.Where(q => q.Reset > DateTimeOffset.UtcNow.ToUnixTimeSeconds()).ToList();
    }
    internal static string StatusLine(string line)
    {
        var o = Data.Json().DeserializeObject(line);
        var qs = new List<Quota>();
        if (DirectClaude(Str(o, "workspace", "project_dir")) &&
            Str(o, "model", "id").StartsWith("claude-", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var pair in new[] { Tuple.Create("five_hour", 300), Tuple.Create("seven_day", 10080) })
            {
                var q = Window(Get(o, "rate_limits", pair.Item1), pair.Item2, "used_percentage", "resets_at");
                if (q != null)
                    qs.Add(q);
            }
        }
        Data.Write("claude-quota.json", qs);
        return string.Join(" · ", new[] { Str(o, "model", "display_name") }.Concat(
                                      Valid(qs).Select(q => (100 - q.Used).ToString("0") + "%")));
    }
}
}
