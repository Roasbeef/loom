// Mermaid's DOM generation is confined to an opaque, network-disabled frame.
// Only the parent window can submit bounded source; no SVG, vendor error or
// callback crosses back into the session page (protocol-change/091).
import mermaid from "mermaid";

const MAX_SOURCE = 32000;
const MAX_HEIGHT = 2000;
const MIN_HEIGHT = 120;
const host = document.getElementById("diagram");
let latest = 0;
let renderedRevision = 0;
let active = false;
let queued = null;

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  suppressErrorRendering: true,
  maxTextSize: MAX_SOURCE,
  maxEdges: 250,
  htmlLabels: false,
  theme: "default",
  flowchart: { htmlLabels: false },
});

function send(message) {
  parent.postMessage(JSON.stringify(message), "*");
}

function measuredHeight() {
  const svg = host.querySelector("svg");
  const svgHeight = svg ? svg.getBoundingClientRect().height : 0;
  return Math.max(MIN_HEIGHT, Math.min(MAX_HEIGHT, Math.ceil(svgHeight)));
}

// The HTTP sandbox and CSP are the isolation boundary. This additional
// filter removes navigation and embedded-document features before display.
function safeSvg(markup) {
  const parsed = new DOMParser().parseFromString(markup, "image/svg+xml");
  const root = parsed.documentElement;
  if (root.localName !== "svg" || parsed.querySelector("parsererror")) return null;
  if (root.querySelector("a, foreignObject, script, image")) return null;
  for (const element of [root, ...root.querySelectorAll("*")]) {
    for (const attribute of element.attributes) {
      if ((attribute.name === "href" || attribute.name.endsWith(":href")) &&
          !attribute.value.startsWith("#")) return null;
    }
  }
  return root;
}

// One vendor promise runs at a time. A single queued request is replaced
// by newer source, so neither stale completion nor a burst builds a backlog.
async function drain() {
  if (active || !queued) return;
  active = true;
  const request = queued;
  queued = null;
  try {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      suppressErrorRendering: true,
      maxTextSize: MAX_SOURCE,
      maxEdges: 250,
      htmlLabels: false,
      theme: request.theme,
      flowchart: { htmlLabels: false },
    });
    host.replaceChildren();
    const result = await mermaid.render(`loom-diagram-${request.revision}`, request.source, host);
    if (request.revision !== latest) return;
    const svg = safeSvg(result.svg);
    if (!svg) throw new Error("unsafe svg");
    host.replaceChildren(document.importNode(svg, true));
    const renderedSvg = host.querySelector("svg");
    if (renderedSvg) {
      renderedSvg.setAttribute("role", "img");
      renderedSvg.setAttribute("aria-label", "Rendered Mermaid diagram");
      renderedSvg.style.maxWidth = "100%";
      renderedSvg.style.height = "auto";
    }
    renderedRevision = request.revision;
    send({ kind: "rendered", revision: request.revision, height: measuredHeight() });
  } catch (_) {
    host.replaceChildren();
    if (request.revision === latest) send({ kind: "failed", revision: request.revision });
  } finally {
    active = false;
    if (queued) void drain();
  }
}

window.addEventListener("message", (event) => {
  if (event.source !== parent || typeof event.data !== "string") return;
  let request;
  try { request = JSON.parse(event.data); } catch (_) { return; }
  if (!request || typeof request.source !== "string" || request.source.length > MAX_SOURCE) return;
  if (!Number.isSafeInteger(request.revision) || request.revision <= latest) return;
  if (request.theme !== "dark" && request.theme !== "default") return;
  if (/%%\{|^\s*---\s*$|^\s*click\s+[^\n]+/m.test(request.source)) {
    latest = request.revision;
    queued = null;
    host.replaceChildren();
    send({ kind: "failed", revision: latest });
    return;
  }
  latest = request.revision;
  queued = request;
  void drain();
});

let lastWidth = 0;
new ResizeObserver((entries) => {
  const width = entries[0].contentRect.width;
  if (width === lastWidth) return;
  lastWidth = width;
  if (renderedRevision > 0) send({ kind: "rendered", revision: renderedRevision, height: measuredHeight() });
}).observe(document.documentElement);
send({ kind: "ready" });
