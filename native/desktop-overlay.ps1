param([int]$ParentProcessId)
$ErrorActionPreference='Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,System,System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;
public class DesktopOverlayForm : Form {
  public string Kind; public bool Pulse; public float UiScale=1;
  public DesktopOverlayForm(string kind) {
    Kind=kind;FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;TopMost=true;
    BackColor=Color.Magenta;TransparencyKey=Color.Magenta;Enabled=false;
    StartPosition=FormStartPosition.Manual;AutoScaleMode=AutoScaleMode.None;DoubleBuffered=true;AccessibleRole=AccessibleRole.None;
  }
  protected override bool ShowWithoutActivation { get {return true;} }
  protected override CreateParams CreateParams {get {var p=base.CreateParams;p.ExStyle|=0x08000000|0x00000020|0x00000080;return p;}}
  protected override void WndProc(ref Message m) {if(m.Msg==0x0084){m.Result=new IntPtr(-1);return;}base.WndProc(ref m);}
  protected override void OnPaint(PaintEventArgs e) {
    base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.ScaleTransform(UiScale,UiScale);
    var blue=Color.FromArgb(59,130,246);
    if(Kind=="edge"){g.Clear(blue);return;}
    if(Kind=="banner"){
      using(var outline=new GraphicsPath()) {int r=16;int width=(int)(Width/UiScale),height=(int)(Height/UiScale);outline.AddArc(0,0,r,r,180,90);outline.AddArc(width-r-1,0,r,r,270,90);outline.AddArc(width-r-1,height-r-1,r,r,0,90);outline.AddArc(0,height-r-1,r,r,90,90);outline.CloseFigure();using(var brush=new SolidBrush(Color.FromArgb(15,23,42)))g.FillPath(brush,outline);using(var pen=new Pen(blue,1.5f))g.DrawPath(pen,outline);}
      using(var pen=new Pen(blue,1.8f)){g.DrawRectangle(pen,14,12,16,11);g.DrawLine(pen,22,23,22,27);g.DrawLine(pen,17,27,27,27);}
      using(var font=new Font("Segoe UI",14,FontStyle.Regular,GraphicsUnit.Pixel))using(var brush=new SolidBrush(Color.White))g.DrawString("DSH is using your computer",font,brush,40,10);
      return;
    }
    if(Pulse){using(var pen=new Pen(blue,2.5f))g.DrawEllipse(pen,4,4,32,32);}
    g.TranslateTransform(16,16);
    var points=new Point[]{new Point(4,4),new Point(4,29),new Point(10,22),new Point(16,35),new Point(21,32),new Point(15,20),new Point(28,20)};
    using(var brush=new SolidBrush(blue))g.FillPolygon(brush,points);using(var pen=new Pen(Color.White,1.7f))g.DrawPolygon(pen,points);
  }
}
public static class DesktopOverlay {
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point,uint flags);
  [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr monitor,int type,out uint x,out uint y);
  static float scale=1;

  static DesktopOverlayForm[] edges;static DesktopOverlayForm banner,cursor;static DateTime until=DateTime.MinValue,pulseUntil=DateTime.MinValue;
  static int Num(Dictionary<string,object> data,string key,int fallback) {object value;return data.TryGetValue(key,out value)?Convert.ToInt32(value):fallback;}
  static void Hide() {foreach(var form in edges)form.Hide();banner.Hide();cursor.Hide();}
  static void Apply(Dictionary<string,object> data) {
    object method;if(!data.TryGetValue("method",out method))return;
    if(Convert.ToString(method)=="hide"){Hide();until=DateTime.MinValue;return;}
    until=DateTime.UtcNow.AddSeconds(45);
    object rect;
    if(data.TryGetValue("rect",out rect)){
      var r=(Dictionary<string,object>)rect;var screen=Screen.FromRectangle(new Rectangle(Num(r,"x",0),Num(r,"y",0),Num(r,"width",1),Num(r,"height",1))).Bounds;
      uint dpiX,dpiY;try {if(GetDpiForMonitor(MonitorFromPoint(new Point(screen.Left+screen.Width/2,screen.Top+screen.Height/2),2),0,out dpiX,out dpiY)==0)scale=dpiX/96f;}catch{scale=1;}
      var edgeWidth=Math.Max(3,(int)(3*scale));
      edges[0].Bounds=new Rectangle(screen.Left,screen.Top,screen.Width,edgeWidth);edges[1].Bounds=new Rectangle(screen.Left,screen.Bottom-edgeWidth,screen.Width,edgeWidth);edges[2].Bounds=new Rectangle(screen.Left,screen.Top,edgeWidth,screen.Height);edges[3].Bounds=new Rectangle(screen.Right-edgeWidth,screen.Top,edgeWidth,screen.Height);
      foreach(var edge in edges)edge.Show();banner.UiScale=scale;cursor.UiScale=scale;banner.Bounds=new Rectangle(screen.Left+(screen.Width-(int)(304*scale))/2,screen.Top+(int)(12*scale),(int)(304*scale),(int)(40*scale));banner.Show();
    }
    object point;
    if(data.TryGetValue("point",out point)){
      var p=(Dictionary<string,object>)point;cursor.Bounds=new Rectangle(Num(p,"x",0)-(int)(20*scale),Num(p,"y",0)-(int)(20*scale),(int)(64*scale),(int)(68*scale));cursor.Pulse=Convert.ToString(method)=="click";if(cursor.Pulse)pulseUntil=DateTime.UtcNow.AddMilliseconds(500);cursor.Show();cursor.Invalidate();
    }
  }
  public static void Run(int parent) {
    try{SetProcessDpiAwarenessContext(new IntPtr(-4));}catch{SetProcessDPIAware();}
    edges=new DesktopOverlayForm[]{new DesktopOverlayForm("edge"),new DesktopOverlayForm("edge"),new DesktopOverlayForm("edge"),new DesktopOverlayForm("edge")};banner=new DesktopOverlayForm("banner");cursor=new DesktopOverlayForm("cursor");
    var control=new Control();var handle=control.Handle;var ctx=new ApplicationContext();
    var reader=new Thread(()=>{string line;while((line=Console.ReadLine())!=null){try{var data=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line);control.BeginInvoke((Action)(()=>Apply(data)));}catch{}}try{control.BeginInvoke((Action)(()=>ctx.ExitThread()));}catch{}});reader.IsBackground=true;reader.Start();
    var timer=new System.Windows.Forms.Timer();timer.Interval=50;timer.Tick+=(s,e)=>{if(DateTime.UtcNow>until)Hide();if(cursor.Pulse&&DateTime.UtcNow>pulseUntil){cursor.Pulse=false;cursor.Invalidate();}try{if(Process.GetProcessById(parent).HasExited)ctx.ExitThread();}catch{ctx.ExitThread();}};timer.Start();
    Console.WriteLine("{\"ready\":true}");Console.Out.Flush();
    try{Application.Run(ctx);}finally{timer.Dispose();Hide();foreach(var form in edges)form.Dispose();banner.Dispose();cursor.Dispose();control.Dispose();}
  }
}
'@
[DesktopOverlay]::Run($ParentProcessId)
