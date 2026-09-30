import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const entry=process.env.npm_execpath;
if(!entry)throw new Error('Run npm run setup-sdk.');
const packages=JSON.parse(readFileSync(new URL('./sdk-packages.json',import.meta.url),'utf8'));
const args=Object.entries(packages).map(([name,version])=>name+'@'+version);
const result=spawnSync(process.execPath,[entry,'install','--no-save','--package-lock=false','--ignore-scripts',...args],{stdio:'inherit'});
if(result.error)throw result.error;
process.exitCode=result.status??1;
