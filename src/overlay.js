import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Non-activating Windows UI, owned by this plugin rather than the input worker. */
export class DesktopOverlay {
  constructor({ spawnProcess=spawn, platform=process.platform, onCancel=()=>{} }={}) { this.spawnProcess=spawnProcess;this.platform=platform;this.onCancel=onCancel;this.proc=null;this.starting=null;this.owner=null;this.epoch=0;this.closed=false; }
  async ready() {
    if(this.closed)throw new Error('Desktop overlay is closed');
    if(this.starting)return this.starting;
    if(this.proc)return;
    this.starting=this.start().finally(()=>this.starting=null);return this.starting;
  }
  async start() {
    if(this.platform!=='win32')return;
    const executable=path.join(process.env.SystemRoot||'C:/Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
    const proc=this.spawnProcess(executable,['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('../native/desktop-overlay.ps1',import.meta.url)),'-ParentProcessId',String(process.pid)],{windowsHide:true,stdio:['pipe','pipe','pipe']});this.proc=proc;
    const lost=()=>{if(this.proc!==proc)return;this.proc=null;if(this.owner!==null&&!this.closed){this.epoch++;this.owner=null;try{Promise.resolve(this.onCancel({reason:'overlay_exit'})).catch(()=>{});}catch{}}};
    proc.on('exit',lost);proc.on('error',lost);proc.stdin.on('error',lost);proc.stderr.on('data',()=>{});
    let events='';proc.stdout.on('data',chunk=>{events+=String(chunk);if(events.length>8192)events='';let end;while((end=events.indexOf('\n'))>=0){const line=events.slice(0,end);events=events.slice(end+1);let event;try{event=JSON.parse(line);}catch{continue;}if(event.type==='cancel'&&event.reason==='physical_escape'&&this.proc===proc&&this.owner!==null&&event.epoch===this.epoch){this.epoch++;this.owner=null;this.send({method:'hide'});try{Promise.resolve(this.onCancel(event)).catch(()=>{});}catch{}}}});
    await new Promise((resolve,reject)=>{let buffer='';const timer=setTimeout(()=>done(new Error('Desktop overlay startup timed out')),5000);const done=error=>{clearTimeout(timer);proc.stdout.removeListener('data',read);proc.removeListener('error',fail);proc.removeListener('exit',exit);if(error){if(this.proc===proc)this.proc=null;proc.kill();reject(error);}else resolve();};const read=chunk=>{buffer+=String(chunk);if(buffer.includes('"ready":true'))done();};const fail=e=>done(e);const exit=()=>done(new Error('Desktop overlay exited before startup'));proc.stdout.on('data',read);proc.once('error',fail);proc.once('exit',exit);});
  }
  send(value) {if(this.proc&&!this.closed)this.proc.stdin.write(JSON.stringify({...value,epoch:this.epoch})+'\n');}
  async show(owner,rect,signal,visible=true) {const epoch=this.epoch;signal?.throwIfAborted();await this.ready();signal?.throwIfAborted();if(this.epoch!==epoch||this.closed)return;this.owner=owner;this.send({method:'show',rect,visible});}
  point(event) {if(this.owner&&event.point)this.send({method:event.action==='click'?'click':'move',point:event.point});}
  hide(owner) {if(owner!==undefined&&owner!==this.owner)return;this.epoch++;this.owner=null;this.send({method:'hide'});}
  close() {this.hide();this.closed=true;this.proc?.kill();this.proc=null;}
}
