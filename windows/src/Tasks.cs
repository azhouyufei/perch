using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DeskToys
{
static class Tasks
{
    public static event Action Changed;
    public static void Commit()
    {
        Data.SaveTasks();
        if(Changed!=null)Changed();
    }
    public static Note NewNote()
    {
        var n = new Note { Title = Data.T("待办清单", "Task list") };
        Data.Book.Notes.Add(n);
        return n;
    }
    public static void Pin(Todo task, Note note)
    {
        note.Pinned = true;
        task.Note = note.Id;
        Commit();
    }
    public static void Unpin(Note note)
    {
        note.Pinned = false;
        Commit();
    }
    public static void Check(Todo task)
    {
        task.Done = !task.Done;
        UpdateReminder(task);
        Commit();
    }
    public static void Delete(Todo task)
    {
        Data.Book.Tasks.Remove(task);
        Schedule(task, true);
        Commit();
    }
    public static Note PinToDesktop(Todo task)
    {
        if (task.Done) return null;
        var note = Data.Book.Notes.FirstOrDefault(n => n.Id == task.Note)
                   ?? Data.Book.Notes.FirstOrDefault(n => n.Pinned) ?? NewNote();
        if (!note.Pinned || task.Note != note.Id) Pin(task, note);
        return note;
    }

    internal static int Choose(Control anchor, string caption, string[] choices)
    {
        if (choices.Length == 0) return -1;
        using (var dialog = new Form { Text=caption, ClientSize=new Size(340,230), MinimizeBox=false,
                MaximizeBox=false, FormBorderStyle=FormBorderStyle.FixedDialog, ShowInTaskbar=false })
        {
            UI.Theme(dialog); dialog.StartPosition=FormStartPosition.CenterParent;
            var list=new ListBox { Dock=DockStyle.Fill, BackColor=UI.Card, ForeColor=UI.Ink, BorderStyle=BorderStyle.None, IntegralHeight=false };
            list.Items.AddRange(choices);list.SelectedIndex=0;
            var ok=UI.Btn(Data.T("确定","OK"),()=>dialog.DialogResult=DialogResult.OK);
            var cancel=UI.Btn(Data.T("取消","Cancel"),()=>dialog.DialogResult=DialogResult.Cancel);
            var actions=UI.Row(ok,cancel);actions.Dock=DockStyle.Bottom;
            list.DoubleClick+=(s,e)=>{if(list.SelectedIndex>=0)dialog.DialogResult=DialogResult.OK;};
            dialog.Padding=new Padding(12);dialog.Controls.Add(list);dialog.Controls.Add(actions);
            dialog.AcceptButton=ok;dialog.CancelButton=cancel;
            return dialog.ShowDialog(anchor.FindForm())==DialogResult.OK?list.SelectedIndex:-1;
        }
    }
    public static void ChooseNote(Control anchor, Todo task)
    {
        var notes=Data.Book.Notes.ToArray();var options=notes.Select(n=>n.Title).ToList();
        options.Add(Data.T("新建独立便签","New note"));
        if(task.Note!="")options.Add(Data.T("从便签移除","Remove from note"));
        int choice=Choose(anchor,Data.T("选择便签","Choose note"),options.ToArray());
        if(choice<0)return;
        if(choice==notes.Length+1){task.Note="";Commit();return;}
        Pin(task,choice==notes.Length?NewNote():notes[choice]);
    }
    public static void Edit(Todo task, Note fixedNote = null)
    {
        bool fresh = task == null;
        if (fresh)
            task = new Todo();
        using (var f = new Form { Text = fresh ? Data.T("新建待办", "New task") : Data.T("编辑待办", "Edit task"),
                                  ClientSize = new Size(485, 355), FormBorderStyle = FormBorderStyle.FixedDialog,
                                  MaximizeBox = false, MinimizeBox = false, TopMost = true })
        {
            UI.Theme(f);
            var box = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
                                            WrapContents = false, Padding = new Padding(12) };
            f.Controls.Add(box);
            var title = new TextBox { Width = 443, Text = task.Title };
            var detail = new TextBox { Width = 443, Height = 62, Multiline = true, Text = task.Detail };
            box.Controls.Add(UI.Label(Data.T("标题", "Title")));
            box.Controls.Add(title);
            box.Controls.Add(UI.Label(Data.T("备注", "Notes")));
            box.Controls.Add(detail);
            DateTimePicker due, rem;
            var dueOn = DateRow(box, Data.T("截止时间", "Due date"), task.Due, out due);
            var remOn = DateRow(box, Data.T("定时提醒", "Reminder"), task.Remind, out rem);
            var pins = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 240 };
            pins.Items.Add(Data.T("不固定", "Not pinned"));
            foreach (var n in Data.Book.Notes)
                pins.Items.Add(n.Title);
            pins.Items.Add(Data.T("新建独立便签", "New note"));
            pins.SelectedIndex = 1 + Data.Book.Notes.FindIndex(n => n.Id == (fixedNote==null?task.Note:fixedNote.Id));
            box.Controls.Add(UI.Row(UI.Label(Data.T("桌面便签", "Desktop note")), pins));
            var save = UI.Btn(Data.T("保存", "Save"),
                              () =>
                              {
                                  if (string.IsNullOrWhiteSpace(title.Text))
                                  {
                                      title.Focus();
                                      return;
                                  }
                                  if (remOn.Checked && rem.Value != task.Remind && rem.Value <= DateTime.Now)
                                  {
                                      MessageBox.Show(Data.T("请选择未来的提醒时间", "Choose a future reminder time"));
                                      return;
                                  }
                                  task.Title = title.Text.Trim();
                                  task.Detail = detail.Text;
                                  task.Due = dueOn.Checked  ? (DateTime ?) due.Value: null;
                                  var alarm = remOn.Checked ? (DateTime ?) rem.Value: null;
                                  if (task.Remind != alarm)
                                      task.Notified = false;
                                  task.Remind = alarm;
                                  var target = pins.SelectedIndex == pins.Items.Count - 1 ? NewNote()
                                               : pins.SelectedIndex > 0 ? Data.Book.Notes[pins.SelectedIndex - 1]
                                                                        : null;
                                  task.Note = target==null?"":target.Id;
                                  if (target != null && (fixedNote != null || fresh || pins.SelectedIndex != 0))
                                      target.Pinned = true;
                                  if (fresh)
                                      Data.Book.Tasks.Add(task);
                                  Commit();
                                  UpdateReminder(task);
                                  f.DialogResult = DialogResult.OK;
                              });
            box.Controls.Add(save);
            f.AcceptButton = save;
            f.ShowDialog();
        }
    }
    static CheckBox DateRow(FlowLayoutPanel box, string label, DateTime? current, out DateTimePicker value)
    {
        var ck = new CheckBox { Text = label, Checked = current.HasValue, AutoSize = true,
                                Margin = new Padding(4, 8, 4, 4) };
        var picker =
            new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "yyyy-MM-dd HH:mm", Width = 164,
                                 Value = current ?? DateTime.Now.AddHours(1), Enabled = current.HasValue };
        ck.CheckedChanged += (s, e) => picker.Enabled = ck.Checked;
        box.Controls.Add(UI.Row(ck, picker));
        value = picker;
        return ck;
    }
    public static bool UpdateReminder(Todo task)
    {
        return Schedule(task, task.Done || !task.Remind.HasValue || task.Notified || task.Remind <= DateTime.Now);
    }
    // A per-user Task Scheduler time trigger also fires while the main workspace is closed.
    static bool Schedule(Todo task, bool remove)
    {
        try
        {
            dynamic service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true));
            service.Connect();
            dynamic root = service.GetFolder("\\");
            var name = "DeskToys-Reminder-" + task.Id;
            if (remove)
            {
                try
                {
                    root.DeleteTask(name, 0);
                }
                catch (System.Runtime.InteropServices.COMException)
                {
                }
                return true;
            }
            dynamic def = service.NewTask(0);
            def.RegistrationInfo.Description = "Perch reminder";
            def.Settings.StartWhenAvailable = true;
            def.Settings.DisallowStartIfOnBatteries = false;
            def.Settings.StopIfGoingOnBatteries = false;
            def.Settings.ExecutionTimeLimit = "PT30M";
            dynamic trigger = def.Triggers.Create(1);
            trigger.StartBoundary = task.Remind.Value.ToString("yyyy-MM-ddTHH:mm:ss");
            dynamic action = def.Actions.Create(0);
            action.Path = Application.ExecutablePath;
            action.Arguments = "--remind " + task.Id + " " + new DateTimeOffset(task.Remind.Value).ToUnixTimeSeconds();
            root.RegisterTaskDefinition(name, def, 6, null, null, 3, null);
            return true;
        }
        catch (Exception ex)
        {
            if (!remove)
                MessageBox.Show(
                    Data.T("关闭应用后的提醒未能注册：", "Could not schedule the reminder for when Perch is closed: ") +
                        ex.Message,
                    Data.AppName);
            return false;
        }
    }
    internal static void Deliver(string id, string ticks)
    {
        Guid parsed;
        long at;
        if (!Guid.TryParse(id, out parsed) || !long.TryParse(ticks, out at))
            return;
        var t = Data.Book.Tasks.FirstOrDefault(x => x.Id == id && !x.Done && x.Remind.HasValue &&
                                                    new DateTimeOffset(x.Remind.Value).ToUnixTimeSeconds() == at);
        if (t == null)
            return;
        MessageBox.Show(t.Title + Environment.NewLine + t.Detail, Data.AppName + " · " + Data.T("待办提醒", "Reminder"),
                        MessageBoxButtons.OK, MessageBoxIcon.Information, MessageBoxDefaultButton.Button1,
                        MessageBoxOptions.DefaultDesktopOnly);
    }
}
class NoteWindow : Form
{
    readonly Note note;
    readonly FlowLayoutPanel rows;
    readonly TextBox add;
    readonly Label title;
    bool peeling;
    readonly Color paper = Color.FromArgb(255, 237, 179), ink = Color.FromArgb(58, 46, 28);
    public NoteWindow(Note n)
    {
        note = n;
        UI.Theme(this);
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        Appearance.Round(this,10);
        BackColor = paper;
        ForeColor = ink;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(Math.Max(265, n.Width), Math.Max(180, n.Height));
        Location = n.X != int.MinValue && Screen.AllScreens.Any(
                                              s => s.WorkingArea.IntersectsWith(new Rectangle(n.X, n.Y, Width, Height)))
                       ? new Point(n.X, n.Y)
                       : new Point(Screen.PrimaryScreen.WorkingArea.Right - Width - 35,
                                   Screen.PrimaryScreen.WorkingArea.Top + 45 + 20 * (Data.Book.Notes.IndexOf(n) % 5));
        var bounds=Screen.FromRectangle(Bounds).WorkingArea;
        Location=new Point(Math.Max(bounds.Left,Math.Min(Left,bounds.Right-Width)),Math.Max(bounds.Top,Math.Min(Top,bounds.Bottom-Height)));
        var top = new Panel { Dock = DockStyle.Top, Height = 48, BackColor = paper };
        var grip = new Panel { Dock = DockStyle.Top, Height = 12, Cursor = Cursors.SizeAll };
        grip.MouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                Native.Drag(this);
                SavePosition();
            }
        };
        grip.Paint+=delegate(object sender,PaintEventArgs e){using(var brush=new SolidBrush(Color.FromArgb(214,178,106)))e.Graphics.FillRectangle(brush,(grip.Width-48)/2,5,48,3);};
        top.Controls.Add(grip);
        title = new Label { Left = 11,   Top = 19,          Width = Width - 67,
                            Height = 26, Text = note.Title, Font = new Font("Segoe UI", 12, FontStyle.Bold) };
        title.Click += (s, e) =>
        {
            var name = UI.Prompt(Data.T("便签名称", "Note name"), note.Title);
            if (!string.IsNullOrWhiteSpace(name))
            {
                note.Title = name.Trim();
                Tasks.Commit();
            }
        };
        top.Controls.Add(title);
        var pin = PaperButton("pin", Data.T("取消固定整张便签", "Unpin this note"), () => Tasks.Unpin(note));
        pin.Location=new Point(Width-pin.Width-Appearance.Px(this,6),Appearance.Px(this,9));pin.Anchor=AnchorStyles.Top|AnchorStyles.Right;top.Height=pin.Bottom+Appearance.Px(this,5);
        top.Controls.Add(pin);
        var bottom = new TableLayoutPanel { Dock=DockStyle.Bottom, ColumnCount=2, RowCount=1, Padding=new Padding(Appearance.Px(this,7)), BackColor=paper };
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        bottom.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        add = new TextBox { Anchor=AnchorStyles.Left|AnchorStyles.Right, Margin=new Padding(0,0,Appearance.Px(this,6),0), BorderStyle=BorderStyle.FixedSingle };
        var plus = PaperButton("plus", Data.T("加入已有待办", "Add existing task"),
                               () =>
                               {
                                   var available=Data.Book.Tasks.Where(x=>!x.Done && x.Note!=n.Id).ToArray();
                                   if(available.Length==0){MessageBox.Show(this,Data.T("没有其他待办","No other tasks"),Text);return;}
                                   int picked=Tasks.Choose(this,Data.T("加入已有待办","Add existing task"),available.Select(t=>t.Title).ToArray());
                                   if(picked>=0)Tasks.Pin(available[picked],n);
                               });
        plus.Anchor=AnchorStyles.Right;plus.Margin=Padding.Empty;
        bottom.Height=Math.Max(add.PreferredHeight,plus.Height)+bottom.Padding.Vertical;
        bottom.Controls.Add(add,0,0);bottom.Controls.Add(plus,1,0);
        UI.Tips.SetToolTip(add, Data.T("输入待办后按回车", "Type a task and press Enter"));
        add.KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Enter && !string.IsNullOrWhiteSpace(add.Text))
            {
                e.SuppressKeyPress = true;
                Data.Book.Tasks.Add(new Todo { Title = add.Text.Trim(), Note = n.Id });
                add.Clear();
                Tasks.Commit();
            }
        };
        rows = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
                                     AutoScroll = true };
        rows.ClientSizeChanged+=delegate{FitRows();};
        Controls.Add(rows);
        Controls.Add(bottom);
        Controls.Add(top);
        RefreshRows();
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr window,StringBuilder name,int capacity);
    [DllImport("user32.dll")]static extern bool ShowWindow(IntPtr window,int command);
    [DllImport("user32.dll")]static extern bool SetWindowPos(IntPtr window,IntPtr order,int x,int y,int width,int height,uint flags);
    internal static bool DesktopIsForeground(){
        var name=new StringBuilder(64);GetClassName(Native.GetForegroundWindow(),name,name.Capacity);
        string kind=name.ToString();return kind=="Progman"||kind=="WorkerW";
    }
    internal void ShowOnDesktop(){
        if(peeling||IsDisposed||!IsHandleCreated)return;
        ShowWindow(Handle,4); // SW_SHOWNOACTIVATE restores a minimized tool window.
        SetWindowPos(Handle,new IntPtr(-1),0,0,0,0,0x0053); // Show on top without changing focus, size or position.
    }
    internal void Reveal()
    {
        if (WindowState == FormWindowState.Minimized) WindowState=FormWindowState.Normal;
        if (!Visible) Show();
        TopMost=true;
        BringToFront();
        Activate();
    }
    Button PaperButton(string text, string help, Action action)
    {
        var b = UI.IconButton(text,ink,action,help);
        b.AutoSize = false;
        b.Size = new Size(Appearance.Px(this,40),Appearance.Px(this,32));
        b.BackColor = Color.FromArgb(247, 222, 154);
        b.ForeColor = ink;
        return b;
    }
    void SavePosition()
    {
        note.X = Left;
        note.Y = Top;
        note.Width = Width;
        note.Height = Height;
        Data.SaveTasks();
    }
    public void RefreshRows()
    {
        title.Text = note.Title;
        UI.Clear(rows);
        foreach (var t in Data.Book.Tasks.Where(x => x.Note == note.Id && !x.Done))
        {
            var check = PaperButton("circle", Data.T("完成", "Complete"), () => Tasks.Check(t));
            var body = new Label { Width = Width - 130,
                                   Height = 44,
                                   Text = t.Title + (t.Due.HasValue ? "\n" + t.Due.Value.ToString("g") : ""),
                                   AutoEllipsis = true,
                                   ForeColor = ink,
                                   Cursor = Cursors.IBeam,
                                   TextAlign = ContentAlignment.MiddleLeft };
            body.Click += (s, e) => EditTitle(t, body);
            UI.Tips.SetToolTip(body, t.Detail);
            var more =
                PaperButton("more", Data.T("编辑截止时间与提醒", "Edit deadline and reminder"), () => Tasks.Edit(t, note));
            var row=new TableLayoutPanel{ColumnCount=3,RowCount=1,Height=Math.Max(Appearance.Px(this,42),check.Height+6),
                Margin=new Padding(2,1,2,1)};
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            row.RowStyles.Add(new RowStyle(SizeType.Percent,100));check.Anchor=more.Anchor=AnchorStyles.None;
            body.Dock=DockStyle.Fill;row.Controls.Add(check,0,0);row.Controls.Add(body,1,0);row.Controls.Add(more,2,0);
            rows.Controls.Add(row);FitRows();
        }
    }
    void FitRows(){
        int width=Math.Max(1,rows.ClientSize.Width-SystemInformation.VerticalScrollBarWidth-6);
        foreach(Control row in rows.Controls)if(row.Width!=width)row.Width=width;
    }
    void EditTitle(Todo task, Label label)
    {
        var editor=new TextBox{Dock=DockStyle.Fill,Text=task.Title};label.Controls.Add(editor);
        bool finished = false;
        Action<bool> finish = save =>
        {
            if (finished || editor.IsDisposed)
                return;
            finished = true;
            var name = editor.Text.Trim();
            bool changed = save && name != "" && name != task.Title;
            if (changed)
                task.Title = name;
            editor.Dispose();
            label.Show();
            if (changed)
                Tasks.Commit();
        };
        editor.KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Escape)
            {
                e.SuppressKeyPress = true;
                finish(e.KeyCode == Keys.Enter);
            }
        };
        editor.Leave += (s, e) => finish(true);
        editor.Focus();
        editor.SelectAll();
    }
    public void Peel()
    {
        if (peeling)
            return;
        peeling = true;
        Enabled = false;
        var timer = new Timer { Interval = 20 };
        timer.Tick += (s, e) =>
        {
            if (IsDisposed || Opacity <= 0.16)
            {
                timer.Dispose();
                if (!IsDisposed)
                    Close();
            }
            else
            {
                Opacity -= 0.12;
                Top -= 2;
                Left++;
            }
        };
        timer.Start();
    }
}
}
