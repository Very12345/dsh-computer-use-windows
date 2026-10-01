import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DesktopOverlay } from '../src/overlay.js';

function fixture(options={}){let proc;const spawnProcess=(exe,args,options)=>{proc=new EventEmitter();proc.stdout=new EventEmitter();proc.stderr=new EventEmitter();proc.stdin=new EventEmitter();proc.writes=[];proc.stdin.write=line=>proc.writes.push(JSON.parse(line));proc.kill=()=>proc.killed=true;proc.options=options;queueMicrotask(()=>proc.stdout.emit('data','{"ready":true}\n'));return proc;};return {overlay:new DesktopOverlay({spawnProcess,platform:'win32',...options}),proc:()=>proc};}
test('overlay is lazy, non-console and owner-scoped',async()=>{const f=fixture();await f.overlay.show('a',{x:10,y:20,width:100,height:200});assert.equal(f.proc().options.windowsHide,true);assert.equal(f.proc().writes[0].method,'show');f.overlay.hide('other');assert.equal(f.proc().writes.length,1);f.overlay.point({action:'click',point:{x:30,y:40}});assert.deepEqual(f.proc().writes[1],{method:'click',point:{x:30,y:40},epoch:0});f.overlay.hide('a');assert.equal(f.proc().writes.at(-1).method,'hide');f.overlay.close();assert.equal(f.proc().killed,true);});
test('stop during overlay startup cannot display a late banner',async()=>{const f=fixture();const pending=f.overlay.show('a',{x:0,y:0,width:100,height:100});f.overlay.hide();await pending;assert.equal(f.proc().writes.some(w=>w.method==='show'),false);f.overlay.close();});

test('physical Esc clears the owner before cancellation and advances the epoch',async()=>{
 let cancellations=0;const f=fixture({onCancel:()=>{cancellations++;assert.equal(f.overlay.owner,null);}});
 await f.overlay.show('a',{x:0,y:0,width:100,height:100});const oldEpoch=f.overlay.epoch;
 f.proc().stdout.emit('data','{"type":"cancel","reason":"physical_escape",');
 f.proc().stdout.emit('data','"epoch":'+oldEpoch+'}\n');assert.equal(cancellations,1);assert.ok(f.overlay.epoch>oldEpoch);assert.equal(f.proc().writes.at(-1).method,'hide');
 f.overlay.point({action:'click',point:{x:1,y:1}});assert.equal(f.proc().writes.at(-1).method,'hide');
 await f.overlay.show('b',{x:0,y:0,width:100,height:100});f.proc().stdout.emit('data',JSON.stringify({type:'cancel',reason:'physical_escape',epoch:oldEpoch})+'\n');assert.equal(cancellations,1);assert.equal(f.overlay.owner,'b');f.overlay.close();
});
test('Esc listener is armed even when the visual overlay is hidden',async()=>{
 let stopped=false;const f=fixture({onCancel:()=>{stopped=true;}});await f.overlay.show('a',{x:0,y:0,width:100,height:100},undefined,false);
 assert.equal(f.proc().writes[0].visible,false);f.proc().stdout.emit('data',JSON.stringify({type:'cancel',reason:'physical_escape',epoch:f.overlay.epoch})+'\n');assert.equal(stopped,true);f.overlay.close();
});
test('losing an active Esc listener stops control rather than continuing without it',async()=>{
 const reasons=[];const f=fixture({onCancel:e=>reasons.push(e.reason)});await f.overlay.show('a',{x:0,y:0,width:100,height:100});f.proc().emit('exit',1);assert.deepEqual(reasons,['overlay_exit']);assert.equal(f.overlay.owner,null);f.overlay.close();
});
