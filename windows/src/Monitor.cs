using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace DeskToys
{
class ProcRow
{
    public string Name;
    public int Pid;
    public long Memory;
    public double Cpu = double.NaN, Up = double.NaN, Down = double.NaN;
}
class Sample
{
    public DateTime At = DateTime.Now;
    public double Pressure = double.NaN, Cpu = double.NaN, Memory = double.NaN, Up = double.NaN, Down = double.NaN,
                  Read = double.NaN, Write = double.NaN, Swap = double.NaN, Gpu = double.NaN;
    public long Used, Total, FreeDisk;
    public double[] Cores = new double[0];
    public string Interfaces = "", Power = "";
    public List<ProcRow> Processes = new List<ProcRow>();
    public Dictionary<string, List<string>> Sensors = new Dictionary<string, List<string>>();
    public double Metric(int i)
    {
        return new[] { Cpu, Memory, Up, Down, Read, Write, Gpu, Swap, Pressure }[i];
    }
}
class Sampler
{
    [StructLayout(LayoutKind.Sequential)]
    class Mem
    {
        public uint size = 64, percent;
        public ulong total, avail, page, freePage, virt, freeVirt, ext;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx([In, Out] Mem info);
    [DllImport("kernel32.dll")]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("ntdll.dll")]
    static extern int NtQuerySystemInformation(int kind, IntPtr info, int bytes, out int used);
    Dictionary<string, long[]> networks = new Dictionary<string, long[]>();
    Dictionary<int, Tuple<long, long>> procs = new Dictionary<int, Tuple<long, long>>();
    long[] oldCpu;
    long[][] oldCores;
    readonly Stopwatch clock = Stopwatch.StartNew();
    double previous, procPrevious;
    DateTime nextSlow = DateTime.MinValue;
    Sample slow = new Sample();
    readonly TcpCounters tcp = new TcpCounters();
    [DllImport("kernel32.dll")]
    static extern Microsoft.Win32.SafeHandles.SafeWaitHandle CreateMemoryResourceNotification(int type);
    [DllImport("kernel32.dll")]
    static extern bool QueryMemoryResourceNotification(Microsoft.Win32.SafeHandles.SafeWaitHandle handle,
                                                       out bool active);
    Microsoft.Win32.SafeHandles.SafeWaitHandle lowMemory, highMemory;
    double Pressure()
    {
        if (lowMemory == null)
        {
            lowMemory = CreateMemoryResourceNotification(0);
            highMemory = CreateMemoryResourceNotification(1);
        }
        bool low, high;
        if (lowMemory.IsInvalid || highMemory.IsInvalid || !QueryMemoryResourceNotification(lowMemory, out low) ||
            !QueryMemoryResourceNotification(highMemory, out high))
            return double.NaN;
        return low ? 2 : high ? 0 : 1;
    }
    static double Load(long[] now, long[] old)
    {
        if (old == null)
            return double.NaN;
        long total = now[1] + now[2] - old[1] - old[2];
        return total <= 0 ? double.NaN : Math.Max(0, Math.Min(100, 100.0 * (1 - (double)(now[0] - old[0]) / total)));
    }
    static List<Dictionary<string, object>> Query(string scope, string query)
    {
        var rows = new List<Dictionary<string, object>>();
        try
        {
            using (var s = new ManagementObjectSearcher(scope, query)) using (var result = s.Get())
            {
                foreach (ManagementBaseObject item in result)
                {
                    using (item)
                    {
                        var row = new Dictionary<string, object>();
                        foreach (var p in item.Properties)
                            row[p.Name] = p.Value;
                        rows.Add(row);
                    }
                }
            }
        }
        catch (ManagementException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
        catch (COMException)
        {
        }
        return rows;
    }
    static double Num(Dictionary<string, object> row, string k)
    {
        return row.ContainsKey(k) && row[k] != null ? Convert.ToDouble(row[k]) : double.NaN;
    }
    void Slow(bool detail)
    {
        var s = new Sample();
        var disk = Query(@"root\cimv2", "SELECT DiskReadBytesPersec,DiskWriteBytesPersec FROM " +
                                        "Win32_PerfFormattedData_PerfDisk_PhysicalDisk WHERE Name='_Total'")
                       .FirstOrDefault();
        if (disk != null)
        {
            s.Read = Num(disk, "DiskReadBytesPersec");
            s.Write = Num(disk, "DiskWriteBytesPersec");
        }
        var mem = Query(@"root\cimv2", "SELECT CurrentUsage FROM Win32_PageFileUsage");
        if (mem.Count > 0)
            s.Swap = mem.Sum(x => Num(x, "CurrentUsage")) * 1048576;
        if (detail)
        {
            var gpu = Query(@"root\cimv2",
                            "SELECT Name,UtilizationPercentage FROM " +
                            "Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine WHERE Name LIKE '%engtype_3D%'");
            if (gpu.Count > 0)
                s.Gpu = Math.Min(
                    100,
                    gpu.GroupBy(
                           x => Convert.ToString(x["Name"]).Split(new[] { "_luid_" }, StringSplitOptions.None).Last())
                        .Max(g => g.Sum(x => Num(x, "UtilizationPercentage"))));
            foreach (var scope in new[] { @"root\LibreHardwareMonitor", @"root\OpenHardwareMonitor" })
            {
                foreach (var row in Query(scope, "SELECT Name,SensorType,Value FROM Sensor"))
                {
                    var k = Convert.ToString(row["SensorType"]);
                    string unit;
                    k = k == "Clock" ? "Frequency" : k;
                    if (!new[] { "Temperature", "Power", "Voltage", "Fan", "Frequency" }.Contains(k) ||
                        row["Value"] == null)
                        continue;
                    unit = k == "Temperature" ? " °C"
                           : k == "Power"     ? " W"
                           : k == "Voltage"   ? " V"
                           : k == "Fan"       ? " RPM"
                                              : " MHz";
                    if (!s.Sensors.ContainsKey(k))
                        s.Sensors[k] = new List<string>();
                    s.Sensors[k].Add(row["Name"] + "   " + Num(row, "Value").ToString("0.#") + unit);
                }
                if (s.Sensors.Count > 0)
                    break;
            }
            if (!s.Sensors.ContainsKey("Frequency"))
            {
                var freqs = Query(@"root\cimv2", "SELECT Name,CurrentClockSpeed FROM Win32_Processor");
                if (freqs.Count > 0)
                    s.Sensors["Frequency"] =
                        freqs.Select(x => x["Name"] + "   " + x["CurrentClockSpeed"] + " MHz").ToList();
            }
            if (!s.Sensors.ContainsKey("Temperature"))
            {
                var temps =
                    Query(@"root\wmi", "SELECT InstanceName,CurrentTemperature FROM MSAcpi_ThermalZoneTemperature")
                        .Where(x => Num(x, "CurrentTemperature") > 0)
                        .Select(x => x["InstanceName"] + "   " +
                                     (Num(x, "CurrentTemperature") / 10 - 273.15).ToString("0.#") + " °C")
                        .ToList();
                if (temps.Count > 0)
                    s.Sensors["Temperature"] = temps;
            }
        }
        slow = s;
    }
    public Sample Read(bool detail)
    {
        double now = clock.Elapsed.TotalSeconds, dt = now - previous;
        var s = new Sample();
        long idle, kernel, user;
        if (GetSystemTimes(out idle, out kernel, out user))
        {
            var current = new[] { idle, kernel, user };
            s.Cpu = Load(current, oldCpu);
            oldCpu = current;
        }
        s.Pressure = Pressure();
        var mem = new Mem();
        if (GlobalMemoryStatusEx(mem))
        {
            s.Total = (long)mem.total;
            s.Used = (long)(mem.total - mem.avail);
            s.Memory = 100.0 * s.Used / s.Total;
        }
        var buf = Marshal.AllocHGlobal(48 * Math.Max(256, Environment.ProcessorCount));
        try
        {
            int used;
            if (NtQuerySystemInformation(8, buf, 48 * Math.Max(256, Environment.ProcessorCount), out used) == 0)
            {
                var cores = new long [used / 48][];
                s.Cores = new double[cores.Length];
                for (int i = 0; i < cores.Length; i++)
                {
                    int off = 48 * i;
                    cores[i] = new[] { Marshal.ReadInt64(buf, off), Marshal.ReadInt64(buf, off + 8),
                                       Marshal.ReadInt64(buf, off + 16) };
                    s.Cores[i] = Load(cores[i], oldCores != null && i < oldCores.Length ? oldCores[i] : null);
                }
                oldCores = cores;
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
        var net = new Dictionary<string, long[]>();
        var ips = new List<string>();
        double up = 0, down = 0;
        bool matched = false;
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces().Where(
                     n => n.OperationalStatus == OperationalStatus.Up &&
                          n.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                          n.NetworkInterfaceType != NetworkInterfaceType.Tunnel))
        {
            try
            {
                var io = nic.GetIPStatistics();
                var pair = new[] { io.BytesSent, io.BytesReceived };
                long[] old;
                if (networks.TryGetValue(nic.Id, out old) && dt > 0 && pair[0] >= old[0] && pair[1] >= old[1])
                {
                    up += (pair[0] - old[0]) / dt;
                    down += (pair[1] - old[1]) / dt;
                    matched = true;
                }
                net[nic.Id] = pair;
                foreach (var a in nic.GetIPProperties().UnicastAddresses.Where(a => a.Address.AddressFamily ==
                                                                                    AddressFamily.InterNetwork))
                    ips.Add(nic.Name + "  " + a.Address);
            }
            catch (NetworkInformationException)
            {
            }
        }
        networks = net;
        if (matched)
        {
            s.Up = up;
            s.Down = down;
        }
        s.Interfaces = string.Join("  ·  ", ips);
        previous = now;
        if (now > 0 && DateTime.UtcNow >= nextSlow)
        {
            Slow(detail);
            nextSlow = DateTime.UtcNow.AddSeconds(detail ? 8 : 30);
        }
        s.Read = slow.Read;
        s.Write = slow.Write;
        s.Sensors = slow.Sensors;
        s.Swap = slow.Swap;
        s.Gpu = slow.Gpu;
        try
        {
            s.FreeDisk = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory)).AvailableFreeSpace;
            var power = SystemInformation.PowerStatus;
            s.Power = power.PowerLineStatus.ToString() + (power.BatteryLifePercent >= 0 && power.BatteryLifePercent <= 1
                                                              ? " · " + power.BatteryLifePercent.ToString("P0")
                                                              : "");
        }
        catch (IOException)
        {
        }
        if (detail)
        {
            var current = new Dictionary<int, Tuple<long, long>>();
            var traffic = tcp.Read(now);
            foreach (var p in Process.GetProcesses())
            {
                using (p)
                try
                {
                    var row = new ProcRow { Pid = p.Id, Name = p.ProcessName, Memory = p.PrivateMemorySize64 };
                    var cpu = p.TotalProcessorTime.Ticks;
                    var birth = p.StartTime.Ticks;
                    Tuple<long, long> old;
                    if (procs.TryGetValue(p.Id, out old) && old.Item2 == birth && now > procPrevious)
                        row.Cpu = Math.Max(0, (cpu - old.Item1) / 1e7 / (now - procPrevious) * 100);
                    current[p.Id] = Tuple.Create(cpu, birth);
                    double[] rate;
                    if (traffic.TryGetValue(p.Id, out rate))
                    {
                        row.Up = rate[0];
                        row.Down = rate[1];
                    }
                    s.Processes.Add(row);
                }
                catch (System.ComponentModel.Win32Exception)
                {
                }
                catch (InvalidOperationException)
                {
                }
            }
            procs = current;
            procPrevious = now;
        }
        else
        {
            procs.Clear();
            tcp.Reset();
        }
        return s;
    }
}
// Read existing per-connection TCP EStats. Unavailable counters stay unknown.
class TcpCounters
{
    [DllImport("iphlpapi.dll")]
    static extern uint GetExtendedTcpTable(IntPtr p, ref int size, bool sort, int family, int cls, int reserved);
    [DllImport("iphlpapi.dll")]
    static extern uint GetPerTcpConnectionEStats(IntPtr row, int type, [Out] byte[] rw, int rwVersion, int rwSize,
                                                 IntPtr ros, int rosVersion, int rosSize, [Out] byte[] rod,
                                                 int rodVersion, int rodSize);
    Dictionary<string, long[]> old = new Dictionary<string, long[]>();
    double prev;
    public void Reset()
    {
        old.Clear();
        prev = 0;
    }
    public Dictionary<int, double[]> Read(double time)
    {
        var rates = new Dictionary<int, double[]>();
        int bytes = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref bytes, false, 2, 5, 0);
        if (bytes <= 0)
            return rates;
        IntPtr table = Marshal.AllocHGlobal(bytes);
        var next = new Dictionary<string, long[]>();
        try
        {
            if (GetExtendedTcpTable(table, ref bytes, false, 2, 5, 0) != 0)
                return rates;
            for (int i = 0; i < Marshal.ReadInt32(table); i++)
            {
                var r = IntPtr.Add(table, 4 + i * 24);
                if (Marshal.ReadInt32(r) != 5 || (Marshal.ReadInt32(r, 12) & 255) == 127)
                    continue;
                var rw = new byte[4];
                var rod = new byte[96];
                if (GetPerTcpConnectionEStats(r, 1, rw, 0, 1, IntPtr.Zero, 0, 0, rod, 0, 96) != 0 || rw[0] == 0)
                    continue;
                int pid = Marshal.ReadInt32(r, 20);
                string k = pid + "/" + Marshal.ReadInt64(r, 4) + "/" + Marshal.ReadInt64(r, 12);
                var counters = new[] { BitConverter.ToInt64(rod, 0), BitConverter.ToInt64(rod, 16) };
                next[k] = counters;
                long[] last;
                if (time > prev && old.TryGetValue(k, out last))
                {
                    double[] rate;
                    if (!rates.TryGetValue(pid, out rate))
                        rates[pid] = rate = new double[2];
                    for (int j = 0; j < 2; j++)
                        rate[j] += Math.Max(0, counters[j] - last[j]) / (time - prev);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(table);
        }
        old = next;
        prev = time;
        return rates;
    }
}
class Plot : Control
{
    public List<Sample> Samples = new List<Sample>();
    public int Metric, Seconds = 120;
    public bool Heat;
    public Color Accent = UI.Blue;
    public Plot()
    {
        DoubleBuffered = true;
        BackColor = UI.Card;
        Height = 150;
        Width = 550;
        MouseMove += (s, e) =>
        {
            var pts = Window();
            if (pts.Count == 0)
                return;
            var p = pts[Math.Min(pts.Count - 1, Math.Max(0, e.X) * pts.Count / Math.Max(1, Width))];
            UI.Tips.SetToolTip(this, p.At.ToString("T") + "  " + Format(p.Metric(Metric), Metric));
        };
    }
    List<Sample> Window()
    {
        return Samples.Where(x => x.At >= DateTime.Now.AddSeconds(-Seconds)).ToList();
    }
    public static string Format(double v, int m)
    {
        return double.IsNaN(v)              ? "—"
               : m == 8                     ? (v == 2   ? Data.T("高", "High")
                                               : v == 1 ? Data.T("中", "Medium")
                                                        : Data.T("低", "Low"))
               : m == 7                     ? Data.Size(v)
               : m == 0 || m == 1 || m == 6 ? v.ToString("0.#") + "%"
                                            : Data.Size(v) + "/s";
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var data = Window();
        if (data.Count == 0)
            return;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (Heat)
        {
            int n = data.Last().Cores.Length;
            if (n == 0)
                return;
            var groups = data.GroupBy(x => x.At.Ticks / (TimeSpan.TicksPerSecond * 4)).ToArray();
            float h = (float)Height / n, w = (float)(Width - 42) / Math.Max(30, groups.Length);
            for (int i = 0; i < n; i++)
            {
                if (h > 11)
                    g.DrawString("#" + i, Font, Brushes.Gray, 0, i * h);
                for (int j = 0; j < groups.Length; j++)
                {
                    int index = i;
                    double v = groups[j]
                                   .Where(p => p.Cores.Length > index && !double.IsNaN(p.Cores[index]))
                                   .Select(p => p.Cores[index])
                                   .DefaultIfEmpty(0)
                                   .Max();
                    using (var b = new SolidBrush(
                               Color.FromArgb(40 + (int)(Math.Min(v, 100) * 2.15), v > 84 ? UI.Orange : UI.Blue)))
                        g.FillRectangle(b, 40 + j * w, i * h, Math.Max(1, w - 2), Math.Max(1, h - 1));
                }
            }
            return;
        }
        var vals = data.Select(p => p.Metric(Metric)).Where(v => !double.IsNaN(v)).ToList();
        if (vals.Count < 2)
            return;
        double max = Metric == 8 ? 2 : Metric == 0 || Metric == 1 || Metric == 6 ? 100 : Math.Max(1, vals.Max());
        float bottom = Height - 5;
        var points =
            data.Where(p => !double.IsNaN(p.Metric(Metric)))
                .Select(p => new PointF(
                            Math.Max(0, Width - 1 - (float)((data.Last().At - p.At).TotalSeconds / Seconds) * Width),
                            bottom - (float)(p.Metric(Metric) / max) * (Height - 14)))
                .ToArray();
        using (var path = new GraphicsPath())
        {
            path.AddLines(points);
            path.AddLine(points.Last(), new PointF(points.Last().X, bottom));
            path.AddLine(new PointF(points.First().X, bottom), points.First());
            using (var fill = new LinearGradientBrush(ClientRectangle, Color.FromArgb(105, Accent),
                                                      Color.FromArgb(4, Accent), 90f)) g.FillPath(fill, path);
        }
        using (var pen = new Pen(Accent, 2)) g.DrawLines(pen, points);
    }
}
}
