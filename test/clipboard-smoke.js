import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

if (process.platform !== 'win32') throw new Error('Windows clipboard required');
const output = execFileSync(path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
  ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./clipboard-smoke.ps1',import.meta.url))],
  {windowsHide:true,encoding:'utf8',timeout:15000});
const cases = JSON.parse(output.trim());
assert.equal(cases.length, 5);
assert.equal(cases[0].wrong_prior_clipboard, true);
assert.equal(cases[1].write_verified, true);
assert.equal(cases[1].retained, true);
assert.equal(cases[2].restored, true);
assert.equal(cases[3].target_text_observed, true);
assert.equal(cases[3].paste_calls, 1);
assert.equal(cases[4].rejected_before_input, true);
assert.equal(cases[4].paste_calls, 0);
console.log(JSON.stringify({ok:true,clipboardCases:cases}));
