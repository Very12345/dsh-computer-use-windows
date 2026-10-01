import { readFileSync } from 'node:fs';
import { defineTool } from '@deepseek-ai/dsh-tools';
import z from '@deepseek-ai/schemastery';
import { WindowsBackend } from './backend.js';
import { DesktopController } from './controller.js';
import { DesktopOverlay } from './overlay.js';
import { normalizeAllowedApps } from './policy.js';
import { TOOL_SPECS, dispatch, separateImage } from './tools.js';

const valueOf = value => value?.get ? value.get() : value;
export const ROUTE = '/plugins/computer-use-windows';
export const SKILL = readFileSync(new URL('../skills/SKILL.md', import.meta.url), 'utf8');

export class ComputerUseWindows {
  static inject = ['tools','systemPrompt','settings'];
  static Config = z.object({ enabled: z.boolean().default(true).volatile(), showOverlay: z.boolean().default(true).volatile(), accessMode: z.union(['desktop','selected']).default('desktop').volatile(), allowedApps: z.array(z.string()).default([]).volatile() });
  constructor(ctx, config) {
    this.ctx = ctx; this.config = config; this.grants = new Map(); this.error = ''; this.lastEnabled = this.enabled; this.manualStopEpoch = 0;
    this.overlay = new DesktopOverlay();
    this.backend = new WindowsBackend({ onActivity: event => { if(this.showOverlay)this.overlay.point(event); } });
    this.controller = new DesktopController(this.backend, { authorize: (app, exec, consequential, reason) => this.authorize(app, exec, consequential, reason), onObserve: (owner,rect,signal) => this.showOverlay ? this.overlay.show(owner,rect,signal) : undefined, onStop: () => this.overlay.hide() });
    ctx.effect(() => ctx.settings.configure({ auto: false }));
    ctx.provide('computerUseWindows', this);
    ctx.on('agent/disposed', ({ agent }) => { this.overlay.hide(agent.id);this.controller.releaseOwner(agent.id); this.grants.delete(agent.id); });
    ctx.on('agent/turn-stopping', ({ agent }) => { if(agent)this.overlay.hide(agent.id); });
    ctx.on('agent/status', ({ agent,status }) => { if(agent&&status==='idle')this.overlay.hide(agent.id); });
    ctx.on('settings/document-updated', namespace => { if (namespace === 'computer-use-windows') { const active = !this.controller.stopped; this.grants.clear(); this.controller.stop(); if (this.enabled && active) this.controller.resume(); this.lastEnabled = this.enabled; } });
    ctx.effect(() => () => { this.controller.close();this.overlay.close(); });
    if (!this.enabled) this.controller.stop();
    ctx.effect(() => ctx.systemPrompt.section({ name: 'computer-use-windows:workflow', order: 920, text: () => this.enabled && process.platform === 'win32' ? SKILL : '' }));
    ctx.inject(['skills'], scope => scope.skills.register({ name: 'windows-desktop', description: 'Operate native Windows desktop apps using bound windows and verified computer_* tools. Browser control is excluded.', content: SKILL, source: '@very12345/dsh-computer-use-windows', invocation: { modelInvocable: true, userInvocable: true } }));
    ctx.inject(['webServer'], scope => this.routes(scope));
    for (const [method, description, parameters] of TOOL_SPECS) {
      const projections = new WeakMap();
      ctx.tools.register(defineTool({
        name: 'computer_' + method, description, parameters, timeoutMs: 120000,
        output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
        isConcurrencySafe: () => false,
        execute: async (args, exec) => {
          if (process.platform !== 'win32') throw new Error('Windows desktop required.');
          if (!this.enabled && method !== 'stop') throw new Error('Computer use is disabled in settings.');
          if (method === 'stop') this.manualStopEpoch++;
          const { value, image } = separateImage(await dispatch(this.controller, method, args, exec));
          const text = JSON.stringify(value);
          if (image) {
            try {
              const attachments = ctx.get('attachments'), llm = ctx.get('llm');
              const route = exec.agent?.session.requestHeader?.()?.config || exec.agent?.options;
              const info = route && await llm?.resolveModelInfo(route.provider, route.model, exec.signal);
              if (!attachments || !info?.inputModalities?.includes('image')) throw new Error('Current model route does not declare image input or attachment storage is unavailable.');
              exec.signal.throwIfAborted();
              const [ref] = await attachments.saveImages([{ data: Buffer.from(image.data,'base64'), mediaType: image.mediaType }]);
              projections.set(exec, { text, content: [{ type: 'text', text }, { type: 'image', attachment: ref }] });
            } catch (error) {
              // Preserve the actual action outcome even if visual delivery fails.
              value.image_delivery_error = error.message;
              const observation = this.controller.observations.get(value.observation_id || value.state?.observation_id);
              if (observation) { observation.shot = null; delete observation.visualAnchor; }
              if (value.state?.visual_input_ready) value.state.visual_input_ready=false;
              return JSON.stringify(value);
            }
          }
          return text;
        },
        projectContent: (exec, result) => { const hit = projections.get(exec); projections.delete(exec); return hit && !result.isError && result.value === hit.text && result.content?.length === 1 && result.content[0].text === hit.text ? hit.content : undefined; }
      }));
    }
    // Keep one desktop owner when replacing the older MCP plugin, even on reload.
    ctx.effect(() => ctx.tools.guard(exec => exec.name?.startsWith('mcp__wincu__') && this.enabled ? 'Use computer_* from the Windows desktop plugin; the old wincu controller is superseded.' : undefined));
  }
  get enabled() { return valueOf(this.config.enabled) === true; }
  get showOverlay() { return valueOf(this.config.showOverlay) !== false; }
  get accessMode() { return valueOf(this.config.accessMode) || 'desktop'; }
  get allowedApps() { return normalizeAllowedApps(valueOf(this.config.allowedApps) || []); }
  async authorize(app, exec, consequential, reason) {
    const owner = exec.agent?.id || 'host';
    if (!consequential && (this.accessMode === 'desktop' || this.allowedApps.includes(app) || this.grants.get(owner)?.has(app))) return;
    const approval = this.ctx.get('approval');
    if (!exec.agent || !approval) throw new Error('APP_APPROVAL_REQUIRED: allow ' + app + ' in Computer Use settings, or enable DSH native approval.');
    const outcome = await approval.request({ agent: exec.agent, callId: exec.callId, toolName: 'computer_use_windows', signal: exec.signal, reason: consequential ? `Windows 操作需要确认：${reason}（${app}）` : `允许此会话使用 Windows 桌面应用 ${app}？` });
    if (outcome !== 'allowed-once') throw new Error('APP_APPROVAL_REJECTED: ' + outcome);
    if (!consequential) { if (!this.grants.has(owner)) this.grants.set(owner,new Set()); this.grants.get(owner).add(app); }
  }
  status() { return { ok: true, enabled: this.enabled, stopped: this.controller.stopped, supported: process.platform === 'win32', showOverlay:this.showOverlay, accessMode: this.accessMode, allowedApps: this.allowedApps, error: this.error }; }
  routes(ctx) {
    const send = (res, status, data) => { res.writeHead(status, { 'Content-Type':'application/json', 'Cache-Control':'no-store' }); res.end(JSON.stringify(data)); };
    ctx.effect(() => ctx.webServer.register({ kind: 'exact', path: ROUTE, handler: async (req, res) => {
      if (req.method === 'GET') return send(res,200,this.status());
      if (req.method !== 'POST') return send(res,405,{ ok:false,error:'Method not allowed' });
      try {
        let raw = ''; for await (const chunk of req) { raw += chunk; if (raw.length > 8192) throw new Error('Request too large'); }
        const input = JSON.parse(raw || '{}');
        if (input.stop === true) { this.manualStopEpoch++; await this.controller.stop(); return send(res,200,this.status()); }
        const update = {};
        if (input.enabled !== undefined) { if (typeof input.enabled !== 'boolean') throw new Error('enabled must be boolean'); update.enabled = input.enabled; }
        if (input.showOverlay !== undefined) { if (typeof input.showOverlay !== 'boolean') throw new Error('showOverlay must be boolean');update.showOverlay=input.showOverlay; }
        if (input.accessMode !== undefined) { if (!['desktop','selected'].includes(input.accessMode)) throw new Error('Unknown application access mode'); update.accessMode = input.accessMode; }
        if (input.allowedApps !== undefined) update.allowedApps = normalizeAllowedApps(input.allowedApps);
        const resume = input.enabled === true || (input.enabled !== false && !this.controller.stopped);
        const stopEpoch = this.manualStopEpoch;
        await this.ctx.settings.update('computer-use-windows', update);
        this.grants.clear(); await this.controller.stop(); if (this.enabled && resume && this.manualStopEpoch === stopEpoch) this.controller.resume(); this.lastEnabled = this.enabled; this.error = '';
        return send(res,200,this.status());
      } catch (error) { this.error = error.message; return send(res,400,{ ...this.status(),ok:false }); }
    } }));
  }
}
export default ComputerUseWindows;
