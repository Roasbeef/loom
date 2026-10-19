// Deterministic adapter tests, not a substitute for the real browser drive.
// The vendor is replaced by a controllable promise so superseded renders and
// parser failures can be tested without npm dependencies or a browser DOM.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('./renderer.js', import.meta.url), 'utf8');
assert.equal(source.split('import mermaid from "mermaid";').length, 2);
const adapter = source.replace('import mermaid from "mermaid";', '');
let passed = 0;

function fixture() {
  const sent = [];
  const pending = [];
  const configurations = [];
  let receive;
  let resize;
  const parent = { postMessage: text => sent.push(JSON.parse(text)) };
  const host = {
    children: [],
    replaceChildren(...children) { this.children = children; },
    querySelector() { return this.children[0] || null; },
  };
  class Parser {
    parseFromString(markup) {
      const unsafe = /<(a|foreignObject|script|image)(\s|>)/.test(markup);
      const root = {
        localName: markup.startsWith('<svg') ? 'svg' : 'html',
        attributes: markup.includes('external-href') ? [{name: 'href', value:'https://not-used.invalid'}] : [],
        querySelector: () => unsafe ? {} : null,
        querySelectorAll: () => [],
        setAttribute() {},
        style: {},
        getBoundingClientRect: () => ({height: 300}),
      };
      return {documentElement: root, querySelector: () => null};
    }
  }
  const mermaid = {
    initialize: config => configurations.push(config),
    render: (id, text) => new Promise((resolve, reject) => pending.push({id, text, resolve, reject})),
  };
  vm.runInNewContext(adapter, {
    mermaid, parent, DOMParser: Parser,
    document: { getElementById: () => host, documentElement: {}, importNode: node => node },
    window: { addEventListener: (_event, handler) => { receive = handler; } },
    ResizeObserver: class { constructor(handler) { resize = handler; } observe() {} },
  });
  return {
    sent, pending, configurations, host,
    request(revision, text = 'flowchart LR\nA-->B', theme = 'dark', sender = parent) {
      receive({source: sender, data: JSON.stringify({source: text, theme, revision})});
    },
    raw(data, sender = parent) { receive({source: sender, data}); },
    resize(width) { resize([{contentRect: {width}}]); },
  };
}

async function settle() {
  // Cross-context promise continuations run before this turn of the host loop.
  await new Promise(resolve => setTimeout(resolve, 0));
}

function test(name, run) {
  return Promise.resolve().then(run).then(() => { passed++; console.log('ok ' + name); });
}

await test('ready handshake and malformed or foreign requests do not render', () => {
  const f = fixture();
  assert.deepEqual(f.sent, [{kind:'ready'}]);
  for (const data of [null, {}, 'not JSON', '{}', 'null', '[]']) f.raw(data);
  f.request(1, 'flowchart LR\nA-->B', 'dark', {});
  f.request(0);
  f.request(-1);
  f.request(1.5);
  f.request(1, 'flowchart LR\nA-->B', 'forest');
  f.request(1, 'x'.repeat(32001));
  assert.equal(f.pending.length, 0);
  assert.deepEqual(f.sent, [{kind:'ready'}]);
});

await test('configuration and navigation directives are refused before vendor parsing', () => {
  const f = fixture();
  const refused = [
    '%%{init: {"securityLevel":"loose"}}%%\nflowchart LR\nA-->B',
    '---\nconfig:\n  theme: forest\n---\nflowchart LR\nA-->B',
    '  ---\n  config:\n    theme: forest\n  ---\nflowchart LR\nA-->B',
    '\t---\nconfig:\n  theme: forest\n\t---\nflowchart LR\nA-->B',
    'flowchart LR\n A-->B\n click A "https://not-used.invalid"',
  ];
  refused.forEach((text, index) => f.request(index + 1, text));
  assert.equal(f.pending.length, 0);
  assert.deepEqual(f.sent.slice(1), refused.map((_, index) => ({kind:'failed', revision:index + 1})));
});

await test('only the newest queued revision renders and publishes', async () => {
  const f = fixture();
  f.request(1, 'flowchart LR\nA-->Old');
  f.request(2, 'flowchart LR\nA-->Skipped');
  f.request(3, 'flowchart LR\nA-->Latest');
  assert.equal(f.pending.length, 1);
  f.pending[0].resolve({svg:'<svg></svg>'});
  await settle();
  assert.equal(f.pending.length, 2);
  assert.match(f.pending[1].text, /Latest/);
  assert.equal(f.sent.length, 1);
  f.pending[1].resolve({svg:'<svg></svg>'});
  await settle();
  assert.deepEqual(f.sent[1], {kind:'rendered', revision:3, height:300});
  f.request(3);
  assert.equal(f.pending.length, 2);
  const config = f.configurations.at(-1);
  assert.equal(config.securityLevel, 'strict');
  assert.equal(config.startOnLoad, false);
  assert.equal(config.htmlLabels, false);
  assert.equal(config.flowchart.htmlLabels, false);
  assert.equal(config.maxTextSize, 32000);
  assert.equal(config.maxEdges, 250);
});

await test('unsafe generated SVG is refused without forwarding markup', async () => {
  for (const svg of ['<html></html>', '<svg><a href="https://not-used.invalid"></a></svg>', '<svg><foreignObject></foreignObject></svg>', '<svg><script></script></svg>', '<svg><image href="x"></image></svg>', '<svg external-href></svg>']) {
    const f = fixture();
    f.request(1);
    f.pending[0].resolve({svg});
    await settle();
    assert.deepEqual(f.sent.at(-1), {kind:'failed', revision:1});
    assert.equal(f.host.children.length, 0);
  }
});

await test('parser errors are fixed status messages and width changes do not loop', async () => {
  const f = fixture();
  f.request(1);
  f.pending[0].reject(new Error('private source and vendor diagnostic'));
  await settle();
  assert.deepEqual(f.sent.at(-1), {kind:'failed', revision:1});
  f.request(2);
  f.pending[1].resolve({svg:'<svg></svg>'});
  await settle();
  f.resize(600);
  const count = f.sent.length;
  f.resize(600);
  assert.equal(f.sent.length, count);
  f.resize(400);
  assert.deepEqual(f.sent.at(-1), {kind:'rendered', revision:2, height:300});
  assert.equal(f.sent.length, count + 1);
});

console.log(`${passed} renderer adapter checks passed`);
