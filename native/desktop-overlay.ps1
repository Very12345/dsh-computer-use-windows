param([int]$ParentProcessId)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OverlayDpiBootstrap {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
try { if(-not [OverlayDpiBootstrap]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) { [void][OverlayDpiBootstrap]::SetProcessDPIAware() } } catch { [void][OverlayDpiBootstrap]::SetProcessDPIAware() }
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
  public void RenderGlow() {
    if(!Visible||Width<1||Height<1)return;
    using(var bitmap=new Bitmap(Width,Height,PixelFormat.Format32bppPArgb)) {
      using(var g=Graphics.FromImage(bitmap)){
        g.Clear(Color.Transparent);g.SmoothingMode=SmoothingMode.AntiAlias;
        if(Kind=="edge-bottom"){g.TranslateTransform(Width,Height);g.RotateTransform(180);}
        if(Kind=="edge-left"){g.TranslateTransform(0,Height);g.RotateTransform(-90);}
        if(Kind=="edge-right"){g.TranslateTransform(Width,0);g.RotateTransform(90);}
        g.ScaleTransform(UiScale,UiScale);float length=(Kind=="edge-left"||Kind=="edge-right"?Height:Width)/UiScale;
        using(var brush=new LinearGradientBrush(new RectangleF(0,0,length,40),Color.RoyalBlue,Color.Transparent,90f)){
          brush.InterpolationColors=new ColorBlend{Positions=new float[]{0,.04f,.15f,.42f,.72f,1},Colors=new Color[]{Color.FromArgb(180,32,139,255),Color.FromArgb(160,42,146,255),Color.FromArgb(110,53,153,255),Color.FromArgb(48,66,160,255),Color.FromArgb(13,79,168,255),Color.FromArgb(0,79,168,255)}};
          g.FillRectangle(brush,0,0,length,40);
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
      using(var outline=new GraphicsPath()) {int r=16;int width=(int)(Width/UiScale),height=(int)(Height/UiScale);outline.AddArc(0,0,r,r,180,90);outline.AddArc(width-r-1,0,r,r,270,90);outline.AddArc(width-r-1,height-r-1,r,r,0,90);outline.AddArc(0,height-r-1,r,r,90,90);outline.CloseFigure();using(var brush=new LinearGradientBrush(new Rectangle(0,0,width,height),Color.FromArgb(18,145,249),Color.FromArgb(78,119,250),0f))g.FillPath(brush,outline);using(var pen=new Pen(Color.FromArgb(116,190,255),1f))g.DrawPath(pen,outline);}
      using(var font=new Font("Segoe UI",14,FontStyle.Regular,GraphicsUnit.Pixel))using(var brush=new SolidBrush(Color.White))using(var format=new StringFormat(StringFormat.GenericTypographic)){
        const string text="DSH is using your computer  \u00b7  Esc to cancel";float width=Width/UiScale,height=Height/UiScale;
        var textSize=g.MeasureString(text,font,new SizeF(1000,height),format);float groupWidth=28+8+textSize.Width;
        float left=(width-groupWidth)/2,top=(height-textSize.Height)/2;
        var logoState=g.Save();g.TranslateTransform(left,(height-24)/2);g.ScaleTransform(28f/60f,24f/41.3594f);using(var logoBrush=new SolidBrush(Color.White))g.FillPath(logoBrush,DesktopOverlay.Whale);g.Restore(logoState);
        g.DrawString(text,font,brush,new PointF(left+36,top),format);
      }
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
  [StructLayout(LayoutKind.Sequential)] struct KEY {public uint vkCode,scanCode,flags,time;public UIntPtr extra;}
  delegate IntPtr KeyboardCallback(int code,IntPtr message,IntPtr data);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int type,KeyboardCallback callback,IntPtr module,uint thread);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook,int code,IntPtr message,IntPtr data);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
  static IntPtr hook;static KeyboardCallback keyboardCallback;static Control dispatcher;
  static bool active,visibleUi=true,consumeEscapeUp;static long epoch=-1,cancelledEpoch=-1;
  public static bool IsPhysicalEscape(uint key,uint flags,int message){return key==27&&(flags&0x12)==0&&(message==0x100||message==0x104);}
  static IntPtr Keyboard(int code,IntPtr message,IntPtr data) {
    if(code>=0){var key=(KEY)Marshal.PtrToStructure(data,typeof(KEY));int msg=message.ToInt32();
      if(key.vkCode==27&&(key.flags&0x12)==0){
        if(consumeEscapeUp){if(msg==0x101||msg==0x105)consumeEscapeUp=false;return new IntPtr(1);}
        if(active&&IsPhysicalEscape(key.vkCode,key.flags,msg)){
          active=false;consumeEscapeUp=true;cancelledEpoch=epoch;until=DateTime.MinValue;
          long cancelled=epoch;
          dispatcher.BeginInvoke((Action)(()=>{Hide();ThreadPool.QueueUserWorkItem(_=>{Console.WriteLine("{\"type\":\"cancel\",\"reason\":\"physical_escape\",\"epoch\":"+cancelled+"}");Console.Out.Flush();});}));
          return new IntPtr(1);
        }
      }
    }
    return CallNextHookEx(hook,code,message,data);
  }

  static DesktopOverlayForm[] edges;static DesktopOverlayForm banner,cursor;static DateTime until=DateTime.MinValue,pulseUntil=DateTime.MinValue;
  static int Num(Dictionary<string,object> data,string key,int fallback) {object value;return data.TryGetValue(key,out value)?Convert.ToInt32(value):fallback;}
  static void Hide() {foreach(var form in edges)form.Hide();banner.Hide();cursor.Hide();}
  static void Apply(Dictionary<string,object> data) {
    object method;if(!data.TryGetValue("method",out method))return;
    long incoming=Num(data,"epoch",0);if(incoming<epoch)return;
    if(Convert.ToString(method)=="hide"){epoch=incoming;active=false;Hide();until=DateTime.MinValue;return;}
    if(incoming<=cancelledEpoch)return;
    epoch=incoming;active=true;until=DateTime.UtcNow.AddMinutes(5);
    object visibility;if(data.TryGetValue("visible",out visibility))visibleUi=Convert.ToBoolean(visibility);
    object rect;
    if(data.TryGetValue("rect",out rect)){
      var r=(Dictionary<string,object>)rect;var screen=Screen.FromRectangle(new Rectangle(Num(r,"x",0),Num(r,"y",0),Num(r,"width",1),Num(r,"height",1))).Bounds;
      uint dpiX,dpiY;try {if(GetDpiForMonitor(MonitorFromPoint(new Point(screen.Left+screen.Width/2,screen.Top+screen.Height/2),2),0,out dpiX,out dpiY)==0)scale=dpiX/96f;}catch{scale=1;}
      int depth=(int)(40*scale);
      edges[0].Bounds=new Rectangle(screen.Left,screen.Top,screen.Width,depth);edges[1].Bounds=new Rectangle(screen.Left,screen.Bottom-depth,screen.Width,depth);edges[2].Bounds=new Rectangle(screen.Left,screen.Top,depth,screen.Height);edges[3].Bounds=new Rectangle(screen.Right-depth,screen.Top,depth,screen.Height);
      foreach(var edge in edges){edge.UiScale=scale;if(visibleUi){edge.Show();edge.RenderGlow();}else edge.Hide();}
      banner.UiScale=scale;cursor.UiScale=scale;banner.Bounds=new Rectangle(screen.Left+(screen.Width-(int)(440*scale))/2,screen.Top+(int)(30*scale),(int)(440*scale),(int)(44*scale));if(visibleUi){banner.Show();banner.Invalidate();}else{banner.Hide();cursor.Hide();}
    }
    object point;
    if(visibleUi&&data.TryGetValue("point",out point)){
      var p=(Dictionary<string,object>)point;cursor.Bounds=new Rectangle(Num(p,"x",0)-(int)(20*scale),Num(p,"y",0)-(int)(20*scale),(int)(64*scale),(int)(68*scale));cursor.Pulse=Convert.ToString(method)=="click";if(cursor.Pulse)pulseUntil=DateTime.UtcNow.AddMilliseconds(500);cursor.Show();cursor.Invalidate();
    }
  }
  public static void Run(int parent,string whaleFile) {
    LoadWhale(whaleFile);
    edges=new DesktopOverlayForm[]{new DesktopOverlayForm("edge-top"),new DesktopOverlayForm("edge-bottom"),new DesktopOverlayForm("edge-left"),new DesktopOverlayForm("edge-right")};banner=new DesktopOverlayForm("banner");cursor=new DesktopOverlayForm("cursor");
    var control=new Control();var handle=control.Handle;var ctx=new ApplicationContext();
    dispatcher=control;keyboardCallback=Keyboard;hook=SetWindowsHookEx(13,keyboardCallback,GetModuleHandle(null),0);if(hook==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Could not install the physical Esc stop hook");
    var reader=new Thread(()=>{string line;while((line=Console.ReadLine())!=null){try{var data=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(line);control.BeginInvoke((Action)(()=>Apply(data)));}catch{}}try{control.BeginInvoke((Action)(()=>ctx.ExitThread()));}catch{}});reader.IsBackground=true;reader.Start();
    var timer=new System.Windows.Forms.Timer();timer.Interval=80;timer.Tick+=(s,e)=>{if(DateTime.UtcNow>until){active=false;Hide();}if(cursor.Pulse&&DateTime.UtcNow>pulseUntil){cursor.Pulse=false;cursor.Invalidate();}try{using(var parentProcess=Process.GetProcessById(parent)){if(parentProcess.HasExited)ctx.ExitThread();}}catch{ctx.ExitThread();}};timer.Start();
    Console.WriteLine("{\"ready\":true}");Console.Out.Flush();
    try{Application.Run(ctx);}finally{active=false;UnhookWindowsHookEx(hook);timer.Dispose();Hide();foreach(var form in edges)form.Dispose();banner.Dispose();cursor.Dispose();control.Dispose();Whale.Dispose();}
  }
}
'@
[DesktopOverlay]::Run($ParentProcessId,(Join-Path $PSScriptRoot 'assets/deepseek-whale.json'))
