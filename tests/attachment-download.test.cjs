'use strict';
const assert = require('assert');
const { EventEmitter } = require('events');
const fs = require('fs');
const vm = require('vm');
const https = require('https');
const hookPath = require.resolve('../bridge/attachment-download.cjs');
const httpsAgent = https.globalAgent;
const httpsConnect = httpsAgent.createConnection;
const httpsRequest = https.request;
const { install, validateAttachmentUrl } = require(hookPath);
const link = 'https://cdn.discordapp.com/attachments/123/456/file%20name.txt?ex=synthetic&hm=private%2Bsignature';
let checks = 0;
const fixtures = [];
function check(value, name) { assert.ok(value, name); checks++; }
function fixture(options = {}) {
  const session = new EventEmitter();
  const calls = [], logs = [], errors = [], downloads = [], timers = [], io = [], writes = [], forbidden = [];
  const contents = new EventEmitter();
  Object.assign(contents, { isDestroyed: () => false, getURL: () => 'https://discord.com/channels/@me', session,
    downloadURL: url => { if (options.throwDownload) throw new Error(link); downloads.push(url); } });
  const window = { isDestroyed: () => false, webContents: contents };
  const official = function(...args) { calls.push({ receiver: this, args }); return Promise.resolve('official'); };
  const app = new EventEmitter(); app.isReady = () => true;
  const electron = { shell: { openExternal: official }, app,
    BrowserWindow: { getFocusedWindow: () => options.noWindow ? null : window, getAllWindows: () => options.noWindow ? [] : [window] },
    dialog: { showErrorBox: (...args) => errors.push(args) } };
  function forbiddenCall(name) { forbidden.push(name); throw new Error('Forbidden broad hook: ' + name); }
  for (const name of ['registerPreloadScript', 'getPreloads', 'setPreloads', 'setProxy', 'resolveProxy', 'setPermissionRequestHandler']) {
    session[name] = () => forbiddenCall(name);
  }
  Object.defineProperty(session, 'webRequest', { get: () => forbiddenCall('webRequest') });
  Object.defineProperty(electron, 'session', { get: () => forbiddenCall('electron.session') });
  let fileBytes = options.logBytes || 0;
  const asyncFs = {
    stat: (_path, callback) => io.push(() => callback(options.statFailure ? new Error(link) : null, { size: fileBytes })),
    appendFile: (_path, text, _encoding, callback) => {
      writes.push({ kind: 'append', bytes: Buffer.byteLength(text), text });
      io.push(() => { if (!options.writeFailure) { logs.push(text); fileBytes += Buffer.byteLength(text); } callback(options.writeFailure ? new Error(link) : null); });
    },
    writeFile: (_path, text, _encoding, callback) => {
      writes.push({ kind: 'replace', bytes: Buffer.byteLength(text), text });
      io.push(() => { if (!options.writeFailure) { logs.push(text); fileBytes = Buffer.byteLength(text); } callback(options.writeFailure ? new Error(link) : null); });
    }
  };
  for (const name of ['statSync', 'appendFileSync', 'writeFileSync']) asyncFs[name] = () => forbiddenCall(name);
  const config = { env: { DISCORDACCESS_ATTACHMENTS: '1', DISCORDACCESS_DOWNLOAD_LOG: 'fixture.log' }, processType: 'browser', fs: asyncFs,
    setTimeout: (callback, duration) => { const timer = { callback, duration, cleared: false, unref() {} }; timers.push(timer); return timer; },
    clearTimeout: timer => { timer.cleared = true; } };
  function flush() { let count = 0; while (io.length) { if (++count > 1000) throw new Error('Unbounded asynchronous logging'); io.shift()(); } }
  function item(chain = [link], owner = contents, itemOptions = {}) {
    const item = new EventEmitter();
    item.getURLChain = () => { if (itemOptions.chainFailure) throw new Error(link); return chain; };
    item.setSaveDialogOptions = value => { if (itemOptions.dialogFailure) throw new Error(link); item.dialogOptions = value; };
    item.getReceivedBytes = () => itemOptions.received === undefined ? 2048 : itemOptions.received;
    item.getTotalBytes = () => itemOptions.total === undefined ? 2048 : itemOptions.total;
    item.cancel = () => { item.cancelled = true; };
    const event = { preventDefault: () => { if (itemOptions.preventFailure) throw new Error(link); item.prevented = true; } };
    session.emit('will-download', event, item, owner);
    return item;
  }
  const f = { electron, config, calls, logs, errors, downloads, timers, contents, window, session, item, official, flush, io, writes, forbidden, asyncFs };
  fixtures.push(f); return f;
}

(async () => {
  for (const valid of [link, 'https://cdn.discordapp.com/ephemeral-attachments/1/2/f?hm=fixture',
    'https://media.discordapp.net/ephemeral-attachments/1/2/f', 'https://media.discordapp.net/attachments/1/2/f',
    'HTTPS://CDN.DISCORDAPP.COM:443/attachments/1/2/f', 'https://cdn.discordapp.com/attachments/1/2/caf%C3%A9.txt']) check(validateAttachmentUrl(valid), 'valid attachment URL');
  const invalid = [null, 123, {}, '', 'http://cdn.discordapp.com/attachments/1/2/f', 'https://cdn.discordapp.com:8443/attachments/1/2/f',
    'https://cdn.discordapp.com.evil.example/attachments/1/2/f', 'https://x.cdn.discordapp.com/attachments/1/2/f',
    'https://cdn.discordapp.com./attachments/1/2/f', 'https://user@cdn.discordapp.com/attachments/1/2/f', link + '#x', link + '\r\n',
    'https://cdn.discordapp.com/attachments/1/2/%2e%2e', 'https://cdn.discordapp.com/attachments/1/2/../f',
    'https://cdn.discordapp.com/attachments/1/2/%2fsecret', 'https://cdn.discordapp.com/attachments/1/2/%252fsecret',
    'https://cdn.discordapp.com/attachments/1/2/%5csecret', 'https://cdn.discordapp.com/attachments/1/2/%255csecret',
    'https://cdn.discordapp.com/attachments/1/2/%00', 'https://cdn.discordapp.com/attachments/1/2/%',
    'https://cdn.discordapp.com/attachments/1/2/%FE', 'https://cdn.discordapp.com/attachments/1/2/f/other',
    'https://cdn.discordapp.com/attachments/a/2/f', 'https://cdn.discordapp.com/attachments/1/2/f\\x',
    'https://cdn.discordapp.com/attachments/1/2/f x', 'https://cdn.discordapp.com?x=/attachments/1/2/f',
    'https://cdn.discordapp.com/attachments/1/12345678901234567890123/f', link + 'a'.repeat(8193)];
  for (const value of invalid) check(!validateAttachmentUrl(value), 'invalid attachment URL');
  const disabled = fixture(); disabled.config.env.DISCORDACCESS_ATTACHMENTS = '0';
  check(!install(disabled.electron, disabled.config) && disabled.electron.shell.openExternal === disabled.official && disabled.io.length === 0, 'disabled does nothing');
  const legacy = fixture(); delete legacy.config.env.DISCORDACCESS_ATTACHMENTS; legacy.config.env.DISCORDACCESS_DOWNLOADS = '1';
  check(!install(legacy.electron, legacy.config) && legacy.electron.shell.openExternal === legacy.official, 'legacy activation is insufficient');
  const renderer = fixture(); renderer.config.processType = 'renderer';
  check(!install(renderer.electron, renderer.config) && renderer.electron.shell.openExternal === renderer.official, 'renderer does nothing');
  const f = fixture(); check(install(f.electron, f.config), 'install');
  const wrapped = f.electron.shell.openExternal;
  check(install(f.electron, f.config) && f.electron.shell.openExternal === wrapped && f.io.length === 1, 'idempotent installation');
  const opts = { activate: false };
  check(await f.electron.shell.openExternal('https://example.com', opts) === 'official' && f.calls[0].args[1] === opts && f.calls[0].receiver === f.electron.shell, 'nonattachment preserves method, options, receiver and result');
  for (const value of invalid) await f.electron.shell.openExternal(value, opts);
  check(f.calls.length === invalid.length + 1 && f.downloads.length === 0, 'all rejected URLs delegate unchanged');
  await f.electron.shell.openExternal(link);
  check(f.downloads.length === 1 && f.downloads[0] === link && !f.calls.some(c => c.args[0] === link), 'signed query reaches downloadURL unchanged and never opens browser');
  check(f.timers[0].duration === 30000, 'pending timeout is thirty seconds');
  await f.electron.shell.openExternal(link); check(f.downloads.length === 1, 'same click deduplicated');
  const unrelated = f.item(['https://example.com/file']); check(!unrelated.dialogOptions && !unrelated.prevented, 'unrelated download unchanged');
  const otherOwner = f.item([link], {}); check(!otherOwner.dialogOptions && !otherOwner.prevented, 'other contents download unchanged');
  const active = f.item();
  check(active.dialogOptions.title === 'Save Discord file' && Object.keys(active.dialogOptions).length === 1 && f.timers[0].cleared, 'native Save dialog has only a fixed safe title and no forced path');
  f.timers[0].callback(); check(f.errors.length === 0, 'stale cleared timer cannot expire an active item');
  active.emit('done', {}, 'completed'); f.flush();
  check(f.session.listenerCount('will-download') === 0 && f.contents.listenerCount('destroyed') === 0, 'completed item removes both observers');
  check(f.logs.some(line => /COMPLETED.*elapsed_ms=\d+ received_bytes=2048 total_bytes=2048/.test(line)), 'completion has only bounded numeric metrics');
  await f.electron.shell.openExternal(link); const cancelled = f.item(); cancelled.emit('done', {}, 'cancelled');
  await f.electron.shell.openExternal(link); check(f.downloads.length === 3, 'cancellation permits another click');
  const badRedirect = f.item([link, 'https://example.com/private']);
  check(badRedirect.prevented && f.session.listenerCount('will-download') === 0, 'foreign redirect rejected before Save dialog');
  for (const chain of [[link, 'http://cdn.discordapp.com/attachments/1/2/f'], [link, 'https://cdn.discordapp.com/not-attachments/f'], Array(5).fill(link)]) {
    const redir = fixture(); install(redir.electron, redir.config); await redir.electron.shell.openExternal(link);
    const item = redir.item(chain); check(item.prevented && !item.dialogOptions && redir.errors.length === 1, 'bad redirect chain rejected');
  }
  const goodRedirect = fixture(); install(goodRedirect.electron, goodRedirect.config); await goodRedirect.electron.shell.openExternal(link);
  check(!!goodRedirect.item([link, 'https://media.discordapp.net/attachments/123/456/file?hm=other-synthetic']).dialogOptions, 'allowed CDN redirect retains native save flow');
  const timeout = fixture(); install(timeout.electron, timeout.config); await timeout.electron.shell.openExternal(link); timeout.timers[0].callback();
  check(timeout.session.listenerCount('will-download') === 1 && timeout.errors.length === 1, 'timeout retains bounded tombstone to cancel late event');
  check(timeout.errors[0][1].includes('quit DiscordAccess') && timeout.errors[0][1].includes('open the connection and Discord again') && !timeout.errors[0][1].includes('CMD'), 'timeout explains resident tray restart without assuming an open console');
  await timeout.electron.shell.openExternal(link); check(timeout.downloads.length === 1 && timeout.calls.length === 0, 'timeout retry neither relaunches ambiguous request nor opens browser');
  const lateOther = timeout.item([link], {}); check(!lateOther.prevented, 'timeout does not cancel other owner');
  const late = timeout.item(); check(late.prevented && !late.dialogOptions && timeout.session.listenerCount('will-download') === 0, 'late download cancelled and tombstone removed');
  await timeout.electron.shell.openExternal(link); check(timeout.downloads.length === 2, 'late-event cancellation safely permits a fresh retry');
  const closed = fixture(); install(closed.electron, closed.config); await closed.electron.shell.openExternal(link); closed.timers[0].callback(); closed.contents.emit('destroyed');
  check(closed.session.listenerCount('will-download') === 0 && closed.contents.listenerCount('destroyed') === 0, 'window destruction releases timed-out records and observers');
  const activeClosed = fixture(); install(activeClosed.electron, activeClosed.config); await activeClosed.electron.shell.openExternal(link);
  const activeClosedItem = activeClosed.item(); activeClosed.contents.emit('destroyed');
  check(activeClosedItem.cancelled && activeClosed.session.listenerCount('will-download') === 0, 'closing owner cancels owned active item');
  const concurrent = fixture(); install(concurrent.electron, concurrent.config);
  await concurrent.electron.shell.openExternal(link); await concurrent.electron.shell.openExternal(link + '&second=1');
  concurrent.item().emit('done', {}, 'completed');
  check(concurrent.session.listenerCount('will-download') === 1, 'one completed item preserves another pending download observer');
  await concurrent.electron.shell.openExternal(link); concurrent.timers[0].callback();
  check(!!concurrent.item().dialogOptions && concurrent.errors.length === 0, 'old cleared timer cannot expire a newer same-URL request');
  const missing = fixture({ noWindow: true }); install(missing.electron, missing.config); await missing.electron.shell.openExternal(link);
  check(missing.errors.length === 1 && missing.downloads.length === 0 && missing.calls.length === 0, 'missing window has safe error without browser fallback');
  check(missing.errors[0][1].includes('No suitable Discord window was found') && missing.errors[0][1].includes('Open the main window') && !missing.errors[0][1].includes('separate Discord'),
    'missing window explains how to reopen the installed Discord window');
  const notReady = fixture(); notReady.electron.app.isReady = () => false; install(notReady.electron, notReady.config); await notReady.electron.shell.openExternal(link);
  check(notReady.errors.length === 1 && notReady.downloads.length === 0 && notReady.electron.app.eventNames().length === 0, 'not-ready app never adds ready or session-created hooks');
  const invalidWindow = fixture(); invalidWindow.contents.getURL = () => 'https://discord.com.evil.example/channels/@me';
  install(invalidWindow.electron, invalidWindow.config); await invalidWindow.electron.shell.openExternal(link);
  check(invalidWindow.downloads.length === 0 && invalidWindow.errors.length === 1, 'foreign focused window rejected');
  const fallback = fixture(); fallback.electron.BrowserWindow.getFocusedWindow = () => ({ isDestroyed: () => true });
  install(fallback.electron, fallback.config); await fallback.electron.shell.openExternal(link); check(fallback.downloads.length === 1, 'valid unfocused Discord window can download');
  for (const windowUrl of [
    'https://discord.com/app?_=synthetic', 'https://discord.com:443/channels/@me',
    'https://discordapp.com/app?_=synthetic', 'https://discordapp.com/channels/@me',
    'https://discordapp.com/channels/123/456', 'https://discordapp.com/login?redirect_to=synthetic',
    'HTTPS://DISCORDAPP.COM:443/app', 'https://discordapp.com/channels/@me#synthetic'
  ]) {
    const legacyWindow = fixture(); legacyWindow.contents.getURL = () => windowUrl;
    install(legacyWindow.electron, legacyWindow.config); await legacyWindow.electron.shell.openExternal(link);
    check(legacyWindow.downloads.length === 1 && legacyWindow.downloads[0] === link &&
      legacyWindow.calls.length === 0 && legacyWindow.errors.length === 0,
      'both exact official window hosts preserve the signed attachment and avoid external browser fallback');
    const saved = legacyWindow.item();
    check(saved.dialogOptions.title === 'Save Discord file' && !saved.prevented,
      'legacy official window reaches its same-session native Save dialog');
    saved.emit('done', {}, 'completed');
    check(legacyWindow.session.listenerCount('will-download') === 0 && legacyWindow.contents.listenerCount('destroyed') === 0,
      'legacy window download completion releases its own observers');
  }
  const legacyFallback = fixture(); legacyFallback.contents.getURL = () => 'https://discordapp.com/channels/@me';
  legacyFallback.electron.BrowserWindow.getFocusedWindow = () => ({ isDestroyed: () => false,
    webContents: { isDestroyed: () => false, getURL: () => 'https://example.com/app', downloadURL: () => { throw new Error('Foreign window used'); } } });
  install(legacyFallback.electron, legacyFallback.config); await legacyFallback.electron.shell.openExternal(link);
  check(legacyFallback.downloads.length === 1 && legacyFallback.downloads[0] === link && legacyFallback.errors.length === 0,
    'foreign focused window falls back only to the owned legacy Discord main window');
  for (const host of ['discord.com', 'discordapp.com']) {
    for (const windowUrl of [
      'https://' + host + '.evil.example/app', 'https://sub.' + host + '/channels/@me',
      'https://' + host + './app', 'http://' + host + '/app', 'https://' + host + ':8443/app',
      'https://user@' + host + '/app', 'https://user:secret@' + host + '/app',
      'https://' + host + '/attachments/123/456/file', 'https://' + host + '/app-extra',
      'https://' + host + '/not-app', 'https://' + host + '/%61pp',
      'https://' + host + '/channels/../../outside', 'https://' + host + '?path=/app',
      'https://' + host + '/app\r\n', 'https://' + host + '\\app',
      'https://%64' + host.slice(1) + '/app', 'https://' + host + '/app?' + 'x'.repeat(8192)
    ]) {
      const rejectedWindow = fixture(); rejectedWindow.contents.getURL = () => windowUrl;
      install(rejectedWindow.electron, rejectedWindow.config); await rejectedWindow.electron.shell.openExternal(link);
      check(rejectedWindow.downloads.length === 0 && rejectedWindow.calls.length === 0 && rejectedWindow.errors.length === 1 &&
        rejectedWindow.session.listenerCount('will-download') === 0,
        'both window hosts reject lookalikes, alternate ports, credentials, foreign routes and malformed URLs');
    }
  }
  const failure = fixture({ throwDownload: true }); install(failure.electron, failure.config); await failure.electron.shell.openExternal(link);
  check(failure.errors.length === 1 && failure.session.listenerCount('will-download') === 0, 'downloadURL exception resolves safely and cleans observer');
  const dialogFailure = fixture(); install(dialogFailure.electron, dialogFailure.config); await dialogFailure.electron.shell.openExternal(link);
  check(dialogFailure.item([link], dialogFailure.contents, { dialogFailure: true }).cancelled && dialogFailure.errors.length === 1, 'Save dialog setup failure cancels item safely');
  const preventFailure = fixture(); install(preventFailure.electron, preventFailure.config); await preventFailure.electron.shell.openExternal(link);
  check(preventFailure.item([link, 'https://example.com'], preventFailure.contents, { preventFailure: true }).cancelled, 'cancel fallback if preventDefault throws');
  const frozen = fixture(); Object.freeze(frozen.electron.shell);
  check(!install(frozen.electron, frozen.config) && frozen.errors.length === 1, 'uninstallable hook visibly reported');
  const normalized = fixture(); install(normalized.electron, normalized.config);
  const upper = 'HTTPS://CDN.DISCORDAPP.COM:443/attachments/1/2/f?hm=preserve%2Bthis';
  await normalized.electron.shell.openExternal(upper);
  check(normalized.downloads[0] === upper && !!normalized.item([new URL(upper).href]).dialogOptions, 'canonical event matching never rewrites signed request');
  const interrupted = fixture(); install(interrupted.electron, interrupted.config); await interrupted.electron.shell.openExternal(link);
  interrupted.item([link], interrupted.contents, { received: link, total: -1 }).emit('done', {}, 'interrupted'); interrupted.flush();
  check(interrupted.errors.length === 1 && interrupted.logs.some(line => /INTERRUPTED.*elapsed_ms=\d+/.test(line)) && !interrupted.logs.join('').includes('received_bytes='), 'invalid metrics omitted and interruption surfaced safely');
  const busy = fixture(); install(busy.electron, busy.config);
  for (let i = 0; i < 9; i++) await busy.electron.shell.openExternal(link + '&n=' + i);
  check(busy.downloads.length === 8 && busy.errors.length === 1 && busy.session.listenerCount('will-download') === 1 && busy.contents.listenerCount('destroyed') === 1, 'eight pending requests share one observer per session and owner');
  check(busy.errors[0][1].includes('quit DiscordAccess') && busy.errors[0][1].includes('open the connection and Discord again') && !busy.errors[0][1].includes('CMD'), 'busy handler explains resident tray restart without assuming an open console');
  for (const timer of busy.timers) timer.callback(); await busy.electron.shell.openExternal(link + '&n=10');
  check(busy.downloads.length === 8 && busy.timers.length === 8, 'timeout tombstones remain bounded at eight');
  busy.contents.emit('destroyed'); check(busy.session.listenerCount('will-download') === 0, 'all bounded tombstones released when owner closes');
  const pressure = fixture(); install(pressure.electron, pressure.config); await pressure.electron.shell.openExternal(link);
  for (let i = 0; i < 500; i++) await pressure.electron.shell.openExternal(link);
  check(pressure.io.length === 1 && pressure.writes.length === 0, 'slow log storage never queues parallel I/O or blocks click handling');
  pressure.flush(); check(pressure.logs.join('').trim().split('\n').length <= 32 && pressure.writes.length === 1, 'log backlog is bounded and batched');
  const rotation = fixture({ logBytes: 262144 }); install(rotation.electron, rotation.config); rotation.flush();
  check(rotation.writes[0].kind === 'replace' && rotation.writes[0].bytes < 262144, 'bounded async log rotates before its cap');
  const logFailure = fixture({ statFailure: true, writeFailure: true }); install(logFailure.electron, logFailure.config);
  await logFailure.electron.shell.openExternal(link); logFailure.flush(); check(logFailure.downloads.length === 1 && logFailure.errors.length === 0, 'log I/O failure cannot break download or leak exception');
  const noLog = fixture(); delete noLog.config.env.DISCORDACCESS_DOWNLOAD_LOG; install(noLog.electron, noLog.config);
  await noLog.electron.shell.openExternal(link); check(noLog.io.length === 0 && noLog.downloads.length === 1, 'missing log path leaves downloads functional');
  const auto = fixture(); const required = [], consoleCalls = [];
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(hookPath, 'utf8'), { module, exports: module.exports, URL, Buffer, Symbol, Map, Date,
    process: { env: auto.config.env, type: 'browser' }, setTimeout: auto.config.setTimeout, clearTimeout: auto.config.clearTimeout,
    console: { log: (...a) => consoleCalls.push(a), error: (...a) => consoleCalls.push(a), warn: (...a) => consoleCalls.push(a) },
    require: name => { required.push(name); if (name === 'electron') return auto.electron; if (name === 'fs') return auto.asyncFs; throw new Error('Forbidden import: ' + name); } });
  await auto.electron.shell.openExternal(link); auto.item().emit('done', {}, 'completed'); auto.flush();
  check(required.every(name => name === 'electron' || name === 'fs') && required.includes('electron'), 'automatic entry loads only Electron and filesystem, never Node transport or preload modules');
  check(consoleCalls.length === 0, 'automatic entry and download completion produce no console output');
  const autoFailure = fixture(); const failedModule = { exports: {} };
  vm.runInNewContext(fs.readFileSync(hookPath, 'utf8'), { module: failedModule, exports: failedModule.exports, URL, Buffer, Symbol, Map, Date,
    process: { env: autoFailure.config.env, type: 'browser' },
    console: { log: (...a) => consoleCalls.push(a), error: (...a) => consoleCalls.push(a), warn: (...a) => consoleCalls.push(a) },
    require: name => { if (name === 'fs') return autoFailure.asyncFs; throw new Error(link); } });
  autoFailure.flush();
  check(consoleCalls.length === 0 && autoFailure.logs.some(line => line.includes('UNAVAILABLE')), 'bootstrap import failure is recorded asynchronously without console output or raw exception');
  check(https.globalAgent === httpsAgent && httpsAgent.createConnection === httpsConnect && https.request === httpsRequest, 'Node HTTPS APIs remain unchanged');
  for (const state of fixtures) {
    state.flush();
    check(state.forbidden.length === 0 && state.electron.app.eventNames().length === 0, 'no preload, proxy, webRequest, app session events or synchronous log filesystem calls');
    const text = JSON.stringify([state.logs, state.errors]);
    check(!text.includes('private%2Bsignature') && !text.includes('https://') && !text.includes('file%20name'), 'diagnostics contain no signed URL, filename or raw exception');
  }
  check(auto.logs.every(line => line.includes('[DiscordAccessDownload v4.12]')), 'versioned diagnostic prefix');
  console.log('Attachment-only hook checks: PASS (' + checks + ' checks; mocked Electron, no Discord or network launched)');
})().catch(error => { console.error(error); process.exitCode = 1; });
