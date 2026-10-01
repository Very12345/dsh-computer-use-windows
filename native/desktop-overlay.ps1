param([int]$ParentProcessId)
$ErrorActionPreference='Stop'
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,System,System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;
public class DesktopOverlayForm : Form {
  public string Kind; public bool Pulse; public float UiScale=1;
  [StructLayout(LayoutKind.Sequential)] struct XY {public int x,y;public XY(int a,int b){x=a;y=b;}}
  [StructLayout(LayoutKind.Sequential)] struct DIM {public int x,y;public DIM(int a,int b){x=a;y=b;}}
  [StructLayout(LayoutKind.Sequential,Pack=1)] struct BLEND {public byte op,flags,alpha,format;}
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd,IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc,IntPtr item);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr item);
  [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd,IntPtr dst,ref XY position,ref DIM size,IntPtr source,ref XY origin,int key,ref BLEND blend,int flags);
  public void RenderWave(double time) {
    if(!Visible||Width<1||Height<1)return;
    using(var bitmap=new Bitmap(Width,Height,PixelFormat.Format32bppPArgb)) {
      using(var g=Graphics.FromImage(bitmap)){
        g.Clear(Color.Transparent);g.SmoothingMode=SmoothingMode.AntiAlias;
        if(Kind=="edge-bottom"){g.TranslateTransform(Width,Height);g.RotateTransform(180);}
        if(Kind=="edge-left"){g.TranslateTransform(0,Height);g.RotateTransform(-90);}
        if(Kind=="edge-right"){g.TranslateTransform(Width,0);g.RotateTransform(90);}
        g.ScaleTransform(UiScale,UiScale);float length=(Kind=="edge-left"||Kind=="edge-right"?Height:Width)/UiScale;
        for(int layer=0;layer<2;layer++)using(var wave=new GraphicsPath()){
          wave.AddLine(0,0,length,0);float oldY=0;
          for(float x=length;x>=0;x-=2){float y=(float)(19-layer*3+Math.Sin(x/74+time*(layer==0?.45:-.32)+layer*1.6)*4+Math.Sin(x/149-time*.2)*1.4);if(x==length)wave.AddLine(length,0,x,y);else wave.AddLine(x+2,oldY,x,y);oldY=y;}
          wave.AddLine(0,oldY,0,0);wave.CloseFigure();
          using(var brush=new LinearGradientBrush(new RectangleF(0,0,length,32),Color.FromArgb(layer==0?100:72,layer==0?56:37,layer==0?189:99,layer==0?248:235),Color.FromArgb(16,59,130,246),90f))g.FillPath(brush,wave);
        }
      }
      IntPtr screen=GetDC(IntPtr.Zero),memory=CreateCompatibleDC(screen),image=bitmap.GetHbitmap(Color.FromArgb(0)),old=SelectObject(memory,image);
      try{var position=new XY(Left,Top);var size=new DIM(Width,Height);var origin=new XY(0,0);var blend=new BLEND{alpha=255,format=1};UpdateLayeredWindow(Handle,screen,ref position,ref size,memory,ref origin,0,ref blend,2);}
      finally{SelectObject(memory,old);DeleteObject(image);DeleteDC(memory);ReleaseDC(IntPtr.Zero,screen);}
    }
  }
  public DesktopOverlayForm(string kind) {
    Kind=kind;FormBorderStyle=FormBorderStyle.None;ShowInTaskbar=false;TopMost=true;
    BackColor=Color.Magenta;if(!kind.StartsWith("edge-"))TransparencyKey=Color.Magenta;Enabled=false;
    StartPosition=FormStartPosition.Manual;AutoScaleMode=AutoScaleMode.None;DoubleBuffered=true;AccessibleRole=AccessibleRole.None;
  }
  protected override bool ShowWithoutActivation { get {return true;} }
  protected override CreateParams CreateParams {get {var p=base.CreateParams;p.ExStyle|=0x08000000|0x00000020|0x00000080;if(Kind!=null&&Kind.StartsWith("edge-"))p.ExStyle|=0x00080000;return p;}}
  protected override void WndProc(ref Message m) {if(m.Msg==0x0084){m.Result=new IntPtr(-1);return;}base.WndProc(ref m);}
  protected override void OnPaint(PaintEventArgs e) {
    base.OnPaint(e);var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;g.ScaleTransform(UiScale,UiScale);
    var blue=Color.FromArgb(59,130,246);
    if(Kind.StartsWith("edge-"))return;
    if(Kind=="banner"){
      using(var outline=new GraphicsPath()) {int r=16;int width=(int)(Width/UiScale),height=(int)(Height/UiScale);outline.AddArc(0,0,r,r,180,90);outline.AddArc(width-r-1,0,r,r,270,90);outline.AddArc(width-r-1,height-r-1,r,r,0,90);outline.AddArc(0,height-r-1,r,r,90,90);outline.CloseFigure();using(var brush=new SolidBrush(Color.FromArgb(15,23,42)))g.FillPath(brush,outline);using(var pen=new Pen(blue,1.5f))g.DrawPath(pen,outline);}
      var logoState=g.Save();g.TranslateTransform(12,8);g.ScaleTransform(28f/60f,24f/41.3594f);using(var brush=new SolidBrush(Color.FromArgb(77,107,254)))g.FillPath(brush,DesktopOverlay.Whale);g.Restore(logoState);
      using(var font=new Font("Segoe UI",14,FontStyle.Regular,GraphicsUnit.Pixel))using(var brush=new SolidBrush(Color.White))g.DrawString("DSH is using your computer",font,brush,46,10);
      return;
    }
    if(Pulse){using(var pen=new Pen(blue,2.5f))g.DrawEllipse(pen,4,4,32,32);}
    g.TranslateTransform(16,16);
    var points=new Point[]{new Point(4,4),new Point(4,29),new Point(10,22),new Point(16,35),new Point(21,32),new Point(15,20),new Point(28,20)};
    using(var brush=new SolidBrush(blue))g.FillPolygon(brush,points);using(var pen=new Pen(Color.White,1.7f))g.DrawPolygon(pen,points);
  }
}
public class WhaleCommand {public string op;public float[] values;}
public static class DesktopOverlay {
  public static GraphicsPath Whale;
  static void LoadWhale(string file) {
    Whale=new GraphicsPath(FillMode.Winding);PointF current=new PointF(),start=new PointF();
    foreach(var command in new JavaScriptSerializer().Deserialize<List<WhaleCommand>>(File.ReadAllText(file))){var v=command.values;if(command.op=="M"){Whale.StartFigure();current=start=new PointF(v[0],v[1]);}else if(command.op=="C"){Whale.AddBezier(current,new PointF(v[0],v[1]),new PointF(v[2],v[3]),new PointF(v[4],v[5]));current=new PointF(v[4],v[5]);}else{Whale.CloseFigure();current=start;}}
  }
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
      int outside=(int)(14*scale),depth=(int)(32*scale);
      edges[0].Bounds=new Rectangle(screen.Left,screen.Top-outside,screen.Width,depth);edges[1].Bounds=new Rectangle(screen.Left,screen.Bottom-depth+outside,screen.Width,depth);edges[2].Bounds=new Rectangle(screen.Left-outside,screen.Top,depth,screen.Height);edges[3].Bounds=new Rectangle(screen.Right-depth+outside,screen.Top,depth,screen.Height);
      foreach(var edge in edges){edge.UiScale=scale;edge.Show();edge.RenderWave(DateTime.UtcNow.TimeOfDay.TotalSeconds);}
      banner.UiScale=scale;cursor.UiScale=scale;banner.Bounds=new Rectangle(screen.Left+(screen.Width-(int)(314*scale))/2,screen.Top+(int)(20*scale),(int)(314*scale),(int)(40*scale));banner.Show();
    }
    object point;
    if(data.TryGetValue("point",out point)){
      var p=(Dictionary<string,object>)point;cursor.Bounds=new Rectangle(Num(p,"x",0)-(int)(20*scale),Num(p,"y",0)-(int)(20*scale),(int)(64*scale),(int)(68*scale));cursor.Pulse=Convert.ToString(method)=="click";if(cursor.Pulse)pulseUntil=DateTime.UtcNow.AddMilliseconds(500);cursor.Show();cursor.Invalidate();
    }
  }
  public static void Run(int parent,string whaleFile) {
    LoadWhale(whaleFile);
    try{SetProcessDpiAwarenessContext(new IntPtr(-4));}catch{SetProcessDPIAware();}
    edges=new DesktopOverlayForm[]{new DesktopOverlayForm("edge-top"),new DesktopOverlayForm("edge-bottom"),new DesktopOverlayForm("edge-left"),new DesktopOverlayForm("edge-right")};banner=new DesktopOverlayForm("banner");cursor=new DesktopOverlayForm("cursor");
    var control=new Control();var handle=control.Handle;var ctx=new ApplicationContext();
    var reader=new Thread(()=>{string line;while((line=Console.ReadLine())!=null){try{var data=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line);control.BeginInvoke((Action)(()=>Apply(data)));}catch{}}try{control.BeginInvoke((Action)(()=>ctx.ExitThread()));}catch{}});reader.IsBackground=true;reader.Start();
    var timer=new System.Windows.Forms.Timer();timer.Interval=80;timer.Tick+=(s,e)=>{foreach(var edge in edges)if(edge.Visible)edge.RenderWave(DateTime.UtcNow.TimeOfDay.TotalSeconds);if(DateTime.UtcNow>until)Hide();if(cursor.Pulse&&DateTime.UtcNow>pulseUntil){cursor.Pulse=false;cursor.Invalidate();}try{if(Process.GetProcessById(parent).HasExited)ctx.ExitThread();}catch{ctx.ExitThread();}};timer.Start();
    Console.WriteLine("{\"ready\":true}");Console.Out.Flush();
    try{Application.Run(ctx);}finally{timer.Dispose();Hide();foreach(var form in edges)form.Dispose();banner.Dispose();cursor.Dispose();control.Dispose();Whale.Dispose();}
  }
}
'@
[DesktopOverlay]::Run($ParentProcessId,(Join-Path $PSScriptRoot 'assets/deepseek-whale.json'))
