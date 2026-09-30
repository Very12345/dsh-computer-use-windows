import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { WindowsBackend } from '../src/backend.js';
import { DesktopController } from '../src/controller.js';
if(process.platform!=='win32')throw new Error('Windows desktop required');
const backend=new WindowsBackend(),controller=new DesktopController(backend,{authorize:async(app)=>{assert.equal(app,'notepad.exe');}}),exec={agent:{id:'smoke'},signal:new AbortController().signal};
let own;
await fs.mkdir('.tmp',{recursive:true});
const file=path.resolve('.tmp','dsh-cuw-smoke-'+randomUUID()+'.txt');await fs.writeFile(file,'');
const safe = result => JSON.stringify({status:result.status,error:result.error,verification:result.verification,note:result.note});
try {
  await controller.listApps('smoke',exec.signal);
  // Fixture setup names a uniquely owned empty file. Notepad may reuse its
  // process/window and restore old tabs; never identify it by PID novelty.
  const launcher=spawn(path.join(process.env.SystemRoot,'System32/notepad.exe'),[file],{stdio:'ignore'});launcher.on('error',error=>{throw error;});
  for(let attempt=0;attempt<40;attempt++) { const candidates=(await controller.listWindows('smoke',exec.signal)).windows.filter(w=>w.app==='notepad.exe'&&w.title.includes(path.basename(file)));if(candidates.length===1){own=candidates[0].id;break;}await new Promise(r=>setTimeout(r,150)); }
  assert.ok(own,'Unique test-file window required; refusing existing user documents');
  let state=await controller.observe('smoke',{window:own,include_text:true},exec);
  assert.equal(state.accessibility.document_text,'','Fixture must start empty');
  const editable=state.accessibility.tree.split('\n').find(line=>/\] Document /.test(line));assert.ok(editable,'Editable Document required');const index=Number(editable.match(/\[(\d+)\]/)[1]);
  const clicked=await controller.act('smoke','click',{window:own,observation_id:state.observation_id,element_index:index},exec);assert.equal(clicked.status,'dispatched',safe(clicked));state=clicked.state;
  const typed=await controller.act('smoke','type_text',{window:own,observation_id:state.observation_id,text:'hellowworl'},exec);assert.equal(typed.status,'verified',safe(typed));assert.equal(typed.verification.actual,'hellowworl');assert.equal(typed.state.window.id,own);
  await fs.mkdir('.tmp',{recursive:true});if(typed.state.screenshot?.path)await fs.copyFile(typed.state.screenshot.path,'.tmp/notepad-smoke.png');
  const summary={ok:true,app:'notepad.exe',status:typed.status,actual:typed.verification.actual,windowBindingSurvivedTitleChange:true,screenshot:'.tmp/notepad-smoke.png',timestamp:new Date().toISOString()};
  const clearIndex=Number(typed.state.accessibility.tree.split('\n').find(line=>/\] Document /.test(line)).match(/\[(\d+)\]/)[1]);
  const cleared=await controller.act('smoke','set_value',{window:own,observation_id:typed.state.observation_id,element_index:clearIndex,value:''},exec);assert.equal(cleared.status,'verified',safe(cleared));
  assert.ok(cleared.state.window.title.includes(path.basename(file)),'Must still be our own file before saving');
  const saved=await controller.act('smoke','press_key',{window:own,observation_id:cleared.state.observation_id,key:'Ctrl+s'},exec);assert.equal(saved.status,'dispatched',safe(saved));
  assert.ok(saved.state.window.title.includes(path.basename(file)),'Must still be our own tab before closing');
  await controller.act('smoke','press_key',{window:own,observation_id:saved.state.observation_id,key:'Ctrl+w'},exec);own=null;
  await fs.writeFile('.tmp/smoke-result.json',JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
} finally {if(own)console.error('Smoke did not complete; its dedicated test-file tab is left open for inspection.');controller.close();}
