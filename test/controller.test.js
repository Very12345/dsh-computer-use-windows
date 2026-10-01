import test from 'node:test';
import assert from 'node:assert/strict';
import { DesktopController } from '../src/controller.js';
import { assertApp,normalizeAllowedApps,validateKeys } from '../src/policy.js';
import { FakeBackend } from './fake-backend.js';
import { png } from './png.js';

const execution=(id='a')=>({agent:{id},signal:new AbortController().signal});
async function fixture(options={}) {const backend=new FakeBackend();const controller=new DesktopController(backend,options);const exec=execution();const {windows}=await controller.listWindows('a',exec.signal);const window=windows[0].id;const state=await controller.observe('a',{window,include_text:true},exec);return {backend,controller,exec,window,state};}
const input=f=>({window:f.window,observation_id:f.state.observation_id});

test('opaque binding survives changing title; text is verified without retry',async()=>{const f=await fixture();f.backend.delayReads=2;const result=await f.controller.act('a','type_text',{...input(f),text:'hellowworl'},f.exec);assert.equal(result.status,'verified');assert.equal(result.verification.actual,'hellowworl');assert.equal(result.state.window.id,f.window);assert.equal(f.backend.calls.filter(c=>c.action==='type_text').length,1);});
test('replaced HWND owner cannot reconnect an old window id',async()=>{const f=await fixture();f.backend.window.processStartedAt='new-owner';await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1},f.exec),/Window closed|owner/);assert.equal(f.backend.calls.filter(c=>c.action==='click').length,0);});
test('observation is consumed before action and rejected on reuse',async()=>{const f=await fixture();await f.controller.act('a','click',{...input(f),element_index:1},f.exec);await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1},f.exec),/expired|consumed/);});
test('cross-agent observations and window ids are rejected',async()=>{const f=await fixture();await assert.rejects(f.controller.observe('b',{window:f.window},execution('b')),/Choose a window/);await assert.rejects(f.controller.act('b','click',{...input(f),element_index:1},execution('b')),/belongs to another/);});
test('expired observation rejects before any input',async()=>{let now=10;const f=await fixture({now:()=>now,ttlMs:10});now=25;await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1},f.exec),/expired/);});
test('screenshot pixels are scaled and mapped into moved window once',async()=>{const f=await fixture();f.backend.window.boundingBox.x+=50;f.backend.window.boundingBox.y+=30;await f.controller.act('a','click',{...input(f),x:100,y:80},f.exec);const click=f.backend.calls.find(c=>c.action==='click');assert.equal(click.args.x,350);assert.equal(click.args.y,390);});
test('resizing invalidates coordinate actions',async()=>{const f=await fixture();f.backend.window.boundingBox.width+=20;await assert.rejects(f.controller.act('a','click',{...input(f),x:10,y:10},f.exec),/resized/);});
test('occluded or absent screenshot prohibits coordinates',async()=>{const f=await fixture();f.backend.occluded=true;const state=await f.controller.observe('a',{window:f.window,include_text:true},f.exec);assert.equal(state.screenshot,null);await assert.rejects(f.controller.act('a','click',{window:f.window,observation_id:state.observation_id,x:10,y:10},f.exec),/usable screenshot/);});
test('out-of-image coordinates reject before input',async()=>{const f=await fixture();await assert.rejects(f.controller.act('a','click',{...input(f),x:500,y:10},f.exec),/inside/);});
test('focus missing forbids typing; Document focus is accepted',async()=>{const f=await fixture();f.backend.focused=false;const state=await f.controller.observe('a',{window:f.window,include_text:true},f.exec);await assert.rejects(f.controller.act('a','type_text',{window:f.window,observation_id:state.observation_id,text:'x'},f.exec),/focused editable/);});
test('failed input reports unknown and does not automatically replay',async()=>{const f=await fixture();f.backend.failAction='type_text';const result=await f.controller.act('a','type_text',{...input(f),text:'x'},f.exec);assert.equal(result.status,'outcome_unknown');assert.match(result.next,/Reobserve/);assert.equal(f.backend.calls.filter(c=>c.action==='type_text').length,1);await assert.rejects(f.controller.act('a','type_text',{...input(f),text:'x'},f.exec),/consumed/);});
test('refresh failure does not report input as not executed',async()=>{const f=await fixture();const original=f.backend.request.bind(f.backend);f.backend.request=async(a,b,s)=>{const r=await original(a,b,s);if(a==='type_text')f.backend.failAction='snapshot';return r;};const result=await f.controller.act('a','type_text',{...input(f),text:'x'},f.exec);assert.equal(result.status,'outcome_unknown');assert.equal(f.backend.calls.filter(c=>c.action==='type_text').length,1);});
test('verification timeout retains actual partial value and never resends',async()=>{const f=await fixture({verifyMs:120});f.backend.delayReads=100;const result=await f.controller.act('a','type_text',{...input(f),text:'longer'},f.exec);assert.equal(result.status,'outcome_unknown');assert.equal(result.verification.actual,'');assert.equal(f.backend.calls.filter(c=>c.action==='type_text').length,1);});
test('set_value reads the exact observed element and permits intended replacement',async()=>{const f=await fixture();f.backend.value='existing';f.state=await f.controller.observe('a',{window:f.window,include_text:true},f.exec);const result=await f.controller.act('a','set_value',{...input(f),element_index:1,value:'replacement'},f.exec);assert.equal(result.status,'verified');assert.equal(result.verification.actual,'replacement');});
test('non-empty document insertion is dispatched, not falsely verified',async()=>{const f=await fixture();f.backend.value='existing';const state=await f.controller.observe('a',{window:f.window,include_text:true},f.exec);const result=await f.controller.act('a','type_text',{window:f.window,observation_id:state.observation_id,text:'+'},f.exec);assert.equal(result.status,'dispatched');});
test('concurrent agents share a strictly serialized desktop queue',async()=>{const f=await fixture();f.backend.latency=5;await Promise.all([f.controller.listWindows('a',f.exec.signal),f.controller.listWindows('b',f.exec.signal),f.controller.listApps('a',f.exec.signal)]);assert.equal(f.backend.maxInFlight,1);});
test('rejected approval sends no input and consequential actions request it',async()=>{let deny=false,consequential=false;const f=await fixture({authorize:async(a,e,c)=>{consequential=c;if(deny)throw new Error('rejected');}});deny=true;await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1,requires_confirmation:true},f.exec),/rejected/);assert.equal(consequential,true);assert.equal(f.backend.calls.filter(c=>c.action==='click').length,0);});
test('stop invalidates running and queued work even when immediately resumed',async()=>{const f=await fixture();f.backend.latency=10;const running=f.controller.listWindows('a',f.exec.signal);const runningRejected=assert.rejects(running,/stopped/);await new Promise(r=>setTimeout(r,1));const queued=f.controller.observe('a',{window:f.window},f.exec);const rejected=assert.rejects(queued,/stopped/);f.controller.stop();f.controller.resume();await runningRejected;await rejected;await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1},f.exec),/expired|consumed/);});
test('pre-cancelled call never starts a backend request',async()=>{const f=await fixture();const abort=new AbortController();abort.abort();const before=f.backend.calls.length;await assert.rejects(f.controller.act('a','click',{...input(f),element_index:1},{...f.exec,signal:abort.signal}));assert.equal(f.backend.calls.length,before);});
test('app catalog excludes browsers and refuses arbitrary launch arguments',async()=>{const f=await fixture();const result=await f.controller.listApps('a',f.exec.signal);assert.equal(result.apps.some(a=>a.id==='chrome.exe'),false);await assert.rejects(f.controller.launch('a','notepad.exe & calc.exe',f.exec),/exact|catalog|Select/);});
test('policy excludes browsers, terminal and credentials; key aliases work',()=>{for(const a of ['chrome.exe','msedge.exe','pwsh.exe','cmd.exe','1password.exe'])assert.throws(()=>assertApp(a),/DENIED/);assert.throws(()=>normalizeAllowedApps(['C:\\Windows\\notepad.exe']),/name/);assert.throws(()=>normalizeAllowedApps(['*.exe']),/DENIED/);assert.throws(()=>validateKeys('Win+R'),/KEY_DENIED/);assert.deepEqual(validateKeys('Control_L+Shift_L+a'),['Ctrl','Shift','a']);});
test('content changed after observation refuses input without replacement',async()=>{const f=await fixture();f.backend.value='human edit';const result=await f.controller.act('a','type_text',{...input(f),text:'x'},f.exec);assert.equal(result.status,'outcome_unknown');assert.match(result.error.message,/CONTENT_CHANGED/);assert.equal(f.backend.value,'human edit');});
test('ordinary non-ASCII executable names can be authorized',()=>{assert.equal(assertApp('企业应用.exe'),'企业应用.exe');assert.deepEqual(normalizeAllowedApps(['企业应用.exe']),['企业应用.exe']);});

async function withShot(f, edit) {
  const request = f.backend.request.bind(f.backend);
  f.backend.request = async (...args) => { const result = await request(...args); if (args[0] === 'snapshot') edit(result); return result; };
  f.state = await f.controller.observe('a', { window: f.window, include_text: true }, f.exec);
}
test('legacy unscaled capture omits scale and origin; every coordinate tool still maps physical pixels', async () => {
  for (const [action, coords] of [['click',{x:200,y:160}],['scroll',{x:200,y:160,scrollY:1}],['drag',{from_x:200,from_y:160,to_x:300,to_y:260}]]) {
    const f = await fixture();
    await withShot(f, raw => { raw.screenshot.base64 = png(1000,600); delete raw.screenshot.origin; delete raw.screenshot.imageScale; });
    assert.deepEqual([f.state.screenshot.width,f.state.screenshot.height], [1000,600]);
    assert.equal((await f.controller.act('a',action,{...input(f),...coords},f.exec)).status,'dispatched');
    const dispatched = f.backend.calls.find(c => c.action === action).args;
    assert.deepEqual(action === 'drag' ? dispatched.path : {x:dispatched.x,y:dispatched.y},action === 'drag' ? [{x:300,y:360},{x:400,y:460}] : {x:300,y:360});
  }
});
test('3120x2080 physical capture uses exact PNG size and separate axis rounding, never double DPI scaling',async()=>{
  const f=await fixture();f.backend.window.boundingBox={x:-3120,y:40,width:3120,height:2080};
  await withShot(f,raw=>{raw.screenshot.base64=png(1600,1067);raw.screenshot.imageScale=0.5128;});
  assert.deepEqual([f.state.screenshot.width,f.state.screenshot.height],[1600,1067]);
  f.backend.window.boundingBox.x+=20;f.backend.window.boundingBox.y+=10;
  await f.controller.act('a','click',{...input(f),x:1599,y:1066},f.exec);
  const {x,y}=f.backend.calls.find(c=>c.action==='click').args;
  assert.equal(x,Math.round(-3120+1599*3120/1600+20));assert.equal(y,Math.round(40+1066*2080/1067+10));
});
test('UIA provider border differences do not masquerade as a window resize',async()=>{
  const f=await fixture();await withShot(f,raw=>{raw.tree.boundingBox={x:108,y:208,width:984,height:584};});
  assert.equal((await f.controller.act('a','click',{...input(f),x:100,y:80},f.exec)).status,'dispatched');
  const {x,y}=f.backend.calls.find(c=>c.action==='click').args;assert.deepEqual({x,y},{x:300,y:360});
});
test('malformed screenshot metadata disables coordinates with a useful error before input',async()=>{
  for(const edit of [s=>{s.origin=null;},s=>{s.bounds.width=0;},s=>{s.width=99;},s=>{s.imageScale=NaN;},s=>{s.base64='aGVsbG8=';}]){
    const f=await fixture();await withShot(f,raw=>edit(raw.screenshot));assert.equal(f.state.screenshot,null);assert.match(f.state.screenshot_error,/Invalid screenshot geometry/);
    await assert.rejects(f.controller.act('a','click',{...input(f),x:10,y:10},f.exec),/usable screenshot/);assert.equal(f.backend.calls.some(c=>c.action==='click'),false);
  }
});

async function visualFixture(options={}) {
 const f=await fixture(options);await withShot(f,raw=>{raw.tree.children[0].controlType='Pane';delete raw.tree.children[0].value;});return f;
}
test('visual text requires a successful click and reports dispatched without readback',async()=>{
 const f=await visualFixture();await assert.rejects(f.controller.act('a','type_text',{...input(f),text:'x'},f.exec),/fresh successful left click/);
 const clicked=await f.controller.act('a','click',{...input(f),x:50,y:50},f.exec);f.state=clicked.state;assert.equal(f.state.visual_input_ready,true);
 const r=await f.controller.act('a','type_text',{...input(f),text:'视觉'},f.exec);assert.equal(r.status,'dispatched');assert.equal(r.verification.verified,false);assert.equal(r.verification.mode,'visual');assert.equal(f.backend.calls.find(c=>c.action==='type_text').args.expectedFocusHandle,102);
});
test('visual focus expires, is lost on reobservation, and cannot use an undelivered image',async()=>{
 for(const mode of ['expiry','reobserve','unseen']){
  let now=10;const f=await visualFixture({now:()=>now});f.state=(await f.controller.act('a','click',{...input(f),x:50,y:50},f.exec)).state;
  if(mode==='expiry')now+=300001;
  if(mode==='reobserve')f.state=await f.controller.observe('a',{window:f.window,include_text:true},f.exec);
  if(mode==='unseen')f.controller.observations.get(f.state.observation_id).shot=null;
  await assert.rejects(f.controller.act('a','type_text',{...input(f),text:'x'},f.exec),/fresh successful left click|expired/);assert.equal(f.backend.calls.some(c=>c.action==='type_text'),false);
 }
});
test('right click cannot establish visual typing focus; explicit UIA mode keeps its gate',async()=>{
 const f=await visualFixture();f.state=(await f.controller.act('a','click',{...input(f),x:50,y:50,mouse_button:'right'},f.exec)).state;
 await assert.rejects(f.controller.act('a','type_text',{...input(f),text:'x'},f.exec),/fresh successful left click/);
 f.state=(await f.controller.act('a','click',{...input(f),x:50,y:50},f.exec)).state;
 await assert.rejects(f.controller.act('a','type_text',{...input(f),text:'x',input_mode:'uia'},f.exec),/focused editable/);
});
test('direct scoped focus and selection are included when tree limits omit them',async()=>{
 const f=await fixture();await withShot(f,raw=>{raw.tree.children=[];raw.focusedElement={id:'focus:edit',name:'Direct edit',controlType:'Edit',hasKeyboardFocus:true,value:''};raw.selectedText='selected';raw.accessibilityErrors=['ProviderError'];});
 assert.equal(f.state.accessibility.focused_element.name,'Direct edit');assert.equal(f.state.accessibility.selected_text,'selected');assert.deepEqual(f.state.accessibility.diagnostics,['ProviderError']);
});
test('Raise maps to window activation and rejects non-window elements',async()=>{
 const f=await fixture();await assert.rejects(f.controller.act('a','secondary_action',{...input(f),element_index:1,action:'Raise'},f.exec),/Window element/);
 const r=await f.controller.act('a','secondary_action',{...input(f),element_index:0,action:'Raise'},f.exec);assert.equal(r.status,'dispatched');assert.ok(f.backend.calls.some(c=>c.action==='activate_window'));
});
test('writable Value controls accept set_value while read-only controls do not',async()=>{
 const f=await fixture();await withShot(f,raw=>{Object.assign(raw.tree.children[0],{controlType:'ComboBox',patterns:['Value'],isReadOnly:false});});
 const r=await f.controller.act('a','set_value',{...input(f),element_index:1,value:'Beta'},f.exec);assert.equal(r.status,'verified');
 f.state=r.state;f.controller.observations.get(f.state.observation_id).elements[1].isReadOnly=true;
 await assert.rejects(f.controller.act('a','set_value',{...input(f),element_index:1,value:'Gamma'},f.exec),/writable value/);
});
test('known native pre-dispatch rejection remains distinct from uncertain input',async()=>{
 const f=await fixture();const req=f.backend.request.bind(f.backend);f.backend.request=async(a,b,s)=>{if(a==='type_text'){const e=new Error('FOCUS_CHANGED: No text sent.');e.dispatched=false;e.code='FOCUS_CHANGED';throw e;}return req(a,b,s);};
 const r=await f.controller.act('a','type_text',{...input(f),text:'x'},f.exec);assert.equal(r.status,'rejected');assert.match(r.next,/No input was sent/);assert.equal(f.backend.value,'');
});
test('numpad and punctuation aliases preserve physical key intent',()=>{assert.deepEqual(validateKeys('Control_L+KP_1'),['Ctrl','Numpad1']);assert.deepEqual(validateKeys('Numpad_Add'),['NumpadAdd']);assert.deepEqual(validateKeys('Control_L+Shift_L+period'),['Ctrl','Shift','.']);});

test('stop while the observation UI is starting cannot publish a late usable observation',async()=>{
 let armed=false;const f=await fixture({onObserve:async()=>{if(armed){await f.controller.stop();f.controller.resume();}}});armed=true;
 await assert.rejects(f.controller.observe('a',{window:f.window,include_text:true},f.exec),/stopped during observation/);assert.equal(f.controller.observations.size,0);
});
