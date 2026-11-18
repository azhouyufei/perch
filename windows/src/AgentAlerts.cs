using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace DeskToys
{
sealed class AgentNotice : Form
{
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; }
    }
    readonly Stream art;
    readonly PictureBox sprite;
    internal AgentNotice(AgentAlerts.Request item, Action dismiss)
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(375, 118);
        BackColor = UI.Card;
        string animation = item.Reason == "permission" ? "alert" : "question";
        art = typeof(AgentNotice).Assembly.GetManifestResourceStream("Perch.avatar." + animation + ".gif");
        sprite = new PictureBox { Bounds = new Rectangle(6, 12, 72, 72), SizeMode = PictureBoxSizeMode.Zoom };
        if (art != null) sprite.Image = Image.FromStream(art);
        var title = UI.Label((item.Agent == "claude" ? "Claude Code" : "Codex") + " · " + item.Project, 11);
        var reason = UI.Label(item.Reason == "permission" ? Data.T("请回到会话确认权限", "Return to review a permission request") :
                                                            Data.T("请回到会话回答问题", "Return to the session to answer"));
        var tool = UI.Label(item.Tool ?? "", 9);
        int top = 12;
        foreach (var label in new[] {title, reason, tool}) {
            label.AutoSize = false; label.AutoEllipsis = true;
            label.Bounds = new Rectangle(82, top, 250, 23); top += 24; Controls.Add(label);
        }
        var close = UI.Btn("×", dismiss, Data.T("收起提醒", "Dismiss alert"));
        close.Bounds = new Rectangle(334, 6, 35, 35);
        if (!string.IsNullOrEmpty(item.Resume)) {
            var resume = UI.Btn(Data.T("复制恢复会话命令", "Copy resume command"), () => {
                try { Clipboard.SetText(item.Resume); } catch (System.Runtime.InteropServices.ExternalException e) { Data.Error(e); }
            });
            resume.AutoSize = false; resume.Bounds = new Rectangle(82, 81, 195, 31);
            Controls.Add(resume);
        }
        Controls.Add(sprite); Controls.Add(close);
    }
    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(area.Right - Width - 14, area.Bottom - Height - 14);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing && sprite != null) {
            var image = sprite.Image; sprite.Image = null;
            if (image != null) image.Dispose();
            if (art != null) art.Dispose();
        }
        base.Dispose(disposing);
    }
}
sealed class AgentAlerts : IDisposable
{
    public sealed class Request {
        public string Agent { get; set; }
        public string Project { get; set; }
        public string Reason { get; set; }
        public string Tool { get; set; }
        public string Resume { get; set; }
        public int Sequence { get; set; }
    }
    readonly Workspace owner;
    readonly HashSet<string> enabled = new HashSet<string>();
    readonly HashSet<int> dismissed = new HashSet<int>();
    List<Request> rows = new List<Request>();
    string helper;
    Process listener;
    AgentNotice notice;
    int showing;
    internal string Error { get; private set; }
    internal bool Enabled(string agent) { return enabled.Contains(agent); }
    internal AgentAlerts(Workspace owner) { this.owner = owner; }
    internal void Start()
    {
        try {
            var asm = typeof(AgentAlerts).Assembly;
            using (var input = asm.GetManifestResourceStream("Perch.Agent.exe")) {
                if (input == null) return;
                var folder = Path.Combine(Data.Root, "tools", asm.ManifestModule.ModuleVersionId.ToString("N"));
                Directory.CreateDirectory(folder);
                helper = Path.Combine(folder, "PerchAgent.exe");
                if (!File.Exists(helper)) {
                    var tmp = helper + "." + Guid.NewGuid().ToString("N");
                    try {
                        using (var file = File.Create(tmp)) input.CopyTo(file);
                        File.Move(tmp, helper);
                    } finally { if (File.Exists(tmp)) File.Delete(tmp); }
                }
            }
            foreach (var agent in new[] {"claude", "codex"}) {
                try { if (Command("status", agent)) enabled.Add(agent); }
                catch (Exception e) { Error = e.Message; }
            }
            Listen();
        } catch (Exception e) { Error = e.Message; }
    }
    ProcessStartInfo Info(string args)
    {
        return new ProcessStartInfo(helper, args) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, StandardOutputEncoding = Encoding.UTF8 };
    }
    bool Command(string action, string agent)
    {
        var info = Info(action + " " + agent); info.RedirectStandardError = true;
        using (var p = Process.Start(info)) {
            var value = p.StandardOutput.ReadToEnd(); var error = p.StandardError.ReadToEnd(); p.WaitForExit();
            if (p.ExitCode != 0) throw new IOException(error.Trim());
            return value.Trim() == "true";
        }
    }
    internal void Toggle(string agent, bool value)
    {
        Command(value ? "enable" : "disable", agent);
        if (value) enabled.Add(agent); else { enabled.Remove(agent); rows.RemoveAll(r => r.Agent == agent); }
        Error = null;
        if (enabled.Count == 0) Stop(); else Listen();
        Present();
    }
    void Listen()
    {
        if (listener != null || enabled.Count == 0) return;
        var info = Info("watch"); info.RedirectStandardInput = true;
        var p = new Process { StartInfo = info };
        p.OutputDataReceived += (s, e) => {
            if (owner.IsDisposed || !owner.IsHandleCreated) return;
            try {
                owner.BeginInvoke((Action)(() => {
                    if (listener != p) return;
                    if (e.Data == null) {
                        Stop(); Error = Data.T("监听已中断，请重新启用提醒。", "Listener stopped. Toggle alerts to reconnect.");
                    } else {
                        rows = Data.Json().Deserialize<List<Request>>(e.Data).Where(r => Enabled(r.Agent)).ToList();
                    }
                    Present();
                }));
            } catch (InvalidOperationException) { }
        };
        p.Start(); listener = p; p.BeginOutputReadLine();
    }
    internal Button PendingButton()
    {
        var button = UI.Btn(Data.T("查看待处理提醒", "Show pending requests"), () => { dismissed.Clear(); Present(); });
        Action update = () => button.Enabled = rows.Count > 0;
        update();
        Changed += update;
        button.Disposed += (s, e) => Changed -= update;
        return button;
    }
    event Action Changed;
    void Present()
    {
        if (Changed != null) Changed();
        dismissed.IntersectWith(rows.Select(r => r.Sequence));
        var r0 = rows.FirstOrDefault(r => !dismissed.Contains(r.Sequence));
        if (notice != null && r0 != null && showing == r0.Sequence) return;
        if (notice != null) { notice.Dispose(); notice = null; }
        if (r0 == null) return;
        showing = r0.Sequence;
        notice = new AgentNotice(r0, () => { dismissed.Add(r0.Sequence); Present(); });
        notice.Show();
    }
    void Stop()
    {
        var p = listener; listener = null;
        if (p != null) { try { p.StandardInput.Close(); } finally { p.Dispose(); } }
        rows.Clear(); dismissed.Clear();
    }
    public void Dispose() { Stop(); if (notice != null) notice.Dispose(); }
}
}
