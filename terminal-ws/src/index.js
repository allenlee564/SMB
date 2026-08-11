const { WebSocketServer } = require('ws');
const pty = require('node-pty');

const PORT = process.env.PORT || 3000;
const TARGET_CONTAINER = process.env.TARGET_CONTAINER || 'target-box';
const TARGET_SHELL = process.env.TARGET_SHELL || 'bash';
const TARGET_USER = process.env.TARGET_USER || 'customer';

const wss = new WebSocketServer({ port: PORT });

wss.on('connection', (ws) => {
  const term = pty.spawn(
    'docker',
    ['exec', '-it', '-u', TARGET_USER, TARGET_CONTAINER, TARGET_SHELL],
    {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
    }
  );

  term.onData((data) => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });

  term.onExit(() => ws.close());

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg.type === 'input') {
      term.write(msg.data);
    } else if (msg.type === 'resize' && msg.cols && msg.rows) {
      term.resize(msg.cols, msg.rows);
    }
  });

  ws.on('close', () => term.kill());
});

console.log(`[terminal-ws] listening on ${PORT}, target container = ${TARGET_CONTAINER}`);
