// These checks cover only the minimal foreign binding. Request validation,
// queueing, SVG policy and publication regressions run as Gleam controller tests.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const binding = readFileSync(new URL('../src/web_mermaid/internal/dom.mjs', import.meta.url), 'utf8');
const bootstrap = readFileSync(new URL('./renderer.js', import.meta.url), 'utf8');
const names = [...binding.matchAll(/export function (\w+)/g)].map(match => match[1]);
const executable = binding.replace(/^import .*;\n/m, '').replaceAll('export function ', 'function ') +
  '\nglobalThis.bridge = {' + names.join(',') + '};';
let passed = 0;

class Ok { constructor(value) { this.value = value; } }
class ErrorResult { constructor(value) { this.value = value; } }

function fixture(overrides = {}) {
  const sent = [];
  const listeners = [];
  const parent = { postMessage: (text, origin) => sent.push({text, origin}) };
  const document = {documentElement: {}, importNode: node => ({copied: node})};
  const context = {
    Ok, Error: ErrorResult, toList: Array.from,
    document, window: {parent, addEventListener: (name, handler) => listeners.push({name, handler})},
    DOMParser: class { parseFromString(text, type) { return {text, type}; } },
    ResizeObserver: class { constructor(callback) { this.callback = callback; } observe(node) { this.node = node; } },
    ...overrides,
  };
  vm.runInNewContext(executable, context);
  return {bridge: context.bridge, sent, listeners, parent, document};
}

async function check(name, body) {
  await body();
  passed++;
  console.log('ok ' + name);
}

await check('bootstrap injects a vendor but owns no controller state', () => {
  assert.match(bootstrap, /import \{ start \} from .*web_mermaid\.mjs/);
  assert.match(bootstrap, /start\(mermaid\)/);
  assert.doesNotMatch(bootstrap, /\b(let|var|initialize|render|addEventListener|DOMParser)\s*[=(]/);
});

await check('configuration conversion and XML exceptions become typed refusal', () => {
  const {bridge} = fixture();
  let actual;
  assert.ok(bridge.initialize({initialize: config => { actual = config; }}, '{"theme":"dark"}') instanceof Ok);
  assert.equal(actual.theme, 'dark');
  assert.ok(bridge.initialize({initialize() { throw new Error('private diagnostic'); }}, '{}') instanceof ErrorResult);
  assert.ok(bridge.initialize({}, 'invalid JSON') instanceof ErrorResult);
  const parsed = bridge.parse_svg('<not-svg/>');
  assert.ok(parsed instanceof Ok);
  assert.equal(parsed.value.type, 'image/svg+xml');
  const failing = fixture({DOMParser: class { parseFromString() { throw new Error('private diagnostic'); } }});
  assert.ok(failing.bridge.parse_svg('x') instanceof ErrorResult);
});

await check('vendor promise reports SVG exactly once without invoking callbacks', async () => {
  const {bridge} = fixture();
  const host = {};
  let calls = 0;
  let bound = false;
  const vendor = {render(id, source, target) {
    assert.equal(id, 'id');
    assert.equal(source, 'source');
    assert.equal(target, host);
    return Promise.resolve({svg:'<svg/>', bindFunctions() { bound = true; }});
  }};
  const outcome = await new Promise(resolve => bridge.render(vendor, 'id', 'source', host, result => {
    calls++;
    resolve(result);
  }));
  assert.ok(outcome instanceof Ok);
  assert.equal(outcome.value, '<svg/>');
  assert.equal(calls, 1);
  assert.equal(bound, false);
});

await check('sync throws, rejection and malformed vendor output do not leak diagnostics', async () => {
  const {bridge} = fixture();
  for (const vendor of [
    {render() { throw new Error('private diagnostic'); }},
    {render() { return Promise.reject(new Error('private diagnostic')); }},
    {render() { return Promise.resolve(null); }},
    {render() { return Promise.resolve({svg: false}); }},
  ]) {
    let calls = 0;
    const outcome = await new Promise(resolve => bridge.render(vendor, 'id', 'source', {}, result => {
      calls++;
      resolve(result);
    }));
    assert.ok(outcome instanceof ErrorResult);
    assert.equal(outcome.value, undefined);
    assert.equal(calls, 1);
  }
});

await check('DOM primitives preserve identity and do not choose message or SVG policy', () => {
  const {bridge, parent, listeners, sent} = fixture();
  assert.equal(bridge.is_parent_message({source: parent}), true);
  assert.equal(bridge.is_parent_message({source: {}}), false);
  const text = '{"kind":"ready"}';
  bridge.send_text(text);
  assert.equal(sent[0].text, text);
  assert.equal(sent[0].origin, '*');
  const handler = () => {};
  bridge.listen_messages(handler);
  assert.equal(listeners[0].handler, handler);
  assert.equal(listeners[0].name, 'message');
  assert.equal(bridge.message_data({data: 42}), 42);
  assert.ok(bridge.query_selector({querySelector() { return null; }}, '*') instanceof ErrorResult);
  const attribute = {name:'href', value:'https://not-followed.invalid'};
  assert.equal(bridge.attribute_name(attribute), 'href');
  assert.equal(bridge.attribute_value(attribute), 'https://not-followed.invalid');
  // Rejection of this external reference belongs to the Gleam SVG policy.
  const root = {};
  assert.equal(bridge.document_root({documentElement: root}).value, root);
  assert.ok(bridge.document_root({documentElement: null}) instanceof ErrorResult);
});

console.log(`${passed} renderer FFI checks passed`);
