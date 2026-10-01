import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { DesktopOverlay } from '../src/overlay.js';

function fixture(){let proc;const spawnProcess=(exe,args,options)=>{proc=new EventEmitter();proc.stdout=new EventEmitter();proc.stderr=new EventEmitter();proc.stdin=new EventEmitter();proc.writes=[];proc.stdin.write=line=>proc.writes.push(JSON.parse(line));proc.kill=()=>proc.killed=true;proc.options=options;queueMicrotask(()=>proc.stdout.emit('data','{"ready":true}\n'));return proc;};return {overlay:new DesktopOverlay({spawnProcess,platform:'win32'}),proc:()=>proc};}
test('overlay is lazy, non-console and owner-scoped',async()=>{const f=fixture();await f.overlay.show('a',{x:10,y:20,width:100,height:200});assert.equal(f.proc().options.windowsHide,true);assert.equal(f.proc().writes[0].method,'show');f.overlay.hide('other');assert.equal(f.proc().writes.length,1);f.overlay.point({action:'click',point:{x:30,y:40}});assert.deepEqual(f.proc().writes[1],{method:'click',point:{x:30,y:40}});f.overlay.hide('a');assert.equal(f.proc().writes.at(-1).method,'hide');f.overlay.close();assert.equal(f.proc().killed,true);});
test('stop during overlay startup cannot display a late banner',async()=>{const f=fixture();const pending=f.overlay.show('a',{x:0,y:0,width:100,height:100});f.overlay.hide();await pending;assert.equal(f.proc().writes.some(w=>w.method==='show'),false);f.overlay.close();});
