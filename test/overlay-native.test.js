import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {readFileSync} from 'node:fs';
test('banner separator is encoded as a C# escape for Windows PowerShell 5.1',()=>{
 const source=readFileSync(new URL('../native/desktop-overlay.ps1',import.meta.url),'utf8');
 const caption=source.match(/const string text="([^"]+)"/)[1];assert.match(caption,/\\u00b7/);assert.ok([...caption].every(c=>c.charCodeAt(0)<128));
});
test('native hook filter accepts only physical Escape key-down',t=>{
 if(process.platform!=='win32'){t.skip('Windows native filter');return;}
 const output=execFileSync(path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('./overlay-native-test.ps1',import.meta.url))],{windowsHide:true,encoding:'utf8',timeout:15000});
 assert.deepEqual(JSON.parse(output),[true,true,false,false,false,false]);
});
