using System;
using System.IO;
using System.Drawing;
using System.Linq;
using System.Collections.Generic;
using System.Text;
using DeskToys;
class Checks
{
    static int passed;
    static void Check(bool ok, string message)
    {
        if (!ok)
            throw new Exception(message);
        Console.WriteLine("PASS " + message);
        passed++;
    }
    static string Log(string root, string sub, string name, params object[] records)
    {
        var folder = Path.Combine(root, sub);
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, name);
        File.WriteAllLines(file, records.Select(r => Data.Json().Serialize(r)), new UTF8Encoding(false));
        return file;
    }
    static object Token(string stamp, int i, int o)
    {
        return new { timestamp = stamp,
                     payload = new { type = "token_count",
                                     info = new { total_token_usage = new { input_tokens = i, output_tokens = o } } } };
    }
    static object Claude(string stamp, int output)
    {
        return new { timestamp = stamp, type = "assistant", sessionId = "cs", cwd = "C:/work/notes",
                     message = new { id = "same", model = "claude-x",
                                     usage = new { input_tokens = 8, cache_read_input_tokens = 4,
                                                   cache_creation_input_tokens = 2, output_tokens = output } } };
    }
    static double RelativeLight(Color c){
        Func<byte,double> f=v=>v<=10?v/3294.6:Math.Pow((v/255.0+0.055)/1.055,2.4);
        return .2126*f(c.R)+.7152*f(c.G)+.0722*f(c.B);
    }
    static void CheckTaskbarReadout()
    {
        var values = new Sample { Cpu = 17, Memory = 64, Up = 1000000, Down = 0 };
        Check(TaskbarReadout.Lines(values).SequenceEqual(new[] { "CPU 17%", "RAM 64%", "↑ 1 MB/s", "↓ 0 B/s" }),
              "Taskbar readout shows percentages and directional transfer rates");
        Check(TaskbarReadout.Lines(new Sample()).All(line => line.EndsWith("—")), "Missing readings stay distinct from zero");
        var screen = new Rectangle(-1920, 0, 1920, 1080);
        var bottom = new Rectangle(-1920, 1040, 1920, 40);
        var tray = new Rectangle(-270, 1040, 270, 40);
        var size = new Size(170, 32);
        Check(TaskbarReadout.Candidate(bottom, tray, size) == new Rectangle(-440, 1044, 170, 32),
              "Readout sits beside notification area on a negative-coordinate display");
        Check(TaskbarReadout.Candidate(bottom, new Rectangle(-1920, 1040, 270, 40), size).Left == -1650,
              "Left-aligned notification area is preserved");
        var left = new Rectangle(-1920, 0, 48, 1080);
        Check(TaskbarReadout.Candidate(left, tray, size).IsEmpty &&
              TaskbarReadout.Beside(screen, left, Rectangle.Empty, size).Left == left.Right &&
              TaskbarReadout.Beside(screen, bottom, tray, size).Bottom == bottom.Top &&
              TaskbarReadout.Beside(screen, new Rectangle(-1920, 0, 1920, 40), Rectangle.Empty, size).Top == 40,
              "Edge placement clears bottom, top and vertical taskbars");
    }
    static void CheckArtwork(){
        var keys=new[]{"region","window","display","pin","color","gallery","move","pen","arrow","rect","cover","circle","ellipse","text","mosaic","undo","copy","save","check","close","width"};
        foreach(Color background in new[]{Color.White,Color.FromArgb(28,32,39)}){
            for(int i=0;i<keys.Length;i++)using(var b=Appearance.SymbolOn(keys[i],Appearance.Palette[i%6],24,background)){
                int visible=0;
                for(int y=0;y<24;y++)for(int x=0;x<24;x++){var c=b.GetPixel(x,y);
                    double a=RelativeLight(c)+.05,z=RelativeLight(background)+.05;if(c.A>215&&Math.Max(a,z)/Math.Min(a,z)>=3)visible++;
                }
                if(visible<15)throw new Exception(keys[i]+" has insufficient contrast");
            }
            Check(true,"21 tool shapes visible on "+background.Name);
        }
        foreach(var px in new[]{16,20,24,32,48})foreach(var g in new[]{"cpu","traffic","awake","-","100","17K","999M"})
            using(var b=TrayArtwork.Draw(px,g,g.EndsWith("M"))){
                int count=0;for(int y=0;y<px;y++)for(int x=0;x<px;x++)if(b.GetPixel(x,y).R>=220)count++;
                if(count<12)throw new Exception("Unclear tray glyph "+g);
            }
        Check(true,"Tray artwork at five taskbar pixel sizes");
        Check(TrayArtwork.TokenBadge(123456)=="123K"&&TrayArtwork.TokenBadge(987654321)=="987M","Bounded numeric tray badges");
    }
    static void CheckButtonOutlines(){
        foreach(float scale in new float[]{1,1.25f,1.5f,2}){
            foreach(Color face in new[]{Color.FromArgb(225,229,232),Color.FromArgb(247,222,154),Color.FromArgb(48,50,55)}){
                Color parent=face.R>200?Color.White:Color.Black,ink=face.R>200?Color.Black:Color.White;
                foreach(bool focused in new[]{false,true})using(var b=new Bitmap((int)(64*scale),(int)(32*scale)))
                using(var g=Graphics.FromImage(b)){
                    RoundedButton.PaintSurface(g,b.Size,scale,parent,face,ink,focused);
                    int w=b.Width,h=b.Height;
                    if(b.GetPixel(0,0).ToArgb()!=parent.ToArgb()||b.GetPixel(w-1,h-1).ToArgb()!=parent.ToArgb())throw new Exception("Square corner");
                    foreach(Point direction in new[]{new Point(0,1),new Point(1,0),new Point(0,-1),new Point(-1,0)}){
                        int x=direction.X>0?0:direction.X<0?w-1:w/2,y=direction.Y>0?0:direction.Y<0?h-1:h/2;
                        bool edge=false,focusLine=false;
                        for(int i=0;i<(int)Math.Ceiling(scale*6);i++){
                            var pixel=b.GetPixel(x+i*direction.X,y+i*direction.Y);
                            if(Math.Abs(pixel.R-ink.R)<Math.Abs(face.R-ink.R)*.86)edge=true;
                            if(Math.Abs(pixel.R-ink.R)<Math.Abs(face.R-ink.R)*.45)focusLine=true;
                        }
                        if(!edge||(focused&&!focusLine))throw new Exception("Incomplete button outline at "+scale);
                    }
                }
            }
            Check(true,"Continuous button border and focus ring at "+(scale*100)+"%");
        }
    }
    static IEnumerable<System.Windows.Forms.Control> Descendants(System.Windows.Forms.Control parent){
        foreach(System.Windows.Forms.Control child in parent.Controls){yield return child;foreach(var inner in Descendants(child))yield return inner;}
    }
    static void WindowsControls(){
        using(var host=new System.Windows.Forms.Form())
        using(var menu=new System.Windows.Forms.ContextMenuStrip()){
            host.Show();Appearance.RetireMenu(menu);var item=menu.Items.Add("Pin");
            menu.Show(host,0,0);menu.Close();
            Check(!menu.IsDisposed,"Menu survives the current click dispatch");
            System.Windows.Forms.Application.DoEvents();Check(menu.IsDisposed,"Menu released after dispatch");
        }
        using(var note=new NoteWindow(Data.Book.Notes[0])){note.Show();System.Windows.Forms.Application.DoEvents();
            var plus=Descendants(note).OfType<RoundedButton>().First(b=>b.AccessibleName==Data.T("加入已有待办","Add existing task"));
            Check(plus.Top>=plus.Parent.Padding.Top&&plus.Bottom<=plus.Parent.Height-plus.Parent.Padding.Bottom,"Sticky note add button fits inside footer");
            note.WindowState=System.Windows.Forms.FormWindowState.Minimized;note.Reveal();System.Windows.Forms.Application.DoEvents();
            Check(note.Visible&&note.WindowState==System.Windows.Forms.FormWindowState.Normal&&note.TopMost&&!note.ShowInTaskbar,"Restore and reveal desktop note");}
        using(var window=new Workspace()){
            window.Open(1);System.Windows.Forms.Application.DoEvents();
            var tables=Descendants(window).OfType<System.Windows.Forms.DataGridView>().ToArray();
            Check(tables.Length==2&&tables.All(grid=>{
                var more=Descendants(grid.Parent).OfType<RoundedButton>().First(b=>b.Text==Data.T("展开","More"));
                return grid.PointToScreen(Point.Empty).Y-more.PointToScreen(new Point(0,more.Height)).Y>=Appearance.Px(grid,8);
            }),"Both process tables have a gap below their expand button");
            window.Open(3);var reveal=Descendants(window).OfType<RoundedButton>().First(b=>b.AccessibleName==Data.T("显示便签","Show note"));
            reveal.PerformClick();window.Hide();System.Windows.Forms.Application.DoEvents();
            var notes=System.Windows.Forms.Application.OpenForms.OfType<NoteWindow>().Where(n=>n.Visible).ToArray();
            Check(notes.Length==1,"Task action shows a single note independently of workspace");
        }
        foreach(string theme in new[]{"dark","light"}){
            Data.Pref.Theme=theme;
            using(var editor=new CaptureCanvas("editor",new Bitmap(64,64),(bitmap,action)=>{})){
                editor.Show();var toolbar=editor.Controls.OfType<System.Windows.Forms.ToolStrip>().Single();
                Check(toolbar.Items.OfType<System.Windows.Forms.ToolStripButton>().All(b=>b.Image!=null&&b.Width>=32&&!string.IsNullOrEmpty(b.ToolTipText)),"Annotation icons and hit targets under "+theme);
                editor.Close();
            }
        }
    }
    [STAThread]
    static int Main()
    {
        string tmp = Path.Combine(Path.GetTempPath(), "DeskToys-checks-" + Guid.NewGuid());
        Directory.CreateDirectory(tmp);
        try
        {
            string legacy = Directory.CreateDirectory(Path.Combine(tmp, "DeskToys")).FullName;
            string target = Path.Combine(tmp, "perch");
            File.WriteAllText(Path.Combine(legacy, "tasks.json"), "original");
            Data.MigrateStorage(target);
            Data.MigrateStorage(target);
            Check(File.ReadAllText(Path.Combine(target, "tasks.json")) == "original" && !Directory.Exists(legacy), "Repeatable Perch directory migration");
            Directory.CreateDirectory(legacy);
            File.WriteAllText(Path.Combine(legacy, "tasks.json"), "other");
            Data.MigrateStorage(target);
            Check(File.ReadAllText(Path.Combine(target, "tasks.json")) == "original" && Directory.Exists(legacy), "Existing Perch data takes precedence");
            Data.Root = Path.Combine(tmp, "local");
            Data.Load();
            foreach (var env in new[] { "CODEX_HOME", "CLAUDE_CONFIG_DIR", "OPENCLAW_STATE_DIR" })
                Environment.SetEnvironmentVariable(env, tmp);
            string d1 = "2024-05-21T12:00:00Z", d2 = "2024-05-22T12:00:00Z";
            var log = Log(tmp, "sessions", "rollout.jsonl",
                          new { type = "session_meta", payload = new { id = "sid", cwd = "C:/work/tool" } },
                          new { type = "turn_context", payload = new { model = "gpt-test" } }, Token(d1, 10, 2),
                          Token(d2, 22, 5));
            Log(tmp, ".", "session_index.jsonl", new { id = "sid", thread_name = "Build clipboard search" });
            Log(tmp, "projects", "claude.jsonl", new { type = "custom-title", customTitle = "Draft" }, Claude(d1, 2),
                Claude(d1, 3));
            Log(tmp, "agents", "bot.jsonl", new { type = "session", id = "bot", cwd = "C:/work/open" },
                new { type = "message", timestamp = d2, id = "m1",
                      message = new { role = "assistant", model = "local",
                                      usage = new { input = 3, cacheRead = 2, output = 4 } } });
            var rows = Usage.Rows(Usage.Scan());
            var codex = rows.Where(r => r.Tool == "Codex").ToList();
            Check(codex.Count == 2 && codex.Sum(r => r.Value.Total) == 27, "Codex cumulative deltas across dates");
            Check(codex.All(r => r.Title == "Build clipboard search" && r.Model == "gpt-test"),
                  "Session titles from index and model");
            Check(rows.Single(r => r.Tool == "Claude Code").Value.Total == 17,
                  "Deduplicate Claude message updates with cache accounting");
            Check(rows.Single(r => r.Tool == "OpenClaw").Value.Total == 9, "OpenClaw token components");
            var partial = Data.Json().Serialize(Token(d2, 30, 7));
            File.AppendAllText(log, partial);
            Check(Usage.Rows(Usage.Scan()).Sum(r => r.Value.Total) == 53, "Partial JSONL record deferred");
            File.AppendAllText(log, "\n");
            Check(Usage.Rows(Usage.Scan()).Sum(r => r.Value.Total) == 63, "Completed append indexed once");
            var archive = Path.Combine(tmp, "archived_sessions");
            Directory.CreateDirectory(archive);
            File.Copy(log, Path.Combine(archive, "archive.jsonl"));
            Check(Usage.Rows(Usage.Scan()).Sum(r => r.Value.Total) == 63, "Active and archive deduplication");
            File.Delete(log);
            Check(Usage.Rows(Usage.Scan()).Count == 4, "History survives moving a log");
            File.WriteAllText(
                Path.Combine(tmp, "settings.json"),
                Data.Json().Serialize(new { env = new { ANTHROPIC_BASE_URL = "http://localhost:8080" } }));
            var snapshot = Data.Json().Serialize(
                new { model = new { id = "claude-test", display_name = "Claude" }, rate_limits = new {
                         five_hour = new { used_percentage = 10,
                                           resets_at = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds() }
                     } });
            Usage.StatusLine(snapshot);
            Check(!Usage.DirectClaude() && !Data.Read<List<Quota>>("claude-quota.json").Any(),
                  "Custom Claude endpoint suppresses quota");
            File.Delete(Path.Combine(tmp, "settings.json"));
            foreach (var env in new[] { "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                                        "CLAUDE_CODE_USE_FOUNDRY" })
                Environment.SetEnvironmentVariable(env, null);
            Usage.StatusLine(snapshot);
            Check(Data.Read<List<Quota>>("claude-quota.json").Single().Used == 10, "Official Claude quota snapshot");
            Check(Usage.Valid(new[] { new Quota { Reset = 1 } }).Count == 0, "Expired quota omitted");
            Data.Pref.Language = "en";
            Data.Pref.Tokens = true;
            Data.Save();
            Data.Pref.Tool = "Codex";
            Data.Save();
            var note = new Note();
            var when = DateTime.Today.AddHours(19);
            Data.Book.Notes.Add(note);
            Data.Book.Tasks.Add(new Todo { Title = "Review", Note = note.Id, Due = when, Remind = when });
            Data.SaveTasks();
            Data.Load();
            Check(Data.Pref.Tokens && Data.Pref.Tool == "Codex", "Settings replace and reload");
            Check(Data.Book.Tasks[0].Due == when && Data.Book.Tasks[0].Note == Data.Book.Notes[0].Id,
                  "Reminder and pinned note round trip");
            var clip = new Clip { Title = "Design review", Kind = "Text", App = "Writer" };
            Check(Clips.Match(clip, "review", 0) && Clips.Match(clip, "dgv", 1) && Clips.Match(clip, "wri.er", 2) &&
                      !Clips.Match(clip, "[", 2),
                  "Clipboard search modes and invalid regex");
            Check(CaptureCanvas.Between(new Point(45, 29), new Point(10, 4)) == new Rectangle(10, 4, 36, 26),
                  "Inclusive reversed capture coordinates");
            var first=new Todo{Title="First"};var second=new Todo{Title="Second"};
            Data.Book=new TaskBook();Data.Book.Tasks.AddRange(new[]{first,second});Tasks.PinToDesktop(first);Tasks.PinToDesktop(second);
            Check(Data.Book.Notes.Count==1&&first.Note==second.Note&&Data.Book.Notes[0].Pinned,"One click creates and groups desktop notes");
            string id=first.Note;Tasks.PinToDesktop(first);Data.Load();
            Check(Data.Book.Notes.Count==1&&Data.Book.Tasks.All(task=>task.Note==id)&&Data.Book.Notes[0].Pinned,"Repeated pin keeps the same visible note after restart");
            Tasks.Unpin(Data.Book.Notes[0]);Data.Load();Check(!Data.Book.Notes[0].Pinned,"Unpin hides the group without losing tasks");
            Tasks.PinToDesktop(Data.Book.Tasks[0]);Check(Data.Book.Notes.Count==1&&Data.Book.Notes[0].Pinned,"Reopen previously unpinned group");
            CheckTaskbarReadout();CheckArtwork();CheckButtonOutlines();
            if(Environment.OSVersion.Platform==PlatformID.Win32NT)WindowsControls();
            Console.WriteLine(passed + " checks passed");
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e);
            return 1;
        }
        finally
        {
            Directory.Delete(tmp, true);
        }
    }
}
