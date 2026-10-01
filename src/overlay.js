import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Non-activating Windows UI, owned by this plugin rather than the input worker. */
export class DesktopOverlay {
  constructor({ spawnProcess=spawn, platform=process.platform }={}) { this.spawnProcess=spawnProcess;this.platform=platform;this.proc=null;this.starting=null;this.owner=null;this.epoch=0;this.closed=false; }
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
    proc.on('exit',()=>{if(this.proc===proc)this.proc=null;});proc.stdin.on('error',()=>{});proc.stderr.on('data',()=>{});proc.stdout.on('data',()=>{});
    await new Promise((resolve,reject)=>{let buffer='';const timer=setTimeout(()=>done(new Error('Desktop overlay startup timed out')),5000);const done=error=>{clearTimeout(timer);proc.stdout.removeListener('data',read);proc.removeListener('error',fail);proc.removeListener('exit',exit);if(error){if(this.proc===proc)this.proc=null;proc.kill();reject(error);}else resolve();};const read=chunk=>{buffer+=String(chunk);if(buffer.includes('"ready":true'))done();};const fail=e=>done(e);const exit=()=>done(new Error('Desktop overlay exited before startup'));proc.stdout.on('data',read);proc.once('error',fail);proc.once('exit',exit);});
  }
  send(value) {if(this.proc&&!this.closed)this.proc.stdin.write(JSON.stringify(value)+'\n');}
  async show(owner,rect,signal) {const epoch=this.epoch;signal?.throwIfAborted();await this.ready();signal?.throwIfAborted();if(this.epoch!==epoch||this.closed)return;this.owner=owner;this.send({method:'show',rect});}
  point(event) {if(this.owner&&event.point)this.send({method:event.action==='click'?'click':'move',point:event.point});}
  hide(owner) {if(owner!==undefined&&owner!==this.owner)return;this.epoch++;this.owner=null;this.send({method:'hide'});}
  close() {this.hide();this.closed=true;this.proc?.kill();this.proc=null;}
}
