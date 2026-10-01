import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export class BackendError extends Error {
  constructor(code, message, dispatched = false) { super(message); this.code = code; this.dispatched = dispatched; }
}

/** One owned STA process; cancellation destroys it and is never replayed. */
export class WindowsBackend {
  constructor({ spawnProcess = spawn, executable, script, timeoutMs = 45000, onActivity = () => {} } = {}) {
    this.spawnProcess = spawnProcess;
    this.onActivity = onActivity;
    this.executable = executable || path.join(process.env.SystemRoot || 'C:/Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
    this.script = script || fileURLToPath(new URL('../native/windows-uia.ps1', import.meta.url));
    this.timeoutMs = timeoutMs; this.sequence = 0; this.pending = new Map(); this.proc = null; this.tail = ''; this.closed = false; this.cleanup = Promise.resolve(); this.cleanupFailure = '';
  }
  start() {
    if (this.closed) throw new BackendError('STOPPED', 'Computer use backend is stopped.');
    if (this.proc) return this.proc;
    const proc = this.spawnProcess(this.executable, ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', this.script, '-Persistent'], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc = proc; let buffer = '';
    proc.stdout.setEncoding('utf8'); proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', chunk => { this.tail = (this.tail + chunk).slice(-2000); });
    proc.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 32 * 1024 * 1024) return this.destroy(new BackendError('PROTOCOL', 'Backend response exceeds limit.', true), proc);
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end).trim(); buffer = buffer.slice(end + 1); if (!line) continue;
        let reply; try { reply = JSON.parse(line); } catch { continue; }
        if (reply.type === 'activity') { try { this.onActivity(reply); } catch {} continue; }
        const waiter = this.pending.get(reply.id); if (!waiter || waiter.proc !== proc) continue;
        waiter.cleanup();
        if (reply.ok === false) waiter.reject(new BackendError('BACKEND_REJECTED', reply.error || 'Windows action failed.', true));
        else waiter.resolve(reply);
      }
    });
    proc.on('error', error => this.destroy(new BackendError('BACKEND_EXIT', error.message, true), proc));
    proc.on('exit', () => this.destroy(new BackendError('BACKEND_EXIT', 'Windows backend exited unexpectedly. ' + this.tail, true), proc));
    proc.stdin.on('error', error => this.destroy(new BackendError('BACKEND_EXIT', error.message, true), proc));
    return proc;
  }
  async request(action, args = {}, signal) {
    signal?.throwIfAborted(); await this.cleanup; signal?.throwIfAborted();
    if (this.cleanupFailure) throw new BackendError('INPUT_STATE_UNKNOWN', this.cleanupFailure + ' Reload the plugin after checking the desktop.');
    const proc = this.start(); const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', abort); this.pending.delete(id); };
      const abort = () => this.destroy(new BackendError('CANCELLED', 'Stopped during Windows call; effects may already exist. Reobserve before retrying.', true), proc);
      const timer = setTimeout(() => this.destroy(new BackendError('TIMEOUT', 'Windows call timed out; effects may already exist. Reobserve before retrying.', true), proc), this.timeoutMs);
      this.pending.set(id, { resolve, reject, cleanup, proc, action });
      signal?.addEventListener('abort', abort, { once: true });
      if (signal?.aborted) return abort();
      proc.stdin.write(JSON.stringify({ id, action, args }) + '\n', error => { if (error) this.destroy(new BackendError('BACKEND_EXIT', error.message, true), proc); });
    });
  }
  destroy(error = new BackendError('STOPPED', 'Computer use stopped; reobserve before any further input.', true), proc = this.proc) {
    if (!proc) return;
    if (this.proc === proc) this.proc = null;
    const inputPending = [...this.pending.values()].some(w => w.proc === proc && !['snapshot','list_apps','list_windows'].includes(w.action));
    for (const waiter of [...this.pending.values()]) if (waiter.proc === proc) { waiter.cleanup(); waiter.reject(error); }
    // The worker has no child process for input. This kills its input loop.
    proc.kill();
    if (inputPending && process.platform === 'win32') {
      this.cleanup = new Promise(resolve => {
        const release = this.spawnProcess(this.executable, ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',fileURLToPath(new URL('../native/release-input.ps1',import.meta.url))], { windowsHide:true,stdio:'ignore' });
        const timer = setTimeout(() => { this.cleanupFailure='Interrupted input cleanup timed out.';release.kill();resolve(); },5000);
        release.once('exit',code=>{clearTimeout(timer);if(code!==0)this.cleanupFailure='Interrupted input cleanup failed.';resolve();});
        release.once('error',()=>{clearTimeout(timer);this.cleanupFailure='Interrupted input cleanup could not start.';resolve();});
      });
    }
  }
  stop() { this.destroy(); return this.cleanup; }
  close() { this.closed = true; this.destroy(); }
}
