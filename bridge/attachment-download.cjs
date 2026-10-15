'use strict';

// Required by the installed Discord wrapper, before its official core.
// This changes attachment openExternal calls only; all transport remains in the
// existing Chromium session. No Node networking, preload or proxy is changed.
const installed = Symbol.for('DiscordAccess.attachmentDownload.v2');
const maximumPending = 8;
const pendingMilliseconds = 30000;
const maximumLogBytes = 262144;
const maximumLogQueue = 32;
const messages = Object.freeze({
  READY: 'Attachment download handler ready.',
  UNAVAILABLE: 'Attachment download handler could not be installed.',
  STARTED: 'Attachment download requested inside Discord.',
  DUPLICATE: 'Duplicate attachment download request ignored.',
  BUSY: 'Too many attachment downloads are pending.',
  NO_WINDOW: 'No available Discord window for attachment download.',
  FAILED: 'Attachment download could not be started.',
  TIMEOUT: 'Attachment download did not start in time.',
  LATE_CANCELLED: 'Late attachment download was cancelled after timeout.',
  WINDOW_CLOSED: 'Pending attachment downloads ended with the Discord window.',
  REDIRECT_REJECTED: 'Attachment download redirect was rejected.',
  SAVING: 'Attachment download save dialog requested.',
  COMPLETED: 'Attachment download completed.',
  CANCELLED: 'Attachment download cancelled.',
  INTERRUPTED: 'Attachment download interrupted.'
});

function validateAttachmentUrl(value) {
  if (typeof value !== 'string' || !value || value.length > 8192 || /[\x00-\x20\x7f\\]/.test(value)) return false;
  // Check the original path before URL parsing can normalize dot segments.
  const match = /^https:\/\/(?:cdn\.discordapp\.com|media\.discordapp\.net)(?::443)?(\/(?:attachments|ephemeral-attachments)\/[0-9]{1,22}\/[0-9]{1,22}\/[^/?#]+)(?:\?[^#]*)?$/i.exec(value);
  if (!match || /%(?![0-9a-f]{2})/i.test(match[1])) return false;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash || (url.port && url.port !== '443') ||
        !['cdn.discordapp.com', 'media.discordapp.net'].includes(url.hostname)) return false;
    const name = decodeURIComponent(match[1].slice(match[1].lastIndexOf('/') + 1));
    return name !== '.' && name !== '..' && !/[\x00-\x1f\x7f/\\]/.test(name) && !/%(?:2f|5c|00|0a|0d)/i.test(name);
  } catch (_) { return false; }
}

function createLogger(fs, path) {
  const queue = [];
  let running = false, initialized = false, bytes = 0;
  function drain() {
    if (running || !queue.length || !path) return;
    running = true;
    if (!initialized) {
      initialized = true;
      try {
        fs.stat(path, (error, stat) => {
          bytes = !error && stat && Number.isFinite(stat.size) ? stat.size : 0;
          running = false; drain();
        });
      } catch (_) { running = false; drain(); }
      return;
    }
    const batch = queue.splice(0, maximumLogQueue).join('');
    const length = Buffer.byteLength(batch, 'utf8');
    const replace = bytes + length > maximumLogBytes;
    try {
      fs[replace ? 'writeFile' : 'appendFile'](path, batch, { encoding: 'utf8' }, error => {
        if (!error) bytes = (replace ? 0 : bytes) + length;
        running = false; drain();
      });
    } catch (_) { running = false; drain(); }
  }
  return (code, metrics) => {
    if (!path || !Object.prototype.hasOwnProperty.call(messages, code)) return;
    let suffix = '';
    if ((code === 'COMPLETED' || code === 'INTERRUPTED') && metrics) {
      for (const key of ['elapsed_ms', 'received_bytes', 'total_bytes']) {
        if (Number.isSafeInteger(metrics[key]) && metrics[key] >= 0) suffix += ' ' + key + '=' + metrics[key];
      }
    }
    if (queue.length === maximumLogQueue) queue.shift();
    queue.push(new Date().toISOString() + ' [DiscordAccessDownload v4.12] ' + code + ' ' + messages[code] + suffix + '\n');
    drain();
  };
}

function install(electron, options) {
  options = options || {};
  const env = options.env || process.env;
  const processType = options.processType === undefined ? process.type : options.processType;
  if (env.DISCORDACCESS_ATTACHMENTS !== '1' || processType === 'renderer') return false;
  const log = createLogger(options.fs || require('fs'), env.DISCORDACCESS_DOWNLOAD_LOG);
  const schedule = options.setTimeout || setTimeout;
  const unschedule = options.clearTimeout || clearTimeout;
  function report(code, metrics) {
    log(code, metrics);
    try {
      const recovery = code === 'NO_WINDOW'
        ? 'No suitable Discord window was found for the download. Open the main window of the installed Discord and click the file again.'
        : code === 'TIMEOUT' || code === 'BUSY'
        ? 'The pending download could not finish. Quit Discord completely, quit DiscordAccess, then open the connection and Discord again.'
        : 'The file could not be downloaded inside Discord. Details are in the DiscordAccess download log. For a command-line download, follow the --console and D steps in the DiscordAccess usage notes.';
      electron.dialog.showErrorBox('Discord file download',
        recovery);
    } catch (_) { }
  }
  if (!electron || !electron.shell || typeof electron.shell.openExternal !== 'function') { report('UNAVAILABLE'); return false; }
  const shell = electron.shell;
  if (shell[installed]) return true;
  const original = shell.openExternal;
  const pending = new Map();
  const sessions = new Map();
  const owners = new Map();
  function validWindow(window) {
    try {
      if (!window || window.isDestroyed() || !window.webContents || window.webContents.isDestroyed()) return false;
      const value = window.webContents.getURL();
      if (typeof value !== 'string' || value.length > 8192 || /[\x00-\x20\x7f\\]/.test(value) ||
          !/^https:\/\/(?:discord\.com|discordapp\.com)(?::443)?\/(?:app|channels|login)(?:[/?#]|$)/i.test(value)) return false;
      const url = new URL(value);
      // Official stable Discord still uses discordapp.com in unmigrated profiles.
      return url.protocol === 'https:' && ['discord.com', 'discordapp.com'].includes(url.hostname) && !url.port && !url.username && !url.password &&
        /^\/(?:app|channels|login)(?:\/|$)/.test(url.pathname) && typeof window.webContents.downloadURL === 'function';
    } catch (_) { return false; }
  }
  function findWindow() {
    try {
      if (electron.app && !electron.app.isReady()) return null;
      const focused = electron.BrowserWindow.getFocusedWindow();
      if (validWindow(focused)) return focused;
      return electron.BrowserWindow.getAllWindows().find(validWindow) || null;
    } catch (_) { return null; }
  }
  function clearTimer(record) {
    if (record.timer !== null) { try { unschedule(record.timer); } catch (_) { } }
    record.timer = null;
  }
  function cleanup(record) {
    clearTimer(record);
    if (pending.get(record.key) === record) pending.delete(record.key);
    if (![...pending.values()].some(other => other.session === record.session)) {
      const handler = sessions.get(record.session);
      if (handler) { try { record.session.removeListener('will-download', handler); } catch (_) { } }
      sessions.delete(record.session);
    }
    if (![...pending.values()].some(other => other.contents === record.contents)) {
      const handler = owners.get(record.contents);
      if (handler) { try { record.contents.removeListener('destroyed', handler); } catch (_) { } }
      owners.delete(record.contents);
    }
  }
  function prevent(event, item) {
    try { event.preventDefault(); }
    catch (_) { try { item.cancel(); } catch (_) { } }
  }
  function observe(session, contents) {
    if (!owners.has(contents)) {
      const destroyed = () => {
        for (const record of [...pending.values()]) {
          if (record.contents !== contents) continue;
          if (record.item) { try { record.item.cancel(); } catch (_) { } }
          cleanup(record);
        }
        log('WINDOW_CLOSED');
      };
      contents.once('destroyed', destroyed);
      owners.set(contents, destroyed);
    }
    if (sessions.has(session)) return;
    const handler = (event, item, contents) => {
      let chain, key;
      try {
        chain = item.getURLChain();
        if (!Array.isArray(chain) || !chain.length) return;
        key = new URL(chain[0]).href;
      } catch (_) { return; }
      const record = pending.get(key);
      if (!record || record.session !== session || contents !== record.contents || record.item) return;
      if (record.expired) {
        prevent(event, item); cleanup(record); log('LATE_CANCELLED'); return;
      }
      if (chain.length > 4 || !chain.every(validateAttachmentUrl)) {
        prevent(event, item); cleanup(record); report('REDIRECT_REJECTED'); return;
      }
      record.item = item;
      clearTimer(record);
      try {
        // Electron owns the ordinary Save dialog, path and download manager.
        // Never setSavePath, auto-open a file, or change session/global proxies.
        item.setSaveDialogOptions({ title: 'Save Discord file' });
        item.once('done', (_event, state) => {
          const metrics = { elapsed_ms: Date.now() - record.startedAt };
          try { metrics.received_bytes = item.getReceivedBytes(); } catch (_) { }
          try { metrics.total_bytes = item.getTotalBytes(); } catch (_) { }
          cleanup(record);
          if (state === 'completed') log('COMPLETED', metrics);
          else if (state === 'cancelled') log('CANCELLED');
          else report('INTERRUPTED', metrics);
        });
        log('SAVING');
      } catch (_) {
        try { item.cancel(); } catch (_) { }
        cleanup(record); report('FAILED');
      }
    };
    session.on('will-download', handler);
    sessions.set(session, handler);
  }
  function wrapped(url) {
    if (!validateAttachmentUrl(url)) return original.apply(this, arguments);
    // Official core logs the URL when openExternal rejects. Intercepted errors
    // therefore always resolve and are reported using fixed diagnostic strings.
    try {
      const key = new URL(url).href;
      const existing = pending.get(key);
      if (existing) { if (existing.expired) report('TIMEOUT'); else log('DUPLICATE'); return Promise.resolve(); }
      if (pending.size >= maximumPending) { report('BUSY'); return Promise.resolve(); }
      const window = findWindow();
      if (!window) { report('NO_WINDOW'); return Promise.resolve(); }
      const contents = window.webContents;
      const record = { key, contents, session: contents.session, timer: null, item: null, expired: false, startedAt: Date.now() };
      pending.set(key, record);
      try {
        observe(record.session, contents);
        record.timer = schedule(() => {
          if (pending.get(key) !== record || record.item || record.expired) return;
          record.timer = null;
          // Retain this bounded tombstone. Removing the observer here would let
          // a late callback silently download, and a retry is indistinguishable.
          // The late event or destruction of its window releases the record.
          record.expired = true;
          report('TIMEOUT');
        }, pendingMilliseconds);
        if (record.timer && typeof record.timer.unref === 'function') record.timer.unref();
        contents.downloadURL(url);
        log('STARTED');
      } catch (_) { cleanup(record); report('FAILED'); }
    } catch (_) { report('FAILED'); }
    return Promise.resolve();
  }
  try {
    shell.openExternal = wrapped;
    if (shell.openExternal !== wrapped) throw new Error('unavailable');
    Object.defineProperty(shell, installed, { value: true });
  } catch (_) {
    try { if (shell.openExternal === wrapped) shell.openExternal = original; } catch (_) { }
    report('UNAVAILABLE'); return false;
  }
  log('READY');
  return true;
}

module.exports = { install, validateAttachmentUrl };
if (process.env.DISCORDACCESS_ATTACHMENTS === '1' && process.type !== 'renderer') {
  try { install(require('electron')); }
  catch (_) {
    try { createLogger(require('fs'), process.env.DISCORDACCESS_DOWNLOAD_LOG)('UNAVAILABLE'); } catch (_) { }
  }
}
