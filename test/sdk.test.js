import test from 'node:test';
import assert from 'node:assert/strict';
import { FakeBackend } from './fake-backend.js';

async function setup(t) {
  let C,tools,prompt,skills,Plugin;
  try { C=(await import('@deepseek-ai/cordis')).Context;tools=await import('@deepseek-ai/dsh-tools');prompt=await import('@deepseek-ai/dsh-system-prompt');skills=await import('@deepseek-ai/dsh-skill');Plugin=(await import('../src/index.js')).default; }
  catch(error){if(process.env.DSH_CU_REQUIRE_SDK==='1'||error.code!=='ERR_MODULE_NOT_FOUND')throw error;t.skip('Host SDK peers required: '+error.message);return;}
  const root=new C();root.provide('ptcRuntime',{language:'python'});root.provide('sessionProjections',{register:()=>()=>{},stateOf:()=>undefined});
  let config;root.provide('settings',{configure(){},async update(namespace,patch){for(const[k,v]of Object.entries(patch))config[k]={get:()=>v};}});
  const stored=[];root.provide('attachments',{saveImages:async(images)=>{stored.push(images);return [{attachmentId:'sha256:'+'a'.repeat(64),mediaType:'image/png',byteLength:5,width:10,height:10}];}});
  root.provide('llm',{resolveModelInfo:async()=>({inputModalities:['text','image']})});
  const pf=root.plugin(prompt.default),tf=root.plugin(tools.default),sf=root.plugin(skills.default);
  await Promise.all([pf.await(),tf.await(),sf.await()]);
  const fiber=root.plugin(Plugin,{enabled:true,allowedApps:['notepad.exe']});await fiber.await();const plugin=root.get('computerUseWindows');config=plugin.config;
  plugin.backend.close();plugin.controller.backend=new FakeBackend();
  t.after(async()=>{await fiber.dispose();await sf.dispose();await tf.dispose();await pf.dispose();});
  const agent={id:'sdk',options:{provider:'test',model:'vision'},session:{append(){}}};
  const scope=(await import('@deepseek-ai/dsh-scope')).createScope(root,agent);agent.ctx=scope.ctx;t.after(()=>scope.dispose());
  const invoke=(name,args={})=>root.get('tools').execute({name,arguments:args,callId:'test-'+Math.random(),signal:new AbortController().signal,agent,cwd:process.cwd()});
  return {root,plugin,agent,invoke,stored,tools};
}
test('real DSH SDK registers native tools, skill and safe screenshot projection',async(t)=>{
  const f=await setup(t);if(!f)return;
  assert.equal(f.root.get('tools').schemas(f.agent).filter(x=>x.name.startsWith('computer_')).length,14);
  const skill=await f.root.get('skills').get('windows-desktop');assert.match(skill.content,/outcome_unknown/);
  const listed=await f.invoke('computer_list_windows');assert.equal(listed.isError,false,JSON.stringify(listed));const window=JSON.parse(listed.value).windows[0].id;
  const observed=await f.invoke('computer_get_window_state',{window,include_text:true});assert.equal(observed.isError,false,JSON.stringify(observed));assert.ok(observed.content.some(c=>c.type==='image'));assert.ok(!observed.value.includes('aGVsbG8='));assert.equal(f.stored.length,1);
  const state=JSON.parse(observed.value);const typed=await f.invoke('computer_type_text',{window,observation_id:state.observation_id,text:'hellowworl'});assert.equal(typed.isError,false,JSON.stringify(typed));assert.equal(JSON.parse(typed.value).status,'verified');
  f.agent.ctx.get('tools').presentAs('ptc');assert.deepEqual(f.root.get('tools').wireSchemas(f.agent).schemas.map(x=>x.name),['run_code']);assert.ok(f.root.get('tools').sdkSchemas(f.agent).some(x=>x.name==='computer_click'));
});
test('native guard rejects superseded wincu calls and approvals fail closed',async(t)=>{
  const f=await setup(t);if(!f)return;
  let called=false;f.root.get('tools').register(f.tools.defineTool({name:'mcp__wincu__windows_computer_use_click',description:'old controller',parameters:{},output:{schema:{type:'string'},render:(_a,v)=>[{type:'text',text:v}]},execute:async()=>{called=true;return 'bad';}}));
  const denied=await f.invoke('mcp__wincu__windows_computer_use_click');assert.equal(denied.isError,true);assert.equal(called,false);
  const listed=await f.invoke('computer_list_windows');const window=JSON.parse(listed.value).windows[0].id;const state=JSON.parse((await f.invoke('computer_get_window_state',{window,include_text:true})).value);
  const rejected=await f.invoke('computer_click',{window,observation_id:state.observation_id,element_index:1,requires_confirmation:true,reason:'delete'});assert.equal(rejected.isError,true);assert.ok(!f.plugin.controller.backend.calls.some(c=>c.action==='click'));
});
test('text-only route preserves outcome but disables unseen coordinates',async(t)=>{
  const f=await setup(t);if(!f)return;f.root.get('llm').resolveModelInfo=async()=>({inputModalities:['text']});
  const window=JSON.parse((await f.invoke('computer_list_windows')).value).windows[0].id;
  const observed=await f.invoke('computer_get_window_state',{window,include_text:true});const state=JSON.parse(observed.value);assert.match(state.image_delivery_error,/image input/);assert.ok(!observed.content.some(c=>c.type==='image'));
  const rejected=await f.invoke('computer_click',{window,observation_id:state.observation_id,x:10,y:10});assert.equal(rejected.isError,true);
});
