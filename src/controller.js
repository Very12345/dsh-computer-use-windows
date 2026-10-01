import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { assertApp, appName, validateKeys } from './policy.js';
import { normalizeScreenshot, validRect } from './screenshot.js';
import { stat } from 'node:fs/promises';

const identifier = prefix => prefix + ':' + randomUUID();
const fail = (code, message) => { const error = new Error(message); error.code = code; throw error; };
const number = (value, name) => { if (!Number.isFinite(value)) fail('INVALID_ARGUMENT', name + ' must be finite.'); return value; };
const identity = w => [w.nativeWindowHandle, w.processId, w.processStartedAt, appName(w.executable)].join(':');

/** One queue across all agents because they share one physical desktop. */
export class DesktopController {
  constructor(backend, { authorize = async () => {}, onObserve = async () => {}, onStop = () => {}, now = Date.now, ttlMs = 300000, verifyMs = 2500 } = {}) {
    this.backend = backend; this.authorize = authorize; this.now = now; this.ttlMs = ttlMs; this.verifyMs = verifyMs;
    this.onObserve = onObserve; this.onStop = onStop;
    this.windows = new Map(); this.observations = new Map(); this.apps = new Map(); this.epoch = 0; this.queue = Promise.resolve(); this.stopped = false; this.generation = 0;
  }
  serialize(fn, signal) {
    const generation = this.generation;
    const run = this.queue.catch(() => {}).then(() => { signal?.throwIfAborted(); if (this.stopped || this.generation !== generation) fail('STOPPED', 'Computer use is stopped. Obtain fresh state after resuming.'); return fn(); });
    this.queue = run; return run;
  }
  async request(action, args, signal) { const generation=this.generation;signal?.throwIfAborted(); const result = await this.backend.request(action, args, signal); signal?.throwIfAborted();if(this.stopped||this.generation!==generation)fail('STOPPED','Computer use was stopped during the request. Obtain fresh state after resuming.'); return result; }
  async enumerate(owner, signal) {
    const result = await this.request('list_windows', { maxWindows: 4096, includeInvisible: false }, signal);
    const windows = [];
    for (const raw of result.windows || []) {
      if (raw.isOffscreen || raw.boundingBox?.width < 20 || raw.boundingBox?.height < 20 || !raw.processStartedAt) continue;
      let app; try { app = assertApp(raw.executable, raw.name); } catch { continue; }
      let record = [...this.windows.values()].find(w => w.owner === owner && identity(w.raw) === identity(raw));
      if (!record) { record = { id: identifier('window'), owner, raw }; this.windows.set(record.id, record); }
      else record.raw = raw;
      if (!this.apps.has(app)) this.apps.set(app, { executable: app });
      windows.push({ id: record.id, app, title: raw.name, focused: !!raw.hasKeyboardFocus });
    }
    // Keep only current bindings for this owner; stale ids must never reconnect.
    const present = new Set(windows.map(w => w.id));
    for (const [id, record] of this.windows) if (record.owner === owner && !present.has(id)) this.windows.delete(id);
    return windows;
  }
  async listWindows(owner, signal) { return this.serialize(async () => ({ windows: await this.enumerate(owner, signal) }), signal); }
  async listApps(owner, signal) {
    return this.serialize(async () => {
      const windows = await this.enumerate(owner, signal);
      const native = await this.request('list_apps', {}, signal);
      const result = new Map();
      for (const raw of native.apps || []) {
        let app; try { app = assertApp(raw.executable); } catch { continue; }
        this.apps.set(app, { executable: raw.executable }); result.set(app, { id: app, name: raw.name || app, running: false, windows: [] });
      }
      for (const w of windows) {
        if (!result.has(w.app)) result.set(w.app, { id: w.app, name: w.app, windows: [] });
        const app = result.get(w.app); app.running = true; app.windows.push(w);
      }
      return { apps: [...result.values()] };
    }, signal);
  }
  async resolve(owner, id, signal) {
    const record = this.windows.get(id); if (!record || record.owner !== owner) fail('WINDOW_UNKNOWN', 'Choose a window returned by computer_list_windows or computer_list_apps.');
    const expected = identity(record.raw); await this.enumerate(owner, signal);
    const current = this.windows.get(id);
    if (!current || identity(current.raw) !== expected) fail('WINDOW_CHANGED', 'Window closed or its owning process changed. Select a fresh returned window.');
    assertApp(current.raw.executable, current.raw.name);
    return current;
  }
  target(record) { return { nativeWindowHandle: record.raw.nativeWindowHandle, processId: record.raw.processId, processStartedAt: record.raw.processStartedAt }; }
  async permitted(record, exec, consequential = false, reason = '') {
    await this.authorize(appName(record.raw.executable), exec, consequential, reason);
    exec.signal?.throwIfAborted();
  }
  async launch(owner, app, exec) {
    return this.serialize(async () => {
      let known = this.apps.get(String(app).toLowerCase());
      if (!known && typeof app === 'string' && /^[a-z]:[\\/]/i.test(app) && /\.exe$/i.test(app)) {
        assertApp(app);
        if (!(await stat(app).catch(() => null))?.isFile()) fail('APP_UNKNOWN', 'Explicit executable path must name an existing local .exe file.');
        known = { executable: app };
      }
      if (!known) fail('APP_UNKNOWN', 'Select an app id returned by computer_list_apps; arbitrary commands and arguments are not accepted.');
      assertApp(known.executable); await this.authorize(appName(known.executable), exec, false, 'Launch desktop app'); exec.signal?.throwIfAborted();
      this.epoch++; this.observations.clear();
      try {
        await this.request('launch_app', { executable: known.executable }, exec.signal);
        for (let i = 0; i < 20; i++) {
          const windows = (await this.enumerate(owner, exec.signal)).filter(w => w.app === appName(known.executable));
          if (windows.length) return { status: 'launched', windows, note: 'Choose exactly one returned window and observe it before input.' };
          await delay(150, undefined, { signal: exec.signal });
        }
        return { status: 'outcome_unknown', windows: [], note: 'Launch was dispatched, but no visible window was found. List windows; do not relaunch automatically.' };
      } catch (error) { return this.unknown(error); }
    }, exec.signal);
  }
  async getWindow(owner, id, exec) { return this.serialize(async () => { const w = await this.resolve(owner, id, exec.signal); return { window: { id, app: appName(w.raw.executable), title: w.raw.name } }; }, exec.signal); }
  async observe(owner, args, exec) {
    return this.serialize(async () => { const record = await this.resolve(owner, args.window, exec.signal); await this.permitted(record, exec); return this.capture(owner, record, args, exec.signal); }, exec.signal);
  }
  async capture(owner, record, args, signal) {
    const generation=this.generation;
    const includeScreenshot = args.include_screenshot !== false, includeText = args.include_text === true;
    const raw = await this.request('snapshot', { ...this.target(record), includeScreenshot, captureWindow: true, maxWidth: 1600, maxNodes: includeText ? 100 : 1, maxDepth: includeText ? 8 : 0, detailLevel: includeText ? 'full' : 'compact' }, signal);
    await this.onObserve(owner, raw.windowBounds || record.raw.boundingBox, signal);
    if(this.stopped||this.generation!==generation)fail('STOPPED','Computer use was stopped during observation. Obtain fresh state after resuming.');
    const elements = [], text = [];
    const walk = (node, depth = 0) => {
      if (!node) return; const index = elements.length;
      elements.push(node);
      text.push(' '.repeat(depth * 2) + `[${index}] ${node.controlType || ''} ${node.name || ''}` + (node.hasKeyboardFocus ? ' [focused]' : '') + (node.isEnabled === false ? ' [disabled]' : '') + (node.patterns?.length ? ` [patterns: ${node.patterns.join(', ')}]` : ''));
      for (const child of node.children || []) walk(child, depth + 1);
    };
    if (includeText) walk(raw.tree);
    if (includeText && raw.focusedElement && !elements.some(e => e.id === raw.focusedElement.id)) walk(raw.focusedElement);
    let shot = null, screenshotError = '';
    if (raw.screenshot?.base64 && !raw.screenshot.occludedPossible && !raw.screenshot.windowCaptureFailed) {
      try { shot = normalizeScreenshot(raw.screenshot); } catch (error) { screenshotError = error.message; }
    }
    const usableImage = !!shot;
    const id = identifier('observation');
    // An observation supersedes earlier observations for the same owner/window.
    for (const [key, value] of this.observations) if (value.owner === owner && value.window === record.id) this.observations.delete(key);
    // Window enumeration and layout checks share Win32 bounds. A provider's UIA
    // root can exclude borders or report a different rectangle altogether.
    const observed = { id, owner, window: record.id, epoch: this.epoch, time: this.now(), elements, inputFocus: raw.inputFocus, rect: { ...(raw.windowBounds || record.raw.boundingBox) }, shot: usableImage ? { ...shot, base64: undefined } : null };
    this.observations.set(id, observed);
    for (const [key, value] of this.observations) if (this.now() - value.time > this.ttlMs) this.observations.delete(key);
    const focused = elements.find(e => e.hasKeyboardFocus && ['Document','Edit'].includes(e.controlType)) || elements.find(e => e.hasKeyboardFocus);
    const document = elements.find(e => ['Document', 'Edit'].includes(e.controlType));
    return {
      status: 'observed', window: { id: record.id, app: appName(record.raw.executable), title: raw.tree?.name || record.raw.name }, observation_id: id,
      accessibility: includeText ? { tree: text.join('\n'), truncated: !!raw.truncated, focused_element: focused ? { index: elements.indexOf(focused), role: focused.controlType, name: focused.name } : null, document_text: document?.value ?? null, selected_text: raw.selectedText ?? null, selected_elements:elements.filter(e=>e.isSelected).map(e=>`[${elements.indexOf(e)}] ${e.controlType} ${e.name}`), diagnostics: raw.accessibilityErrors || [], elements:elements.map((e,index)=>({index,role:e.controlType,name:e.name,patterns:e.patterns || [],read_only:e.isReadOnly,focused:!!e.hasKeyboardFocus})) } : null,
      screenshot: usableImage ? { id, width: shot.width, height: shot.height, coordinate_space: 'screenshot_pixels', method: shot.method, path: shot.path } : null,
      ...(includeScreenshot && !usableImage ? { screenshot_error: screenshotError || 'No unobscured target screenshot. Bring the app forward and reobserve; coordinates are disabled.' } : {}),
      _image: usableImage ? { data: shot.base64, mediaType: 'image/png' } : null
    };
  }
  observation(owner, args) {
    const observed = this.observations.get(args.observation_id);
    if (!observed || observed.owner !== owner || observed.window !== args.window || observed.epoch !== this.epoch || this.now() - observed.time > this.ttlMs) fail('STALE_OBSERVATION', 'Observe the target window again; this observation is expired, consumed, or belongs to another window/agent. No input sent.');
    return observed;
  }
  element(observed, index) {
    if (!Number.isInteger(index) || index < 0 || index >= observed.elements.length) fail('ELEMENT_UNKNOWN', 'Use an element index from this observation.');
    const element = observed.elements[index]; if (!element.id || element.isEnabled === false || element.isOffscreen) fail('ELEMENT_UNAVAILABLE', 'Target element is unavailable. Reobserve.');
    return element.id;
  }
  point(observed, record, x, y) {
    const shot = observed.shot; if (!shot) fail('SCREENSHOT_REQUIRED', 'Observe a usable screenshot before using coordinates.');
    const rect = record.raw.boundingBox;
    if (!validRect(rect) || !validRect(observed.rect)) fail('WINDOW_GEOMETRY_REQUIRED', 'Window geometry is unavailable. Reobserve before coordinate input.');
    if (rect.width !== observed.rect.width || rect.height !== observed.rect.height) fail('LAYOUT_CHANGED', 'Window resized since capture. Reobserve before clicking.');
    number(x, 'x'); number(y, 'y');
    const { width, height } = shot;
    if (x < 0 || y < 0 || x >= width || y >= height) fail('POINT_OUTSIDE', 'Coordinates must fall inside the returned screenshot.');
    return { x: Math.round(shot.origin.x + x / shot.scaleX + rect.x - observed.rect.x), y: Math.round(shot.origin.y + y / shot.scaleY + rect.y - observed.rect.y) };
  }
  unknown(error, action) {
    if (error.dispatched===false) return {status:'rejected',action,error:{code:error.code || 'INPUT_REJECTED',message:error.message},next:'No input was sent. Obtain fresh state and resolve the reported condition before another action.'};
    return { status: 'outcome_unknown', action, error: { code: error.code || 'WINDOWS_ERROR', message: error.message }, next: 'Reobserve before retrying. A failed refresh does not mean the action was not applied.' };
  }
  async act(owner, action, args, exec) {
    return this.serialize(async () => {
      const observed = this.observation(owner, args); let record = await this.resolve(owner, args.window, exec.signal);
      await this.permitted(record, exec, args.requires_confirmation === true, args.reason || action);
      // Approval waits can change the window or expire the observation.
      this.observation(owner, args); record = await this.resolve(owner, args.window, exec.signal);
      const target = this.target(record); let operation, extra = {}, expected;
      switch (action) {
        case 'click': {
          if (args.element_index !== undefined && (args.x !== undefined || args.y !== undefined)) fail('INVALID_ARGUMENT', 'Choose element_index OR coordinates.');
          extra = args.element_index !== undefined ? { elementId: this.element(observed, args.element_index) } : this.point(observed, record, args.x, args.y);
          if (![1, 2].includes(args.click_count ?? 1)) fail('INVALID_ARGUMENT', 'click_count must be 1 or 2.');
          if (!['left','right','middle'].includes(args.mouse_button || 'left')) fail('INVALID_ARGUMENT', 'Invalid mouse button.');
          operation = args.click_count === 2 ? 'double_click' : 'click'; extra.button = args.mouse_button || 'left'; extra.dispatch = 'foreground'; break;
        }
        case 'press_key': operation = 'keypress'; extra.keys = validateKeys(args.key); extra.dispatch = 'foreground'; break;
        case 'type_text': {
          if (typeof args.text !== 'string' || !args.text.length || args.text.length > 20000) fail('INVALID_ARGUMENT', 'text must contain 1–20000 characters.');
          if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(args.text)) fail('INVALID_ARGUMENT', 'Use press_key for control characters.');
          if (!['auto','uia','visual'].includes(args.input_mode || 'auto')) fail('INVALID_ARGUMENT','input_mode must be auto, uia or visual.');
          const focused = observed.elements.find(e => e.hasKeyboardFocus && ['Edit','Document'].includes(e.controlType));
          if (args.input_mode === 'visual' || (!focused && args.input_mode !== 'uia')) {
            const anchor = observed.visualAnchor;
            if (!observed.shot || !anchor) fail('FOCUS_REQUIRED', 'A focused editable element or a fresh successful left click with a delivered screenshot is required. Inspect the clicked input surface before visual typing.');
            if (!validRect(record.raw.boundingBox) || record.raw.boundingBox.width !== observed.rect.width || record.raw.boundingBox.height !== observed.rect.height) fail('LAYOUT_CHANGED','Window resized after visual focus. Click the input surface again.');
            if (observed.elements.some(e => e.hasKeyboardFocus && e.isPassword)) fail('APP_DENIED','Password entry is excluded.');
            operation='type_text';extra={text:args.text,method:'clipboard',restoreClipboard:true,visual:true,expectedFocusHandle:anchor.focusHandle,expectedCursor:anchor.cursor};
            break;
          }
          if (!focused) fail('FOCUS_REQUIRED', 'Observe accessibility with a focused editable element immediately before typing.');
          if (focused.isPassword) fail('APP_DENIED', 'Password entry is excluded.');
          operation = 'type_text'; extra = { text: args.text, method: 'clipboard', restoreClipboard: true, elementId: focused.id };
          extra.expectedPriorValue = focused.value;
          expected = typeof focused.value === 'string' && focused.value === '' ? args.text : undefined; break;
        }
        case 'set_value': {
          const elementId = this.element(observed, args.element_index), element = observed.elements[args.element_index];
          if (element.isPassword || element.isReadOnly === true || (!['Document','Edit'].includes(element.controlType) && !element.patterns?.includes('Value'))) fail('ELEMENT_NOT_EDITABLE','Choose an observed editable, non-password control with a writable value.');
          if (typeof args.value !== 'string' || args.value.length > 20000) fail('INVALID_ARGUMENT','value must be a string with at most 20000 characters.');
          operation = 'set_value'; extra = { elementId, value: args.value, expectedPriorValue: element.value }; expected = args.value; break;
        }
        case 'scroll': operation = 'scroll'; extra = { ...this.point(observed, record, args.x, args.y), deltaX: number(args.scrollX ?? 0, 'scrollX'), deltaY: number(args.scrollY ?? 0, 'scrollY') }; break;
        case 'drag': {
          const from = this.point(observed, record, args.from_x, args.from_y), to = this.point(observed, record, args.to_x, args.to_y);
          operation = 'drag'; extra = { path: [from, to], durationMs: 350 }; break;
        }
        case 'secondary_action': {
          const semantic = String(args.action).toLowerCase().replace(/\s+/g,'_');
          const map = { invoke:'invoke',toggle:'toggle',select:'select',expand:'expand',collapse:'collapse',scroll_up:'scroll_up',scroll_down:'scroll_down',scroll_left:'scroll_left',scroll_right:'scroll_right' };
          if (semantic==='raise') {
            this.element(observed,args.element_index);
            if (observed.elements[args.element_index].controlType!=='Window') fail('INVALID_ARGUMENT','Raise requires an observed Window element.');
            operation='activate_window';break;
          }
          if (!map[semantic]) fail('INVALID_ARGUMENT', 'Unknown observed auxiliary action.');
          operation = 'invoke'; extra = { elementId: this.element(observed, args.element_index), pattern: map[semantic] }; break;
        }
        case 'activate_window': operation = 'activate_window'; break;
        default: fail('INVALID_ARGUMENT', 'Unsupported desktop action.');
      }
      // Consume before dispatch. Any ambiguous completion invalidates all prior state.
      this.epoch++; this.observations.clear();
      let result;
      try { result = await this.request(operation, { ...target, ...extra, activate: true }, exec.signal); }
      catch (error) { return this.unknown(error, action); }
      try {
        record = await this.resolve(owner, args.window, exec.signal);
        let state = await this.capture(owner, record, { include_screenshot: true, include_text: true }, exec.signal);
        if (action==='click' && (args.mouse_button || 'left')==='left') {
          const current=this.observations.get(state.observation_id);
          if (current.shot && current.inputFocus?.belongsToTarget && current.inputFocus.nativeWindowHandle) {
            current.visualAnchor={time:this.now(),focusHandle:current.inputFocus.nativeWindowHandle,cursor:current.inputFocus.cursor};
            state.visual_input_ready=true;
          }
        }
        if (expected !== undefined) {
          const until = this.now() + this.verifyMs;
          const readValue = () => extra.elementId ? this.observations.get(state.observation_id)?.elements.find(e => e.id === extra.elementId)?.value : state.accessibility.document_text;
          while (readValue() !== expected && this.now() < until) {
            await delay(100, undefined, { signal: exec.signal });
            record = await this.resolve(owner, args.window, exec.signal); state = await this.capture(owner, record, { include_screenshot: true, include_text: true }, exec.signal);
          }
          return { status: readValue() === expected ? 'verified' : 'outcome_unknown', action, verification: { expected, actual: readValue() ?? null }, state, ...(readValue() !== expected ? { next: 'Input was dispatched. Inspect the refreshed state; do not blindly resend text.' } : {}) };
        }
        return { status: 'dispatched', action, method: result.method || operation, state, ...(extra.visual ? { verification: { mode:'visual',verified:false }, note:'Text was dispatched to the visually focused surface. Inspect the refreshed screenshot; no text readback is available. Do not blindly resend.' } : { note:'Refreshed state is evidence; inspect it before deciding the next action.' }) };
      } catch (error) { return this.unknown(error, action); }
    }, exec.signal);
  }
  stop() { this.stopped = true; this.generation++; this.epoch++; this.observations.clear(); this.onStop(); return this.backend.stop(); }
  resume() { this.stopped = false; }
  close() { this.stop(); this.windows.clear(); this.backend.close(); }
  releaseOwner(owner) { for (const [id,w] of this.windows) if (w.owner === owner) this.windows.delete(id); for (const [id,s] of this.observations) if (s.owner === owner) this.observations.delete(id); }
}
