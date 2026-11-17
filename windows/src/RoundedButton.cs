using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace DeskToys
{
    // Paint the outline and keyboard focus indicator on the same inset curve.
    // The rectangular Windows default-button border otherwise intersects rounded window regions.
    internal sealed class RoundedButton : Button
    {
        private bool hovering, pressed;

        internal RoundedButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
        }
        static Color Mix(Color a, Color b, float amount)
        {
            return Color.FromArgb((int)(a.R+(b.R-a.R)*amount),(int)(a.G+(b.G-a.G)*amount),(int)(a.B+(b.B-a.B)*amount));
        }
        static GraphicsPath Outline(RectangleF box, float radius)
        {
            float d=Math.Min(Math.Min(box.Width,box.Height),2*radius);
            var path=new GraphicsPath();
            path.AddArc(box.Left,box.Top,d,d,180,90);path.AddArc(box.Right-d,box.Top,d,d,270,90);
            path.AddArc(box.Right-d,box.Bottom-d,d,d,0,90);path.AddArc(box.Left,box.Bottom-d,d,d,90,90);
            path.CloseFigure();return path;
        }
        internal static void PaintSurface(Graphics g,Size size,float scale,Color parent,Color face,Color ink,bool focus)
        {
            g.Clear(parent);if(size.Width<5*scale || size.Height<5*scale)return;
            g.SmoothingMode=SmoothingMode.AntiAlias;
            float stroke=Math.Max(1,scale),inset=stroke/2+.5f;
            var box=new RectangleF(inset,inset,size.Width-inset*2,size.Height-inset*2);
            using(var path=Outline(box,7*scale))
            using(var fill=new SolidBrush(face))
            using(var edge=new Pen(Mix(face,ink,.27f),stroke)){
                g.FillPath(fill,path);g.DrawPath(edge,path);
            }
            if(focus){
                box.Inflate(-2.3f*scale,-2.3f*scale);
                if(box.Width>2&&box.Height>2)using(var path=Outline(box,4.5f*scale))
                using(var pen=new Pen(ink,Math.Max(1,1.35f*scale)))g.DrawPath(pen,path);
            }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var face=BackColor;var ink=ForeColor;
            bool high=SystemInformation.HighContrast;
            if(high){face=SystemColors.Control;ink=SystemColors.ControlText;}
            if(!Enabled)ink=Mix(face,ink,.55f);
            else if(pressed||hovering)face=Mix(face,ink,pressed?.18f:.09f);
            Color parent=Parent==null?SystemColors.Control:Parent.BackColor;
            PaintSurface(e.Graphics,ClientSize,DeviceDpi/96f,parent,face,ink,Focused&&ShowFocusCues);
            var rect=Rectangle.FromLTRB(Padding.Left,Padding.Top,Width-Padding.Right,Height-Padding.Bottom);
            if(rect.Width<=0||rect.Height<=0)return;
            bool left=TextAlign==ContentAlignment.MiddleLeft;
            if(Image!=null){
                int gap=Appearance.Px(this,6);
                int x=rect.Left+(rect.Width-Image.Width)/2;
                if(!string.IsNullOrEmpty(Text)&&TextImageRelation==TextImageRelation.ImageBeforeText){
                    int textWidth=TextRenderer.MeasureText(Text,Font,Size.Empty,TextFormatFlags.NoPadding).Width;
                    x=left?rect.Left:Math.Max(rect.Left,rect.Left+(rect.Width-Image.Width-gap-textWidth)/2);
                    rect=Rectangle.FromLTRB(x+Image.Width+gap,rect.Top,rect.Right,rect.Bottom);left=true;
                }
                e.Graphics.DrawImageUnscaled(Image,x,(Height-Image.Height)/2);
            }
            var flags=TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine|TextFormatFlags.EndEllipsis|
                      TextFormatFlags.NoPadding|(left?TextFormatFlags.Left:TextFormatFlags.HorizontalCenter);
            if(!UseMnemonic)flags|=TextFormatFlags.NoPrefix;else if(!ShowKeyboardCues)flags|=TextFormatFlags.HidePrefix;
            if(!string.IsNullOrEmpty(Text)&&rect.Width>0)TextRenderer.DrawText(e.Graphics,Text,Font,rect,ink,flags);
        }
        protected override void OnMouseEnter(EventArgs e){base.OnMouseEnter(e);hovering=true;Invalidate();}
        protected override void OnMouseLeave(EventArgs e){base.OnMouseLeave(e);hovering=false;pressed=false;Invalidate();}
        protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);pressed=e.Button==MouseButtons.Left;Invalidate();}
        protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);pressed=false;Invalidate();}
        protected override void OnGotFocus(EventArgs e){base.OnGotFocus(e);Invalidate();}
        protected override void OnLostFocus(EventArgs e){base.OnLostFocus(e);Invalidate();}
    }
}
