'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'work', 'external-wrapper-fixture.cjs'), 'utf8');
const expected = JSON.parse(fs.readFileSync(path.join(root, 'work', 'external-wrapper-fixture.json'), 'utf8'));
let checks = 0;
function requireTrue(value, label) { checks++; if (!value) throw Error(label); }
function run(type, proxy, brokenElectron) {
  const env = Object.freeze({SYNTHETIC_EXISTING_ENV:'preserved'});
  const events = [], core = {official: true};
  const electron = {app:{commandLine:{getSwitchValue(name){requireTrue(name === 'proxy-server', 'only proxy switch read'); return proxy;}}}};
  const ctx = {process:{type,env}, module:{exports:{}}, require(name) {
    if (name === 'electron') { if (brokenElectron) throw Error('inert electron failure'); return electron; }
    if (name === expected.hook) return {install(actual,options){requireTrue(actual === electron,'same Electron instance'); events.push(options);}};
    if (name === './core.asar') return core;
    throw Error('unexpected module request');
  }};
  vm.runInNewContext(source, ctx, {timeout:1000});
  requireTrue(ctx.module.exports === core, 'official core exports preserved');
  requireTrue(ctx.process.env === env && Object.keys(env).length === 1,'global environment never changed');
  return events;
}
let events = run('browser', expected.proxy, false);
requireTrue(events.length === 1, 'matching browser activates download helper');
requireTrue(events[0].env.DISCORDACCESS_ATTACHMENTS === '1', 'explicit attachment opt-in');
requireTrue(events[0].env.DISCORDACCESS_DOWNLOAD_LOG === expected.downloadLog,'fixed journaled log path');
requireTrue(Object.keys(events[0].env).length === 2,'no unrelated injected settings');
for (const proxy of ['', 'http://127.0.0.1:1','http://localhost:32109','https://127.0.0.1:32109'])
  requireTrue(run('browser', proxy, false).length === 0, 'other proxy does not activate');
for (const type of ['renderer','utility',undefined])
  requireTrue(run(type, expected.proxy, false).length === 0, 'non-browser core remains ordinary');
requireTrue(run('browser', expected.proxy, true).length === 0, 'Electron failure preserves normal core');
console.log(`External original Discord wrapper: PASS (${checks} mocked checks; no network or Discord)`);
