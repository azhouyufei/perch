using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Globalization;
using System.Threading;
using System.Windows.Forms;

namespace DeskToys
{
    // Compiled only into the documentation tool. Reuse the application's actual window,
    // layout and charts while omitting global hotkeys, clipboard monitoring and log scanning.
    sealed partial class Workspace
    {
        internal Workspace(List<UsageRow> exampleRows)
        {
            UI.Theme(this);
            Text = Data.AppName;
            ClientSize = new Size(1100, 760);
            AutoScaleMode = AutoScaleMode.Dpi;
            usage = exampleRows;
            scanning = true;
            for (int i = 0; i < 70; i++)
            {
                double wave = (1 + Math.Sin(i * 0.27)) / 2;
                latest = new Sample { At = DateTime.Now.AddSeconds(2 * (i - 69)), Cpu = 16 + 28 * wave,
                    Memory = 42, Used = 7200000000, Total = 17000000000, FreeDisk = 256000000000,
                    Up = 80000 + 300000 * wave, Down = 950000 + 1800000 * wave, Power = "AC power",
                    Processes = new List<ProcRow> { new ProcRow { Name = "Perch", Pid = 1000,
                        Cpu = 0.4, Memory = 32 * 1024 * 1024, Up = 0, Down = 0 } } };
                history.Add(latest);
            }
            BuildShell();
            Shown += delegate { Navigate(2); };
        }
        internal void CaptureTools(string output, string theme)
        {
            Action<Control, string> save = (control, name) => {
                Application.DoEvents();
                control.Refresh();
                using (var bitmap = new Bitmap(control.Width, control.Height))
                {
                    control.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                    bitmap.Save(Path.Combine(output, "windows-" + name + theme + ".png"), ImageFormat.Png);
                }
            };
            save(this, "");
            Navigate(0);
            save(this, "dashboard-");
            ShowPopup(1, true);
            save(popup, "network-panel-");
            ClosePopup();
            using (var menu = CreateTrayMenu(false))
            {
                menu.Show(this, new Point(12, 12));
                save(menu, "tray-menu-");
                menu.Close();
            }
            using (var note = new NoteWindow(Data.Book.Notes[0]))
            {
                note.Show();
                save(note, "note-");
            }
        }
    }

    class ScreenshotProgram
    {
        static List<UsageRow> SampleSessions()
        {
            var rows = new List<UsageRow>();
            int[] volume = { 19, 37, 28, 41, 55, 32, 66, 40, 58, 49, 25, 69, 39, 56 };
            for (int i = 0; i < 28; i++)
            {
                long input = volume[i % volume.Length] * 1250;
                rows.Add(new UsageRow {
                    Tool = "Codex", Project = "perch", Model = "Example model", Title = "Example session",
                    Session = "sample-" + i, Day = DateTime.Today.AddDays(i - 27).ToString("yyyy-MM-dd"),
                    Value = new Amount { Input = input, Output = input / 4, Cached = input / 3, Reason = input / 12 }
                });
            }
            return rows;
        }

        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 1) return 2;
            string output = args.Length == 1 ? Path.GetFullPath(args[0]) : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Perch screenshots");
            Directory.CreateDirectory(output);
            var temporary = Path.Combine(Path.GetTempPath(), "perch-screens-" + Guid.NewGuid());
            Directory.CreateDirectory(temporary);
            try
            {
                Data.Root = temporary;
                Data.Load();
                var sticker = new Note { Title = "Release checklist" };
                Data.Book.Notes.Add(sticker);
                foreach (string title in new[] { "Review the capture toolbar", "Check the keyboard shortcuts", "Write the release notes" })
                    Data.Book.Tasks.Add(new Todo { Title = title, Note = sticker.Id });
                Data.Pref.Language = "en";
                Data.Pref.Tool = "Codex";
                Thread.CurrentThread.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
                Thread.CurrentThread.CurrentUICulture = CultureInfo.GetCultureInfo("en-US");
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                foreach (string theme in new[] { "light", "dark" })
                {
                    Data.Pref.Theme = theme;
                    using (var window = new Workspace(SampleSessions()))
                    {
                        window.Show();
                        window.CaptureTools(output, theme);
                    }
                }
                return 0;
            }
            finally { Directory.Delete(temporary, true); }
        }
    }
}
