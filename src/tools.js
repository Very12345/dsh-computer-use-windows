export const WINDOW = { window: { type: 'string', required: true, description: 'Opaque window id returned by this plugin for this agent.' } };
const OBSERVE = { ...WINDOW, observation_id: { type: 'string', required: true, description: 'Current unconsumed observation_id for this window.' }, requires_confirmation: { type: 'boolean', description: 'True for destructive, external communication, sensitive data, permission or payment actions. Requests native DSH approval.' }, reason: { type: 'string', description: 'User-facing reason for consequential action approval.' } };
const n = (description, required = false) => ({ type: 'number', description, ...(required ? { required: true } : {}) });
const i = { type: 'integer', description: 'Element index in current accessibility observation.' };

export const TOOL_SPECS = [
  ['list_apps', 'List launchable Windows desktop apps and their current windows. Browser/terminal/security apps are excluded.', {}],
  ['list_windows', 'List visible desktop windows with stable ids bound to owner process identity. Select exactly one before observation.', {}],
  ['launch_app', 'Launch a catalog app or an explicit existing local .exe path, without shell commands or arguments. Inspect returned windows; never blindly relaunch.', { app: { type: 'string', required: true, description: 'Returned app id or an absolute local .exe path.' } }],
  ['get_window', 'Refresh a previously returned window id. Rejects closed or replaced windows.', WINDOW],
  ['get_window_state', 'Observe a bound window. Screenshots use image-relative pixels; text provides element indexes and focus. Inspect before acting.', { ...WINDOW, include_screenshot: { type: 'boolean', description: 'Default true.' }, include_text: { type: 'boolean', description: 'Default false; true to inspect editable focus or element indexes.' } }],
  ['click', 'One click or double click on an observed element OR screenshot coordinate, followed by refreshed state. Do not reuse the old observation.', { ...OBSERVE, element_index: i, x: n('Screenshot pixel X.'), y: n('Screenshot pixel Y.'), click_count: { type: 'integer', description: '1 (default) or 2.' }, mouse_button: { type: 'string', enum: ['left','right','middle'] } }],
  ['type_text', 'Insert literal text at observed focus. Auto uses UIA or a fresh left-click visual focus; inspect the clicked screenshot first. Clipboard Unicode text is verified before paste; visual input retains it for asynchronous reading and returns dispatched, not editor-verified. Inspect fresh state before any retry; never replay unknown input.', { ...OBSERVE, text: { type: 'string', required: true }, input_mode:{type:'string',enum:['auto','uia','visual'],description:'Default auto. Visual requires the successful left click observation and its delivered screenshot; window focus and cursor must remain unchanged.'} }],
  ['press_key', 'Press one key or chord in the bound window, then refresh. X keysym modifier aliases accepted, e.g. Control_L+a, Return. Windows key is excluded.', { ...OBSERVE, key: { type: 'string', required: true } }],
  ['scroll', 'Scroll from an observed screenshot point, then refresh. Positive scrollY is down.', { ...OBSERVE, x: n('Screenshot pixel X.',true), y: n('Screenshot pixel Y.',true), scrollX: n('Horizontal scroll amount; default 0.'), scrollY: n('Vertical scroll amount; default 0.') }],
  ['drag', 'Drag between two points in the observed screenshot, then refresh.', { ...OBSERVE, from_x: n('Start screenshot X.',true), from_y: n('Start screenshot Y.',true), to_x: n('End screenshot X.',true), to_y: n('End screenshot Y.',true) }],
  ['set_value', 'Replace the entire value of an observed editable control, then read back the expected value. Do not use on existing content unless replacement is intended.', { ...OBSERVE, element_index: { ...i, required: true }, value: { type: 'string', required: true } }],
  ['secondary_action', 'Perform an auxiliary action on an observed element, then refresh. Raise applies to a Window; other actions require the matching UIA pattern.', { ...OBSERVE, element_index: { ...i, required: true }, action: { type: 'string', required: true, enum: ['invoke','toggle','select','expand','collapse','raise','Raise','scroll_up','scroll_down','scroll_left','scroll_right','Scroll Up','Scroll Down','Scroll Left','Scroll Right'] } }],
  ['activate_window', 'Bring the observed bound window forward and refresh. New state supersedes old coordinates.', OBSERVE],
  ['stop', 'Stop desktop input, cancel the owned backend, and invalidate observations. User must resume in plugin settings.', {}]
];

export async function dispatch(controller, name, args, exec) {
  const owner = exec.agent?.id || 'host';
  if (name === 'stop') { await controller.stop(); return { status: 'stopped' }; }
  if (name === 'list_apps') return controller.listApps(owner, exec.signal);
  if (name === 'list_windows') return controller.listWindows(owner, exec.signal);
  if (name === 'launch_app') return controller.launch(owner, args.app, exec);
  if (name === 'get_window') return controller.getWindow(owner, args.window, exec);
  if (name === 'get_window_state') return controller.observe(owner, args, exec);
  return controller.act(owner, name, args, exec);
}

/** Image payload is separate from the canonical JSON value and never printed. */
export function separateImage(value) {
  let image = value?._image || value?.state?._image;
  const copy = { ...value }; delete copy._image;
  if (copy.state) { copy.state = { ...copy.state }; delete copy.state._image; }
  return { value: copy, image };
}
