import { png } from './png.js';
const screenshot = png(500, 300);
export class FakeBackend {
  constructor() { this.calls=[]; this.focused=true; this.value=''; this.failAction=''; this.delayReads=0; this.pendingText=null; this.inFlight=0;this.maxInFlight=0;this.latency=0;this.occluded=false;this.blocked=false; this.window={nativeWindowHandle:101,processId:42,processStartedAt:'123456',executable:'notepad.exe',name:'无标题 - Notepad',boundingBox:{x:100,y:200,width:1000,height:600},isOffscreen:false}; }
  async request(action,args,signal) {
    signal?.throwIfAborted();this.calls.push({action,args});this.inFlight++;this.maxInFlight=Math.max(this.maxInFlight,this.inFlight);
    try {
      if(this.latency)await new Promise(r=>setTimeout(r,this.latency));
      if(action===this.failAction)throw new Error('simulated failure');
      if(action==='list_windows')return {windows:[structuredClone(this.window)]};
      if(action==='list_apps')return {apps:[{executable:'notepad.exe',name:'Notepad'},{executable:'chrome.exe',name:'Chrome'}]};
      if(action==='snapshot') {
        if(this.pendingText!==null&&this.delayReads--<=0){this.value=this.pendingText;this.pendingText=null;this.window.name='*'+this.value+' - Notepad';}
        return {ok:true,inputFocus:{nativeWindowHandle:102,belongsToTarget:true},windowBounds:{...this.window.boundingBox},tree:{id:'uia:root',name:this.window.name,controlType:'Window',boundingBox:{...this.window.boundingBox},children:[{id:'uia:document',name:'文本编辑器',controlType:'Document',hasKeyboardFocus:this.focused,value:this.value,isEnabled:true,isOffscreen:false}]},screenshot:args.includeScreenshot?{base64:screenshot,bounds:{...this.window.boundingBox},origin:{x:this.window.boundingBox.x,y:this.window.boundingBox.y},imageScale:0.5,method:'printwindow',path:'fake.png',occludedPossible:this.occluded}:null};
      }
      if(['type_text','set_value'].includes(action)&&args.expectedPriorValue!==undefined&&args.expectedPriorValue!==this.value)throw new Error('CONTENT_CHANGED: editable content changed after observation. No input sent.');
      if(action==='type_text'){this.pendingText=this.value+args.text;return {ok:true,method:'clipboard-paste'};}
      if(action==='set_value'){this.pendingText=args.value;return {ok:true,method:'ValuePattern'};}
      if(action==='click')this.focused=true;
      return {ok:true,method:'sendinput'};
    } finally {this.inFlight--;}
  }
  stop(){this.stopped=true;} close(){this.closed=true;}
}
