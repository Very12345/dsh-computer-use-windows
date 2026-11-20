import path from 'node:path';

/**
 * Surfaces that stay excluded no matter what the user configures.
 *
 * Terminals, credential stores, the OS security UI and the harness' own
 * processes are excluded structurally: operating them would let the model
 * escape the approval boundary it is supposed to stay inside.
 */
const ALWAYS_DENIED = new Set(['powershell.exe', 'pwsh.exe', 'cmd.exe', 'windowsterminal.exe', 'wt.exe', 'bash.exe', 'mintty.exe', 'wsl.exe', 'conhost.exe', 'wezterm-gui.exe', 'alacritty.exe', 'codex.exe', 'chatgpt.exe', 'lockapp.exe', 'credentialuibroker.exe', 'consent.exe', 'keepass.exe', 'keepassxc.exe', '1password.exe', 'bitwarden.exe', 'sechealthui.exe']);

/**
 * Browsers, excluded by default.
 *
 * Sites with aggressive anti-automation checks reject extension-driven control,
 * and desktop-level input is the only remaining route. The user can opt in per
 * installation, which keeps the safe default for everyone else.
 */
export const BROWSER_APPS = new Set(['chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe', 'iexplore.exe', 'browser.exe']);

/**
 * Read the browser-relaxation flag from a caller's option bag.
 * @param options - `{ allowBrowserApps }`.
 * @returns normalized options.
 */
export function policyOptions(options = {}) {
  return { allowBrowserApps: options?.allowBrowserApps === true };
}

/**
 * Normalize an executable value to its bare, lower-case file name.
 * @param value - executable path or name.
 * @returns lower-case basename.
 */
export function appName(value) { return path.win32.basename(String(value || '')).toLowerCase(); }

/**
 * Validate one executable name against the active policy.
 * @param value - executable name or path.
 * @param title - window title, checked for credential prompts.
 * @param options - `{ allowBrowserApps }`; browsers stay excluded by default.
 * @returns the normalized executable name.
 */
export function assertApp(value, title = '', options = {}) {
  const app = appName(value);
  const { allowBrowserApps } = policyOptions(options);
  if (!/^(?![.\s])[^<>:"/\\|?*\u0000-\u001f]+\.exe$/i.test(app) || app.length > 255
    || ALWAYS_DENIED.has(app)
    || (!allowBrowserApps && BROWSER_APPS.has(app))
    || /(?:password|credential|authentication|sign.?in|登录|密码|身份验证|Windows 安全中心)/i.test(title)) {
    throw new Error(allowBrowserApps
      ? 'APP_DENIED: terminal, authentication, security and password-manager surfaces are excluded.'
      : 'APP_DENIED: browser, terminal, authentication, security and password-manager surfaces are excluded. Enable browser access in Computer Use settings to operate a browser.');
  }
  return app;
}

/**
 * Normalize the saved app allowlist.
 *
 * The allowlist is validated under the same policy as live traffic, so a saved
 * `chrome.exe` cannot silently re-enable a browser while the switch is off.
 * @param values - executable names.
 * @param options - policy options.
 * @returns unique executable names.
 */
export function normalizeAllowedApps(values, options = {}) {
  if (!Array.isArray(values)) throw new Error('allowedApps must be an array of executable names.');
  return [...new Set(values.map(value => { const app = assertApp(value, '', options); if (String(value).trim().toLowerCase() !== app) throw new Error('Use an executable name, not a path or wildcard.'); return app; }))];
}

/**
 * Validate a keyboard chord and expand common aliases.
 * @param value - `+`-joined key list.
 * @returns normalized key names.
 */
export function validateKeys(value) {
  const keys = String(value || '').split('+').map(s => s.trim()).filter(Boolean);
  if (!keys.length || keys.some(k => /^(?:win(?:dows)?|meta|super|cmd|command|os|lwin|rwin)$/i.test(k))) throw new Error('KEY_DENIED: Windows key combinations are excluded.');
  const aliases = { Control_L: 'Ctrl', Control_R: 'Ctrl', Control: 'Ctrl', Shift_L: 'Shift', Shift_R: 'Shift', Alt_L: 'Alt', Alt_R: 'Alt', Return: 'Enter', Escape: 'Escape', space: 'Space', BackSpace: 'Backspace', Delete: 'Delete', period:'.',comma:',',slash:'/',question:'?',greater:'>',less:'<',Left:'Left',Right:'Right',Up:'Up',Down:'Down',Page_Up:'PageUp',Page_Down:'PageDown',KP_Enter:'Enter' };
  return keys.map(k => ['KP_Enter','Numpad_Enter'].includes(k)?'NumpadEnter':aliases[k] || (/^(?:KP_|Numpad_)([0-9])$/.test(k) ? 'Numpad'+k.at(-1) : ({KP_Add:'NumpadAdd',KP_Subtract:'NumpadSubtract',KP_Multiply:'NumpadMultiply',KP_Divide:'NumpadDivide',KP_Decimal:'NumpadDecimal',Numpad_Add:'NumpadAdd',Numpad_Subtract:'NumpadSubtract',Numpad_Multiply:'NumpadMultiply',Numpad_Divide:'NumpadDivide',Numpad_Decimal:'NumpadDecimal'}[k] || k)));
}
