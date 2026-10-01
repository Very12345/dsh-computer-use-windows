import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { WindowsBackend } from '../src/backend.js';
import { DesktopController } from '../src/controller.js';
import { DesktopOverlay } from '../src/overlay.js';
if(process.platform!=='win32')throw new Error('Windows desktop required');
const overlay=new DesktopOverlay(),backend=new WindowsBackend({onActivity:event=>overlay.point(event)}),controller=new DesktopController(backend,{authorize:async(app)=>{assert.equal(app,'notepad.exe');},onObserve:(owner,rect,signal)=>overlay.show(owner,rect,signal),onStop:()=>overlay.hide()}),exec={agent:{id:'smoke'},signal:new AbortController().signal};
const nativeRequest=backend.request.bind(backend);backend.request=(action,args,signal)=>nativeRequest(action,action==='snapshot'?{...args,diagnostics:true}:args,signal);
let own;
await fs.mkdir('.tmp',{recursive:true});
const file=path.resolve('.tmp','dsh-cuw-smoke-'+randomUUID()+'.txt');await fs.writeFile(file,'');
const safe = result => JSON.stringify({status:result.status,error:result.error,verification:result.verification,note:result.note});
const metrics=async()=>JSON.parse((await promisify(execFile)(backend.executable,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./desktop-metrics.ps1',import.meta.url)),'-WindowHandle',String(controller.windows.get(own).raw.nativeWindowHandle)],{windowsHide:true,timeout:15000})).stdout);
try {
  await controller.listApps('smoke',exec.signal);
  // Fixture setup names a uniquely owned empty file. Notepad may reuse its
  // process/window and restore old tabs; never identify it by PID novelty.
  const launcher=spawn(path.join(process.env.SystemRoot,'System32/notepad.exe'),[file],{stdio:'ignore'});launcher.on('error',error=>{throw error;});
  for(let attempt=0;attempt<40;attempt++) { const candidates=(await controller.listWindows('smoke',exec.signal)).windows.filter(w=>w.app==='notepad.exe'&&w.title.includes(path.basename(file)));if(candidates.length===1){own=candidates[0].id;break;}await new Promise(r=>setTimeout(r,150)); }
  assert.ok(own,'Unique test-file window required; refusing existing user documents');
  const geometry=[];
  const request=backend.request.bind(backend);
  // Exercise native bitmap capture at scale 1 and with forced reduction.
  // Change screenshot size only; never replay an input request.
  for(const maxWidth of [0,500]) {
    backend.request=(action,args,signal)=>request(action,action==='snapshot'?{...args,maxWidth}:args,signal);
    const observed=await controller.observe('smoke',{window:own,include_text:true},exec);
    assert.equal(observed.accessibility.document_text,'','Coordinate fixture must remain empty');
    const observation=controller.observations.get(observed.observation_id),shot=observation.shot;
    assert.ok(shot,'Unobscured coordinate screenshot required');
    const bytes=await fs.readFile(observed.screenshot.path);
    assert.equal(observed.screenshot.width,bytes.readUInt32BE(16));assert.equal(observed.screenshot.height,bytes.readUInt32BE(20));
    const doc=observation.elements.find(e=>e.controlType==='Document');assert.ok(doc?.boundingBox,'Physical document bounds required');
    const physical={x:doc.boundingBox.x+doc.boundingBox.width/2,y:doc.boundingBox.y+doc.boundingBox.height/2};
    const x=Math.round((physical.x-shot.bounds.x)*observed.screenshot.width/shot.bounds.width),y=Math.round((physical.y-shot.bounds.y)*observed.screenshot.height/shot.bounds.height);
    const clicked=await controller.act('smoke','click',{window:own,observation_id:observed.observation_id,x,y},exec);assert.equal(clicked.status,'dispatched',safe(clicked));
    const cursor=await metrics();
    assert.deepEqual({x:cursor.x,y:cursor.y},{x:Math.round(shot.bounds.x+x*shot.bounds.width/shot.width),y:Math.round(shot.bounds.y+y*shot.bounds.height/shot.height)},'Actual system cursor equals the mapped physical pixel');
    assert.ok(Math.abs(cursor.x-physical.x)<=shot.bounds.width/shot.width+1,'Physical cursor X matches image click');
    assert.ok(Math.abs(cursor.y-physical.y)<=shot.bounds.height/shot.height+1,'Physical cursor Y matches image click');
    geometry.push({maxWidth,image:[shot.width,shot.height],physicalBounds:shot.bounds,cursor:{x:cursor.x,y:cursor.y},status:clicked.status});
  }
  backend.request=request;
  let state=await controller.observe('smoke',{window:own,include_text:true},exec);
  assert.equal(state.accessibility.document_text,'','Fixture must start empty');
  const editable=state.accessibility.tree.split('\n').find(line=>/\] Document /.test(line));assert.ok(editable,'Editable Document required');const index=Number(editable.match(/\[(\d+)\]/)[1]);
  const clicked=await controller.act('smoke','click',{window:own,observation_id:state.observation_id,element_index:index},exec);assert.equal(clicked.status,'dispatched',safe(clicked));state=clicked.state;
  const typed=await controller.act('smoke','type_text',{window:own,observation_id:state.observation_id,text:'hellowworl'},exec);assert.equal(typed.status,'verified',safe(typed));assert.equal(typed.verification.actual,'hellowworl');assert.equal(typed.state.window.id,own);
  await fs.mkdir('.tmp',{recursive:true});if(typed.state.screenshot?.path)await fs.copyFile(typed.state.screenshot.path,'.tmp/notepad-smoke.png');
  const screen=await metrics();
  const summary={ok:true,app:'notepad.exe',status:typed.status,actual:typed.verification.actual,geometry,physicalScreen:screen.primary,windowDpi:screen.dpi,windowBindingSurvivedTitleChange:true,screenshot:'.tmp/notepad-smoke.png',timestamp:new Date().toISOString()};
  const clearIndex=Number(typed.state.accessibility.tree.split('\n').find(line=>/\] Document /.test(line)).match(/\[(\d+)\]/)[1]);
  const cleared=await controller.act('smoke','set_value',{window:own,observation_id:typed.state.observation_id,element_index:clearIndex,value:''},exec);assert.equal(cleared.status,'verified',safe(cleared));
  assert.ok(cleared.state.window.title.includes(path.basename(file)),'Must still be our own file before saving');
  const saved=await controller.act('smoke','press_key',{window:own,observation_id:cleared.state.observation_id,key:'Ctrl+s'},exec);assert.equal(saved.status,'dispatched',safe(saved));
  assert.ok(saved.state.window.title.includes(path.basename(file)),'Must still be our own tab before closing');
  await controller.act('smoke','press_key',{window:own,observation_id:saved.state.observation_id,key:'Ctrl+w'},exec);own=null;
  await fs.writeFile('.tmp/smoke-result.json',JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
} finally {if(own)console.error('Smoke did not complete; its dedicated test-file tab is left open for inspection.');controller.close();overlay.close();}
