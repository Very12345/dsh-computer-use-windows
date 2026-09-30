import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { WindowsBackend } from '../src/backend.js';

function spawnHarness() {
  const processes=[];
  const spawn=(exe,args,options)=>{
    const p=new EventEmitter();p.exe=exe;p.args=args;p.options=options;p.stdout=new EventEmitter();p.stdout.setEncoding=()=>{};p.stderr=new EventEmitter();p.stderr.setEncoding=()=>{};p.stdin=new EventEmitter();p.sent=[];p.stdin.write=(line,callback)=>{p.sent.push(JSON.parse(line));callback?.();};p.kill=()=>{p.killed=true;};processes.push(p);
    if(args.some(a=>String(a).endsWith('release-input.ps1')))queueMicrotask(()=>p.emit('exit',0));
    return p;
  };
  return {processes,spawn};
}
test('one STA backend frames replies, handles chunked JSON and ignores foreign ids',async()=>{const h=spawnHarness();const b=new WindowsBackend({spawnProcess:h.spawn});const pending=b.request('list_windows');await new Promise(r=>setImmediate(r));const p=h.processes[0];assert.ok(p.args.includes('-STA'));assert.equal(p.options.windowsHide,true);p.stdout.emit('data','{"id":999,"ok":true}\n{"id":1,');p.stdout.emit('data','"ok":true,"windows":[]}\n');assert.deepEqual((await pending).windows,[]);b.close();});
test('cancellation kills input process and does not dispatch replay',async()=>{const h=spawnHarness();const b=new WindowsBackend({spawnProcess:h.spawn});const abort=new AbortController();const call=b.request('type_text',{text:'x'},abort.signal);await new Promise(r=>setImmediate(r));abort.abort();await assert.rejects(call,/Stopped during/);assert.equal(h.processes[0].killed,true);assert.equal(h.processes[0].sent.length,1);await b.cleanup;assert.equal(b.pending.size,0);b.close();});
test('backend exit rejects pending work; late response cannot revive it',async()=>{const h=spawnHarness();const b=new WindowsBackend({spawnProcess:h.spawn});const call=b.request('snapshot');await new Promise(r=>setImmediate(r));h.processes[0].emit('exit',1);await assert.rejects(call,/exited/);h.processes[0].stdout.emit('data','{"id":1,"ok":true}\n');assert.equal(b.pending.size,0);b.close();});
test('timeout is bounded and never starts an automatic replacement',async()=>{const h=spawnHarness();const b=new WindowsBackend({spawnProcess:h.spawn,timeoutMs:10});await assert.rejects(b.request('snapshot'),/timed out/);assert.equal(h.processes.length,1);b.close();});
test('pre-abort does not spawn a process',async()=>{const h=spawnHarness();const b=new WindowsBackend({spawnProcess:h.spawn});const a=new AbortController();a.abort();await assert.rejects(b.request('list_windows',{},a.signal));assert.equal(h.processes.length,0);b.close();});
