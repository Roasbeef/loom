// Exercise the pinned Lustre transport itself with controlled sockets and
// timers. No DOM, network connection or copied transport implementation runs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { argv } from 'node:process';
import vm from 'node:vm';

const source = readFileSync(argv[2] ?? new URL(
  '../build/dev/javascript/lustre/lustre/runtime/client/server_component.ffi.mjs',
  import.meta.url,
), 'utf8');
const start = source.indexOf('class WebsocketTransport {');
const end = source.indexOf('\nclass SseTransport', start);
assert.ok(start >= 0 && end > start, 'the pinned runtime exposes the tested transport');
const executable = source.slice(start, end) + '\nglobalThis.Transport = WebsocketTransport;';

function fixture() {
  const sockets = [];
  const timers = [];
  class Socket {
    static OPEN = 1;
    readyState = 0;
    sent = [];
    constructor() { sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    open() { this.readyState = Socket.OPEN; this.onopen(); }
    receive(data) { this.onmessage({ data: JSON.stringify(data) }); }
    close(code) { this.readyState = 3; this.onclose({ code }); }
  }
  const context = {
    WebSocket: Socket,
    document: { hidden: false },
    setTimeout: (callback, delay) => timers.push({ callback, delay }),
    batch_kind: 4,
  };
  vm.runInNewContext(executable, context);
  const transport = new context.Transport('ws://fixture.invalid', {
    onConnect() {}, onMessage() {}, onClose() {},
  });
  return { transport, sockets, timers };
}

{
  const { transport, sockets, timers } = fixture();
  sockets[0].open();
  transport.send({ name: 'submit', event: { text: 'sent once' } });
  transport.send({ name: 'submit', event: { text: 'waiting behind lost reply' } });
  assert.equal(sockets[0].sent.length, 1);
  sockets[0].close(4000);
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, 500);
  timers.shift().callback();
  assert.equal(sockets.length, 2);
  sockets[1].open();
  sockets[1].receive({ kind: 'fresh mount' });
  assert.deepEqual(sockets[1].sent, [], 'neither the sent nor queued submit is replayed');
  transport.send({ name: 'read current state' });
  assert.deepEqual(sockets[1].sent, [{ name: 'read current state' }]);
  assert.deepEqual(sockets[0].sent, [{ name: 'submit', event: { text: 'sent once' } }]);
}

{
  const { transport, sockets, timers } = fixture();
  sockets[0].open();
  transport.send({ name: 'submit', event: { text: 'unacknowledged' } });
  sockets[0].close(1000);
  assert.deepEqual(timers, [], 'a revoked or expired page remains final');
}

console.log('ok reconnect drops sent and queued commands; final closes stay final');
