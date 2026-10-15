'use strict';
// The macOS session wrapper with a stand-in Electron (design 7.2), run by SessionWrapperTests:
//   node wrapper.test.cjs <generated wrapper> <session proxy> <download log>
// No network, no Discord: Electron, fs and Discord's core are stand-ins.
const fs = require('node:fs');
const vm = require('node:vm');
const [source, proxy, log] = [fs.readFileSync(process.argv[2], 'utf8'), process.argv[3], process.argv[4]];
let checks = 0;
function check(value, label) { checks++; if (!value) throw new Error(label); }
const settle = () => new Promise(resolve => setImmediate(resolve));

function run(options = {}) {
  // An explicit undefined type stays undefined, as in a process that is not Electron's.
  const type = 'type' in options ? options.type : 'browser';
  const { switchValue = '', failSetProxy = false, throwSetProxy = false, hangSetProxy = false, brokenElectron = false,
    env: given = { EXISTING: 'kept' }, immediateTimers = false } = options;
  const calls = { setProxy: [], watchers: [], records: [] };
  const core = { official: true };
  let release;
  const applied = new Promise((resolve, reject) => {
    release = hangSetProxy ? () => {} : failSetProxy ? () => reject(new Error('inert failure')) : resolve;
  });
  const shell = { openExternal: () => Promise.resolve() };
  const original = shell.openExternal;
  const electron = {
    app: {
      commandLine: { getSwitchValue(name) { check(name === 'proxy-server', 'only the proxy switch is read'); return switchValue; } },
      on(event, handler) { check(event === 'web-contents-created', 'only new web contents are watched'); calls.watchers.push(handler); },
      isReady() { return true; },
    },
    session: { defaultSession: { setProxy(config) { calls.setProxy.push(config); if (throwSetProxy) throw new Error('inert failure'); return applied; } } },
    shell,
    BrowserWindow: { getFocusedWindow() { return null; }, getAllWindows() { return []; } },
    dialog: { showErrorBox() {} },
  };
  const standInFs = {
    stat(path, callback) { callback(new Error('missing')); },
    appendFile(path, data, options, callback) { calls.records.push({ path, data }); callback(null); },
    writeFile(path, data, options, callback) { calls.records.push({ path, data }); callback(null); },
  };
  const env = Object.freeze(given);
  // The wrapper's time limit must not keep this test process alive.
  const timers = immediateTimers ? (callback) => { setImmediate(callback); return 0; }
    : (callback, delay) => { const timer = setTimeout(callback, delay); timer.unref(); return timer; };
  const context = {
    process: { type, env }, module: { exports: {} }, Buffer, URL, setTimeout: timers, clearTimeout,
    require(name) {
      if (name === 'electron') { if (brokenElectron) throw new Error('inert failure'); return electron; }
      if (name === 'fs') return standInFs;
      if (name === './core.asar') return core;
      throw new Error('unexpected module request');
    },
  };
  vm.runInNewContext(source, context, { timeout: 1000 });
  check(context.module.exports === core, "Discord's own core is exported");
  check(context.process.env === env && Object.keys(env).length === Object.keys(given).length, 'the environment is never changed');
  return { calls, release, electron, original };
}

async function loadsAfter(calls, release) {
  check(calls.watchers.length === 1, 'new web contents are watched');
  const loads = [];
  const contents = { loadURL(url) { loads.push(url); return 'loaded'; } };
  calls.watchers[0]({}, contents);
  const pending = contents.loadURL('https://discord.com/app');
  await settle();
  check(loads.length === 0, 'a page load waits for the proxy');
  release();
  check(await pending === 'loaded' && loads.length === 1 && loads[0] === 'https://discord.com/app', 'the load goes on once the proxy step ended');
}

(async () => {
  // Opened without the proxy (Dock, Launchpad, Spotlight): the session proxy is applied, with a direct fallback.
  let { calls, release, electron, original } = run();
  check(calls.setProxy.length === 1 && calls.setProxy[0].proxyRules === proxy + ',direct://' &&
    calls.setProxy[0].proxyBypassRules === '127.0.0.1;localhost', 'the session proxy, a direct fallback and loopback bypassed');
  await loadsAfter(calls, release);
  check(electron.shell.openExternal !== original, 'the attachment download hook is installed');
  await settle();
  check(calls.records.some(record => record.path === log && record.data.includes('READY')), "the hook writes to the session's log");
  // A failed proxy step still lets pages load: Discord as it was.
  ({ calls, release } = run({ failSetProxy: true }));
  await loadsAfter(calls, release);
  // A proxy step that throws leaves the hook in place; one that never ends holds page loads ten seconds at most.
  ({ calls, electron, original } = run({ throwSetProxy: true }));
  check(calls.setProxy.length === 1 && electron.shell.openExternal !== original, 'the hook is installed whatever the proxy step does');
  ({ calls } = run({ hangSetProxy: true, immediateTimers: true }));
  {
    const loads = [];
    const contents = { loadURL(url) { loads.push(url); return 'loaded'; } };
    calls.watchers[0]({}, contents);
    check(await contents.loadURL('https://discord.com/app') === 'loaded' && loads.length === 1, 'a proxy step that never ends holds loads only until the time limit');
  }
  // Discord's own environment never reaches the hook: its records go where the wrapper says.
  ({ calls, electron, original } = run({ env: { DISCORDACCESS_ATTACHMENTS: '1', DISCORDACCESS_DOWNLOAD_LOG: '/elsewhere.log' } }));
  await settle();
  check(electron.shell.openExternal !== original && calls.records.length > 0 && calls.records.every(record => record.path === log), "only the wrapper's log is used");
  // Opened from the menu with the session proxy: nothing more to apply, the hook still installed.
  ({ calls, electron, original } = run({ switchValue: proxy }));
  check(calls.setProxy.length === 0 && calls.watchers.length === 0 && electron.shell.openExternal !== original, 'the proxy argument needs nothing more');
  // Another proxy argument is replaced by the session's.
  ({ calls } = run({ switchValue: 'http://127.0.0.1:1' }));
  check(calls.setProxy.length === 1, 'another proxy argument gets the session proxy');
  // Other processes, and a broken Electron: Discord's own core only.
  for (const type of ['renderer', 'utility', undefined]) {
    ({ calls } = run({ type }));
    check(calls.setProxy.length === 0 && calls.watchers.length === 0 && calls.records.length === 0, 'only the main process is touched');
  }
  ({ calls } = run({ brokenElectron: true }));
  check(calls.setProxy.length === 0 && calls.records.length === 0, 'an Electron failure leaves Discord as it was');
  console.log(`macOS session wrapper: PASS (${checks} checks; no network or Discord)`);
})().catch(error => { console.error(error && error.message); process.exit(1); });
