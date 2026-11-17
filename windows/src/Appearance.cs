using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace DeskToys {
internal static class Appearance {
    internal static int Px(Control control,int value) {
        return Math.Max(1,(int)Math.Round(value*control.DeviceDpi/96.0));
    }
    internal static void Round(Control control,int radius) {
        Action apply=delegate {
            int diameter=Math.Min(Math.Min(control.Width,control.Height),Px(control,2*radius));
            if(diameter<2)return;
            using(var path=new GraphicsPath()){
                path.AddArc(0,0,diameter,diameter,180,90);
                path.AddArc(control.Width-diameter,0,diameter,diameter,270,90);
                path.AddArc(control.Width-diameter,control.Height-diameter,diameter,diameter,0,90);
                path.AddArc(0,control.Height-diameter,diameter,diameter,90,90);
                path.CloseFigure();var old=control.Region;control.Region=new Region(path);if(old!=null)old.Dispose();
            }
        };
        apply();control.SizeChanged+=delegate{apply();};
    }
    // ToolStrip can still be dispatching an item's Click after the menu starts closing.
    internal static void RetireMenu(ContextMenuStrip menu) {
        menu.BackColor=UI.Card;menu.ForeColor=UI.Ink;menu.Renderer=new MenuRenderer();
        menu.Closed+=delegate {
            var context=System.Threading.SynchronizationContext.Current;
            if(context!=null)context.Post(delegate(object unused){menu.Dispose();},null);
        };
    }
    sealed class MenuRenderer:ToolStripProfessionalRenderer {
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e){e.Graphics.Clear(UI.Card);}
        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e){}
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e){
            using(var brush=new SolidBrush(e.Item.Selected?UI.Raised:UI.Card))e.Graphics.FillRectangle(brush,new Rectangle(Point.Empty,e.Item.Size));
        }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e){
            e.TextColor=e.Item.Enabled?UI.Ink:UI.Sub;base.OnRenderItemText(e);
        }
    }
    internal static readonly Color Purple=Color.FromArgb(169,124,247),Teal=Color.FromArgb(49,192,184);
    internal static readonly Color[] Palette={UI.Blue,UI.Yellow,UI.Orange,UI.Green,Purple,Teal};
    internal static Bitmap Symbol(string key,Color color,int size) {
        return SymbolOn(key,color,size,UI.Card);
    }
    internal static Bitmap SymbolOn(string key,Color color,int size,Color background){
        if(key!="paint"&&Luminance(background)>0.5){
            // Stroke contrast on light cards. Keep the user's actual paint swatch unchanged.
            while(Contrast(color,background)<4.5)color=Color.FromArgb(color.R*9/10,color.G*9/10,color.B*9/10);
        }
        var image=new Bitmap(size,size);
        using(var g=Graphics.FromImage(image))using(var p=new Pen(color,2.15f))using(var b=new SolidBrush(color)){
            g.SmoothingMode=SmoothingMode.AntiAlias;g.ScaleTransform(size/24f,size/24f);
            p.StartCap=p.EndCap=LineCap.Round;p.LineJoin=LineJoin.Round;
            Action<float,float,float,float> line=(a,c,d,e)=>g.DrawLine(p,a,c,d,e);
            Action<float,float,float,float> box=(x,y,w,h)=>g.DrawRectangle(p,x,y,w,h);
            switch(key){
            case "region":line(3,9,3,4);line(3,4,9,4);line(15,4,21,4);line(21,4,21,9);line(21,15,21,20);line(21,20,15,20);line(9,20,3,20);line(3,20,3,15);break;
            case "window":box(3,4,18,15);line(4,9,20,9);g.FillEllipse(b,5,6,2,2);break;
            case "display":box(2,4,20,14);line(12,18,12,21);line(8,21,16,21);break;
            case "pin":
                g.DrawPolygon(p,new[]{new Point(9,3),new Point(18,3),new Point(16,7),new Point(16,11),new Point(19,15),new Point(8,15),new Point(11,11),new Point(11,7)});
                line(13.5f,15,13.5f,21);break;
            case "trash":line(4,6,20,6);line(9,3,15,3);g.DrawLines(p,new[]{new Point(6,7),new Point(7,20),new Point(17,20),new Point(18,7)});line(10,10,10,16);line(14,10,14,16);break;
            case "folder":g.DrawPolygon(p,new[]{new Point(3,6),new Point(9,6),new Point(11,8),new Point(21,8),new Point(20,19),new Point(3,19)});break;
            case "more":foreach(int x in new[]{3,10,17})g.FillEllipse(b,x,10,4,4);break;
            case "plus":line(4,12,20,12);line(12,4,12,20);break;
            case "color":line(15,5,20,10);line(18,4,20,6);g.DrawPolygon(p,new[]{new Point(14,8),new Point(17,11),new Point(8,20),new Point(4,21),new Point(5,17)});break;
            case "gallery":box(3,7,16,13);line(7,4,22,4);line(22,4,22,16);line(6,17,10,13);line(10,13,13,16);line(13,16,16,12);g.FillEllipse(b,6,9,3,3);break;
            case "move":line(12,3,12,21);line(3,12,21,12);line(12,3,9,6);line(12,3,15,6);line(21,12,18,9);line(3,12,6,15);line(12,21,15,18);break;
            case "pen":g.DrawPolygon(p,new[]{new Point(4,20),new Point(5,15),new Point(16,4),new Point(20,8),new Point(9,19)});line(14,7,17,10);break;
            case "arrow":line(4,20,20,4);line(11,4,20,4);line(20,4,20,13);break;
            case "rect":box(3,5,18,14);break;case "cover":g.FillRectangle(b,3,5,18,14);break;
            case "circle":g.DrawEllipse(p,4,4,16,16);break;case "ellipse":g.DrawEllipse(p,2,6,20,12);break;
            case "text":line(4,5,20,5);line(4,5,4,8);line(20,5,20,8);line(12,5,12,20);line(9,20,15,20);break;
            case "mosaic":for(int j=0;j<4;j++)for(int i=0;i<4;i++)if((i+j)%2==0)g.FillRectangle(b,4+i*4,4+j*4,4,4);box(3,3,17,17);break;
            case "width":for(int i=0;i<3;i++)g.FillRectangle(b,3,4+i*6,18,1+i);break;
            case "paint":g.FillEllipse(b,4,4,16,16);using(var rim=new Pen(Color.Gray,1))g.DrawEllipse(rim,4,4,16,16);break;
            case "undo":g.DrawArc(p,4,7,15,13,205,275);line(3,11,4,5);line(3,11,9,11);break;
            case "copy":box(8,7,12,14);line(5,17,4,17);line(4,17,4,3);line(4,3,15,3);break;
            case "save":line(12,3,12,16);line(7,11,12,16);line(12,16,17,11);line(3,18,3,21);line(3,21,21,21);line(21,21,21,18);break;
            case "check":line(3,12,9,18);line(9,18,21,5);break;
            case "close":line(5,5,19,19);line(19,5,5,19);break;
            case "activity":line(2,13,7,13);line(7,13,10,5);line(10,5,14,19);line(14,19,17,11);line(17,11,22,11);break;
            case "memory":box(3,7,18,10);for(int i=5;i<20;i+=4){line(i,17,i,20);line(i,10,i,13);}break;
            case "up":case "down":int top=key=="up"?4:20;int delta=key=="up"?6:-6;line(12,4,12,20);line(6,top+delta,12,top);line(12,top,18,top+delta);break;
            case "usage":g.DrawArc(p,4,4,16,16,-90,292);g.DrawArc(p,8,8,8,8,-90,230);break;
            case "tasks":box(4,3,16,18);line(7,11,10,14);line(10,14,16,8);break;
            case "clipboard":box(5,5,14,16);box(9,3,6,4);break;
            case "settings":g.DrawEllipse(p,6,6,12,12);g.DrawEllipse(p,10,10,4,4);for(int i=0;i<8;i++){double a=i*Math.PI/4;line(12+6*(float)Math.Cos(a),12+6*(float)Math.Sin(a),12+9*(float)Math.Cos(a),12+9*(float)Math.Sin(a));}break;
            default:box(3,3,7,7);box(14,3,7,7);box(3,14,7,7);box(14,14,7,7);break;
            }
        }
        return image;
    }
    static double Luminance(Color color){
        Func<int,double> channel=v=>{double c=v/255d;return c<=0.04045?c/12.92:Math.Pow((c+0.055)/1.055,2.4);};
        return 0.2126*channel(color.R)+0.7152*channel(color.G)+0.0722*channel(color.B);
    }
    static double Contrast(Color a,Color b){double x=Luminance(a),y=Luminance(b);return (Math.Max(x,y)+0.05)/(Math.Min(x,y)+0.05);}
    internal static void ButtonIcon(Button button,string key,Color color,int size){
        Bitmap owned=null;
        Action refresh=delegate{
            int pixels=Px(button,size);
            if(owned!=null&&owned.Width==pixels)return;
            var next=Symbol(key,color,pixels);var old=owned;owned=next;button.Image=next;
            if(old!=null)old.Dispose();
        };
        refresh();button.DpiChangedAfterParent+=delegate{refresh();};
        button.Disposed+=delegate{if(owned!=null)owned.Dispose();};
    }
    internal static FlowLayoutPanel Segments(string[] labels,int chosen,Action<int> select){
        var row=UI.Row();row.BackColor=UI.Card;row.Padding=new Padding(2);Round(row,8);
        for(int i=0;i<labels.Length;i++){
            int item=i;var b=UI.Btn(labels[i],()=>{if(item!=chosen)select(item);});
            b.BackColor=i==chosen?UI.Raised:UI.Card;b.ForeColor=i==chosen?UI.Ink:UI.Sub;b.Margin=new Padding(1);row.Controls.Add(b);
        }
        return row;
    }
}
}
