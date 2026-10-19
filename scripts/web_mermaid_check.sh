#!/usr/bin/env bash
# Drive the real seeded session page through Mermaid rendering and recovery.
# Build the daemon and assets, start scripts/web_seed/seed.sh, then pass its
# operator URL (or a file containing it). This sends the fixture prompt
# "mermaid"; use only a disposable session configured with fake_anthropic.py.
# No production session or installed daemon is needed or modified.
set -euo pipefail
url=${1:?usage: web_mermaid_check.sh <seeded operator URL | URL file>}
if [ -f "$url" ]; then url=$(head -n 1 "$url"); fi
# The seeded turn streams its answer and runs the advisor before the third
# fence settles, which outlasts agent-browser's 25 s default wait.
export AGENT_BROWSER_DEFAULT_TIMEOUT=${AGENT_BROWSER_DEFAULT_TIMEOUT:-120000}
export AGENT_BROWSER_SESSION=${AGENT_BROWSER_SESSION:-$(agent-browser session id --scope worktree --prefix mermaid)}
agent-browser open "$url" >/dev/null

# A ticket link redirects to the keyed page. Helpers installed before that
# navigation would be lost with the document they were defined in.
agent-browser wait --fn "location.pathname.startsWith('/ui/p/')" >/dev/null

# The helper crosses Lustre's server and client shadow roots, not frame
# boundaries. Source and SVG must never share the session page's origin.
agent-browser eval --stdin <<'JS'
window.mermaidFind = function find(root, selector) {
  const match = root.querySelector(selector);
  if (match) return match;
  for (const node of root.querySelectorAll('*')) {
    if (node.shadowRoot) {
      const child = find(node.shadowRoot, selector);
      if (child) return child;
    }
  }
  return null;
};
window.mermaidEvents = [];
window.addEventListener('message', event => {
  try {
    const data = JSON.parse(event.data);
    if (['ready', 'rendered', 'failed'].includes(data.kind)) {
      window.mermaidEvents.push({source: event.source, data});
    }
  } catch (_) { /* Non-diagram messages are unrelated to this fixture. */ }
});
true
JS
agent-browser wait --fn "Boolean(mermaidFind(document, 'textarea'))" >/dev/null
agent-browser eval --stdin <<'JS'
(() => {
  const area = mermaidFind(document, 'textarea');
  area.value = 'mermaid';
  area.dispatchEvent(new Event('input', {bubbles: true, composed: true}));
  const form = area.closest('form');
  const button = form.querySelector('button[type=submit]');
  if (!button) throw new Error('seed composer has no submit button');
  form.requestSubmit(button);
  return 'sent deterministic Mermaid fixture prompt';
})()
JS
agent-browser wait --fn "(() => { const el = mermaidFind(document, 'loom-mermaid'); return el && el.parentNode.querySelectorAll('loom-mermaid').length >= 3; })()" >/dev/null

# The checks outlast one CDP evaluation, so they run in the page and publish
# their outcome; the shell polls for it rather than awaiting the promise.
agent-browser eval --stdin <<'JS'
window.mermaidDone = null;
(async () => {
  const check = (ok, label) => { if (!ok) throw new Error(label); results.push(label); };
  const results = [];
  const waitFor = async (predicate, label) => {
    const until = performance.now() + 15000;
    while (!predicate()) {
      if (performance.now() > until) throw new Error('timeout: ' + label);
      await new Promise(resolve => setTimeout(resolve, 30));
    }
  };
  // The streamed row is replaced by the committed one when the turn ends, so
  // the elements are found again on every poll rather than captured once.
  const current = () => {
    const found = mermaidFind(document, 'loom-mermaid');
    return found ? Array.from(found.parentNode.querySelectorAll('loom-mermaid')) : [];
  };
  const frame = host => host.shadowRoot?.querySelector('iframe');
  const shown = host => frame(host) && !frame(host).classList.contains('mermaid-pending');
  const unavailable = host => host.shadowRoot?.querySelector('.mermaid-toolbar')?.textContent.includes('Diagram unavailable');
  await waitFor(() => {
    const [a, b, c] = current();
    return c && shown(a) && shown(b) && unavailable(c);
  }, 'flowchart, sequence and invalid fallback');
  const diagrams = current();
  const first = diagrams[0];
  check(diagrams.length === 3, 'streamed Markdown produced three Mermaid elements');
  check(shown(diagrams[0]) && shown(diagrams[1]), 'flowchart and sequence render under the real response CSP');
  check(diagrams[2].shadowRoot.querySelector('details').open, 'invalid diagram leaves source expanded');
  check(frame(first).getAttribute('sandbox') === 'allow-scripts', 'frame grants scripts but not same-origin, forms or navigation');
  check(frame(first).contentDocument === null, 'renderer document is inaccessible to the session page');
  check(!first.shadowRoot.querySelector('svg'), 'no renderer SVG enters the parent shadow tree');
  check(!first.shadowRoot.querySelector('details').open, 'successful diagram has collapsible source');
  check(frame(first).getBoundingClientRect().height >= 120, 'rendered frame has a usable height');

  const source = first.querySelector('.mermaid-source');
  const original = source.textContent;
  const setSource = text => { source.textContent = text; };
  const refuseSource = async (text, label) => {
    const before = mermaidEvents.length;
    setSource(text);
    await waitFor(() => mermaidEvents.slice(before).some(e =>
      e.source === frame(first)?.contentWindow && e.data.kind === 'failed') && unavailable(first), label);
  };
  await refuseSource('not a diagram', 'invalid source');
  check(first.shadowRoot.querySelector('details').open && source.textContent === 'not a diagram', 'parse failure preserves exact selectable source');
  setSource('x'.repeat(32001));
  await waitFor(() => !frame(first), 'source bound');
  check(first.shadowRoot.textContent.includes('Diagram too large'), 'oversized source never reaches a renderer frame');
  setSource('flowchart LR\n A[Recovered] --> B[Current]');
  await waitFor(() => shown(first), 'recovery after oversized source');
  check(shown(first), 'valid source recovers after frame removal');

  const beforeBurst = mermaidEvents.length;
  for (let n = 0; n < 30; n++) setSource('flowchart LR\n A[Revision ' + n + '] --> B[Latest]');
  await waitFor(() => mermaidEvents.slice(beforeBurst).some(e => e.source === frame(first)?.contentWindow && e.data.kind === 'rendered') && shown(first), 'latest streamed source');
  check(source.textContent.includes('Revision 29'), 'rapid source changes retain the latest revision');
  const currentFrame = frame(first);
  const reply = [...mermaidEvents].reverse().find(e => e.source === currentFrame.contentWindow && e.data.kind === 'rendered');
  check(Boolean(reply), 'renderer returns a revisioned result without SVG');
  const height = currentFrame.getAttribute('height');
  window.dispatchEvent(new MessageEvent('message', {source: window, data: JSON.stringify({kind:'rendered', revision:reply.data.revision, height:1999})}));
  window.dispatchEvent(new MessageEvent('message', {source: currentFrame.contentWindow, data: JSON.stringify({kind:'rendered', revision:reply.data.revision - 1, height:1998})}));
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  check(currentFrame.getAttribute('height') === height, 'foreign-window and stale-revision messages are ignored');

  const initialTheme = document.documentElement.getAttribute('data-theme') ||
    (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
  for (const theme of [initialTheme === 'dark' ? 'light' : 'dark', initialTheme]) {
    const previous = mermaidEvents.length;
    const lastRevision = [...mermaidEvents].reverse().find(e =>
      e.source === frame(first)?.contentWindow && e.data.kind === 'rendered').data.revision;
    document.documentElement.setAttribute('data-theme', theme);
    await waitFor(() => mermaidEvents.slice(previous).some(e => e.source === frame(first)?.contentWindow && e.data.kind === 'rendered' && e.data.revision > lastRevision) && shown(first), theme + ' palette');
    check(shown(first), theme + ' theme redraws successfully');
  }
  await refuseSource('%%{init: {"securityLevel":"loose"}}%%\nflowchart LR\nA-->B', 'configuration directive refusal');
  check(first.shadowRoot.querySelector('details').open, 'session-supplied renderer configuration is refused');
  await refuseSource('  ---\n  config:\n    theme: forest\n  ---\nflowchart LR\nA-->B', 'indented frontmatter refusal');
  check(first.shadowRoot.querySelector('details').open, 'indented renderer configuration is refused');
  await refuseSource('flowchart LR\n A[Link] --> B\n click A "https://mermaid-test.invalid/should-not-load"', 'navigation directive refusal');
  check(unavailable(first), 'diagram navigation directives do not become links');
  setSource(original);
  await waitFor(() => shown(first), 'original source restored');

  const parent = first.parentNode;
  const next = first.nextSibling;
  const departed = frame(first).contentWindow;
  first.remove();
  parent.insertBefore(first, next);
  await waitFor(() => shown(first) && frame(first).contentWindow !== departed, 'disconnect and reconnect');
  const restored = frame(first);
  const restoredHeight = restored.getAttribute('height');
  window.dispatchEvent(new MessageEvent('message', {source: departed, data: JSON.stringify({kind:'rendered', revision:999, height:1999})}));
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  check(restored.getAttribute('height') === restoredHeight, 'a disconnected frame cannot alter its replacement');
  check(source.textContent === original, 'reconnection preserves the original source');
  return {passed: results.length, checks: results};
})().then(
  outcome => { window.mermaidDone = {ok: true, ...outcome}; },
  error => {
    // Report each diagram's state; a failed drive is otherwise a bare label.
    const first = mermaidFind(document, 'loom-mermaid');
    const state = first ? Array.from(first.parentNode.querySelectorAll('loom-mermaid'), host => {
      const frame = host.shadowRoot?.querySelector('iframe');
      const toolbar = host.shadowRoot?.querySelector('.mermaid-toolbar')?.textContent;
      return (frame ? frame.className + ' height=' + frame.getAttribute('height') : 'no frame') + ' | ' + toolbar;
    }) : [];
    window.mermaidDone = {ok: false, error: String(error), state, events: mermaidEvents.map(e => e.data)};
  },
);
true
JS
agent-browser wait --fn "window.mermaidDone !== null" >/dev/null
outcome=$(agent-browser eval "JSON.stringify(window.mermaidDone)")
echo "$outcome"
case "$outcome" in
*'\"ok\":true'* | *'"ok":true'*) ;;
*) exit 1 ;;
esac
