import path from 'node:path';

const DENIED_APPS = new Set(['chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe', 'iexplore.exe', 'browser.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'windowsterminal.exe', 'wt.exe', 'bash.exe', 'mintty.exe', 'wsl.exe', 'conhost.exe', 'wezterm-gui.exe', 'alacritty.exe', 'codex.exe', 'chatgpt.exe', 'lockapp.exe', 'credentialuibroker.exe', 'consent.exe', 'keepass.exe', 'keepassxc.exe', '1password.exe', 'bitwarden.exe', 'sechealthui.exe']);
export function appName(value) { return path.win32.basename(String(value || '')).toLowerCase(); }
export function assertApp(value, title = '') {
  const app = appName(value);
  if (!/^[a-z0-9][a-z0-9._ -]*\.exe$/.test(app) || DENIED_APPS.has(app) || /(?:password|credential|authentication|sign.?in|登录|密码|身份验证|Windows 安全中心)/i.test(title)) throw new Error('APP_DENIED: browser, terminal, authentication, security and password-manager surfaces are excluded.');
  return app;
}
export function normalizeAllowedApps(values) {
  if (!Array.isArray(values)) throw new Error('allowedApps must be an array of executable names.');
  return [...new Set(values.map(value => { const app = assertApp(value); if (String(value).trim().toLowerCase() !== app) throw new Error('Use an executable name, not a path or wildcard.'); return app; }))];
}
export function validateKeys(value) {
  const keys = String(value || '').split('+').map(s => s.trim()).filter(Boolean);
  if (!keys.length || keys.some(k => /^(?:win(?:dows)?|meta|super|cmd|command|os|lwin|rwin)$/i.test(k))) throw new Error('KEY_DENIED: Windows key combinations are excluded.');
  const aliases = { Control_L: 'Ctrl', Control_R: 'Ctrl', Control: 'Ctrl', Shift_L: 'Shift', Shift_R: 'Shift', Alt_L: 'Alt', Alt_R: 'Alt', Return: 'Enter', Escape: 'Escape', space: 'Space', BackSpace: 'Backspace', Delete: 'Delete', period:'.',comma:',',slash:'/',question:'?',greater:'>',less:'<',Left:'Left',Right:'Right',Up:'Up',Down:'Down',Page_Up:'PageUp',Page_Down:'PageDown',KP_Enter:'Enter' };
  return keys.map(k => aliases[k] || k);
}
