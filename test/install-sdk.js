import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const entry=process.env.npm_execpath;
if(!entry)throw new Error('Run npm run setup-sdk.');
const packages=JSON.parse(readFileSync(new URL('./sdk-packages.json',import.meta.url),'utf8'));
const original=readFileSync('package.json');
const manifest=JSON.parse(original);
if(manifest.name!=='@very12345/dsh-computer-use-windows')throw new Error('Run from the plugin repository.');
// npm can omit explicit --no-save installs that are optional peers. Use a
// temporary development manifest, restoring exact bytes even on failure.
try {
  writeFileSync('package.json',JSON.stringify({...manifest,devDependencies:{...manifest.devDependencies,...packages}},null,2)+'\n');
  const result=spawnSync(process.execPath,[entry,'install','--package-lock=false','--ignore-scripts'],{stdio:'inherit'});
  if(result.error)throw result.error;
  process.exitCode=result.status??1;
} finally {writeFileSync('package.json',original);}
