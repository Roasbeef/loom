// create-remote-session.mjs: create a session whose workspace lives on an
// executor, over the daemon's control protocol (docs/client-protocol.md, 3.7).
//
// Neither the terminal client nor the web view can pass `executor` yet, so
// this is the way to make a remote session today. It needs Node 22 or newer,
// whose built-in WebSocket accepts request headers.
//
// Usage:
//   node create-remote-session.mjs PORT TOKEN_FILE EXECUTOR WORKSPACE CONFIG [NAME]
//
//   PORT        the orchestrator's client port (its --bind port)
//   TOKEN_FILE  the orchestrator's owner.token, in its state directory
//   EXECUTOR    an [executors.<name>] key of the orchestrator's loom.toml
//   WORKSPACE   a [workspaces.<name>] key of the executor's loom.toml
//   CONFIG      absolute path of a loom.toml on the orchestrator for the session
//
// It prints the daemon's reply and exits 0 when the daemon accepted the
// creation, 1 when it refused, 2 on a connection problem or timeout. The
// request key is derived from the arguments, so repeating a command recovers
// the same session instead of creating a second one.
import fs from 'node:fs';

const [, , port, tokenFile, executor, workspace, config, name = 'remote'] = process.argv;
if (!config) {
  console.error('usage: node create-remote-session.mjs PORT TOKEN_FILE EXECUTOR WORKSPACE CONFIG [NAME]');
  process.exit(64);
}

const token = fs.readFileSync(tokenFile, 'utf8').trim();
const socket = new WebSocket(`ws://127.0.0.1:${port}/v2/control`, {
  headers: { Authorization: `Bearer ${token}` },
});

const timer = setTimeout(() => {
  console.error('timed out waiting for the daemon');
  process.exit(2);
}, 10000);

socket.onerror = (event) => {
  console.error(`cannot reach the daemon on port ${port}: ${event.message ?? 'connection failed'}`);
  process.exit(2);
};

socket.onmessage = (message) => {
  const frame = JSON.parse(message.data);
  if (frame.event === 'hello') {
    socket.send(JSON.stringify({
      v: 2,
      id: 1,
      cmd: 'sessions.create',
      body: { request_key: `remote:${executor}:${workspace}:${name}`, workspace, name, configuration: config, executor },
    }));
  } else if (frame.reply_to === 1) {
    clearTimeout(timer);
    console.log(JSON.stringify(frame.body));
    socket.close();
    process.exit(frame.event === 'error' ? 1 : 0);
  }
};
