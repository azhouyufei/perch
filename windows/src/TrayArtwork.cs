using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;

namespace DeskToys
{
    internal static class TrayArtwork
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string title);
        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr window);
        [DllImport("user32.dll")]
        private static extern int GetSystemMetricsForDpi(int metric, uint dpi);

        internal static int PixelSize()
        {
            try
            {
                uint dpi = GetDpiForWindow(FindWindow("Shell_TrayWnd", null));
                return Math.Max(16, Math.Min(64, GetSystemMetricsForDpi(49, dpi == 0 ? 96u : dpi)));
            }
            catch (EntryPointNotFoundException) { return 16; }
        }

        internal static string TokenBadge(long total)
        {
            string[] units = { "", "K", "M", "B", "T" };
            int unit = 0;
            while (total >= 1000 && unit < units.Length - 1) { total /= 1000; unit++; }
            return Math.Min(999, Math.Max(0, total)).ToString(CultureInfo.InvariantCulture) + units[unit];
        }

        // All glyphs share a 16-pixel design grid. Whole-pixel digit strokes survive at taskbar size.
        private const string Alphabet = "0123456789KMBT-";
        private static readonly string[] Digits = {
            "111101101101111","010110010010111","111001111100111","111001111001111",
            "101101111001001","111100111001111","111100111101111","111001010010010",
            "111101111101111","111101111001111","101110100110101","101111111101101",
            "110101110101110","111010010010010","000000111000000"
        };

        internal static Bitmap Draw(int size, string glyph, bool active)
        {
            var image = new Bitmap(size, size);
            using (var g = Graphics.FromImage(image))
            using (var face = new SolidBrush(Color.FromArgb(25,31,39)))
            using (var rim = new SolidBrush(Color.FromArgb(130,148,166)))
            using (var ink = new SolidBrush(active ? Color.FromArgb(255,214,88) : Color.FromArgb(244,249,255)))
            {
                g.ScaleTransform(size / 16f, size / 16f);
                g.FillRectangle(rim, 0, 0, 16, 16);
                g.FillRectangle(face, 1, 1, 14, 14);
                if (glyph == "traffic" || glyph == "awake" || glyph == "cpu")
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var pen = new Pen(ink, 1.6f) { LineJoin = LineJoin.Round, StartCap = LineCap.Round, EndCap = LineCap.Round })
                    {
                        if (glyph == "traffic")
                        {
                            g.DrawLines(pen, new[] { new Point(2,7), new Point(5,4), new Point(8,7) });
                            g.DrawLine(pen,5,5,5,12);
                            g.DrawLines(pen, new[] { new Point(8,9), new Point(11,12), new Point(14,9) });
                            g.DrawLine(pen,11,4,11,11);
                        }
                        else if (glyph == "awake")
                        {
                            g.DrawArc(pen, 9, 5, 4, 5, 265, 200);
                            g.DrawLines(pen, new[] { new Point(3,5),new Point(10,5),new Point(10,9),new Point(8,11),new Point(5,11),new Point(3,9),new Point(3,5) });
                            g.DrawLine(pen,3,13,12,13);
                        }
                        else
                            g.DrawLines(pen, new[] { new Point(2,9),new Point(5,9),new Point(7,4),new Point(9,12),new Point(11,7),new Point(14,7) });
                    }
                }
                else
                {
                    int width = -1;
                    foreach (char c in glyph) width += Digits[Alphabet.IndexOf(c)].Length / 5 + 1;
                    float sx = Math.Min(3, Math.Max(1, 15 / width)), left = (int)((16 - width * sx) / 2);
                    foreach (char c in glyph)
                    {
                        string pattern = Digits[Alphabet.IndexOf(c)]; int cols = pattern.Length / 5;
                        for (int row = 0; row < 5; row++)
                            for (int col = 0; col < cols; col++)
                                if (pattern[row * cols + col] == '1')
                                    g.FillRectangle(ink, left + col * sx, 3 + row * 2, sx, 2);
                        left += (cols + 1) * sx;
                    }
                }
            }
            return image;
        }
    }
}
