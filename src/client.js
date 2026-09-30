window.__ModuleLoader__.load({
  id: '@very12345/dsh-computer-use-windows',
  factory: require => {
    const R = require('react'), h = R.createElement, route = '/plugins/computer-use-windows';
    function apply(ctx) {
      function Settings() {
        const [state,setState] = R.useState(null), [apps,setApps] = R.useState(''), [busy,setBusy] = R.useState(false), [error,setError] = R.useState('');
        const load = () => fetch(route).then(r=>r.json()).then(s=>{setState(s);setApps((s.allowedApps||[]).join('\n'));});
        R.useEffect(()=>{ let live=true; fetch(route).then(r=>r.json()).then(s=>{if(live){setState(s);setApps((s.allowedApps||[]).join('\n'));}}).catch(e=>{if(live)setError(e.message);});return()=>{live=false;}; },[]);
        const change = async input => {
          setBusy(true);setError('');
          try { const r=await fetch(route,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(input)});const s=await r.json();if(!r.ok||!s.ok)throw new Error(s.error||'操作失败');setState(s); }
          catch(e){setError(e.message);}finally{setBusy(false);}
        };
        const button = (label,callback,color='#2455db')=>h('button',{type:'button',disabled:busy||!state?.supported,onClick:callback,style:{background:color,color:'#fff',border:'1px solid transparent',borderRadius:8,padding:'8px 14px',marginRight:10,font:'inherit',cursor:'pointer'}},label);
        return h('section',{style:{color:'var(--dsw-alias-label-primary, #1f2937)',maxWidth:760,padding:'16px 0'}},
          h('h3',null,'Windows Computer Use'),
          h('p',null,'操作 Windows 桌面应用：绑定窗口、截图与无障碍树、点击、输入、滚动和拖拽。浏览器操作由独立浏览器插件负责。'),
          button(busy?'处理中…':state?.enabled&&!state?.stopped?'已开启 · 点击关闭':'开启 / 恢复',()=>change({enabled:!state?.enabled||state?.stopped})),
          button('立即停止',()=>change({stop:true}),'#b42318'),
          h('p',null,'当前状态：',state?.enabled?(state?.stopped?'已停止，需点击恢复':'已开启'):'已关闭'),
          h('label',{htmlFor:'computer-use-allowed-apps'},'始终允许的应用（每行一个 .exe 名称）'),
          h('textarea',{id:'computer-use-allowed-apps',rows:5,value:apps,onChange:e=>setApps(e.target.value),placeholder:'notepad.exe\nmspaint.exe\ncalc.exe',style:{display:'block',width:'100%',boxSizing:'border-box',margin:'8px 0',padding:10,borderRadius:8,border:'1px solid var(--dsw-alias-border-l3, #c8cdd8)',background:'var(--dsw-alias-bg-module-platform, #fff)',color:'var(--dsw-alias-label-primary, #1f2937)',font:'inherit'}}),
          button('保存应用授权',()=>change({allowedApps:apps.split(/[\n,]+/).map(s=>s.trim()).filter(Boolean)})),
          h('p',{style:{fontSize:12,color:'var(--dsw-alias-label-secondary, #525b6a)'}},'不在列表中的应用通过 DSH 请求会话授权。审批关闭时请先在此授权。应用授权不代替删除、发送和支付等操作的确认。Windows 输入占用前台，运行时请勿同时操作鼠标键盘。'),
          h('p',{style:{fontSize:12}},'禁用或停止会取消插件拥有的输入进程；再次开启后须重新观察。旧 wincu 工具在本插件开启时被拦截，建议卸载旧插件。'),
          error?h('p',{role:'alert',style:{color:'#b42318'}},error):null);
      }
      ctx.slots.inject('settings.section',()=>ctx.slots.register({name:'settings.section',id:'computer-use-windows',label:'Windows Computer Use',order:47},Settings));
    }
    return {name:'computer-use-windows-client',inject:['slots'],apply};
  }
});
