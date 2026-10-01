using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// An owned, in-memory test app. No user files, accounts, messages or network.
public class DesktopFixture : Form {
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  public DesktopFixture() {
    Text="DSH Computer Use Fixture"; ClientSize=new Size(1600,1000);
    StartPosition=FormStartPosition.CenterScreen; AutoScaleMode=AutoScaleMode.None;
    Font=new Font("Segoe UI",12); BackColor=Color.White;
    Add(new Label {Text="Owned test window / no messages or files",AutoSize=true},30,25,700,50);
    Add(new Label {Text="Verified input"},30,80,650,50);
    var edit=new TextBox {Name="Verified input",AccessibleName="Verified input",Multiline=true,Text=""};Add(edit,30,140,680,180);
    var status=new Label {Name="Fixture status",Text="invokes=0; toggle=False; selection=Alpha",AutoSize=false};Add(status,30,610,700,120);
    int invokes=0; var toggle=new CheckBox {Text="Toggle test",AccessibleName="Toggle test"};Add(toggle,30,420,600,70);
    var combo=new ComboBox {AccessibleName="Selection test",DropDownStyle=ComboBoxStyle.DropDownList};combo.Items.AddRange(new object[]{"Alpha","Beta","Gamma"});combo.SelectedIndex=0;Add(combo,30,510,500,60);
    Action update=()=>status.Text="invokes="+invokes+"; toggle="+toggle.Checked+"; selection="+combo.SelectedItem;
    var invoke=new Button {Text="Invoke test",AccessibleName="Invoke test"};invoke.Click+=(s,e)=>{invokes++;update();};Add(invoke,30,340,400,65);
    toggle.CheckedChanged+=(s,e)=>update();combo.SelectedIndexChanged+=(s,e)=>update();
    Add(new Label {Text="Visual input (no Edit/Value pattern)"},770,80,780,50);
    Add(new VisualInput(),770,140,780,180);
    var list=new ListBox {AccessibleName="Scroll test"};for(int i=0;i<150;i++)list.Items.Add("Row "+i.ToString("000"));Add(list,770,370,330,350);
    Add(new Label {Text="Drag surface"},1150,350,400,50);Add(new DragSurface(),1150,420,400,290);
    var close=new Button {Text="Close fixture",AccessibleName="Close fixture"};close.Click+=(s,e)=>Close();Add(close,30,850,400,70);
  }
  void Add(Control c,int x,int y,int w,int h){c.SetBounds(x,y,w,h);Controls.Add(c);}
  [STAThread] public static void Main(){SetProcessDpiAwarenessContext(new IntPtr(-4));Application.EnableVisualStyles();Application.Run(new DesktopFixture());}
}
public class VisualInput : Control {
  string value="";
  public VisualInput(){AccessibleName="Visual input surface";AccessibleRole=AccessibleRole.Pane;TabStop=true;SetStyle(ControlStyles.Selectable|ControlStyles.UserPaint|ControlStyles.DoubleBuffer,true);BackColor=Color.FromArgb(235,244,255);}
  protected override void OnMouseDown(MouseEventArgs e){Focus();Invalidate();base.OnMouseDown(e);}
  protected override void OnKeyPress(KeyPressEventArgs e){if(!char.IsControl(e.KeyChar)){value+=e.KeyChar;Invalidate();}base.OnKeyPress(e);}
  protected override bool ProcessCmdKey(ref Message m,Keys k){if(k==(Keys.Control|Keys.V)){value+=Clipboard.GetText();Invalidate();return true;}if(k==Keys.Back){if(value.Length>0)value=value.Substring(0,value.Length-1);Invalidate();return true;}return base.ProcessCmdKey(ref m,k);}
  protected override void OnGotFocus(EventArgs e){Invalidate();base.OnGotFocus(e);}
  protected override void OnPaint(PaintEventArgs e){e.Graphics.Clear(BackColor);using(var p=new Pen(Focused?Color.RoyalBlue:Color.LightGray,4))e.Graphics.DrawRectangle(p,2,2,Width-5,Height-5);e.Graphics.DrawString(value.Length==0?"Click here, then type":value,Font,Brushes.Black,20,35);e.Graphics.DrawString(Focused?"FOCUSED":"",Font,Brushes.RoyalBlue,20,100);}
}
public class DragSurface : Control {
  Point start,end;bool dragging;int strokes=0;
  public DragSurface(){AccessibleName="Drag surface";BackColor=Color.FromArgb(240,250,240);}
  protected override void OnMouseDown(MouseEventArgs e){start=end=e.Location;dragging=true;Capture=true;Invalidate();}
  protected override void OnMouseMove(MouseEventArgs e){if(dragging){end=e.Location;Invalidate();}}
  protected override void OnMouseUp(MouseEventArgs e){if(dragging){end=e.Location;dragging=false;Capture=false;strokes++;AccessibleName="Drag surface strokes="+strokes;Invalidate();}}
  protected override void OnPaint(PaintEventArgs e){e.Graphics.Clear(BackColor);using(var p=new Pen(Color.SeaGreen,6))e.Graphics.DrawLine(p,start,end);e.Graphics.DrawString("strokes="+strokes,Font,Brushes.Black,10,10);}
}
