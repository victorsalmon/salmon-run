import { test, mock } from 'node:test';
import assert from 'node:assert/strict';

const FAKE_MESSAGES = [
  {
    uid: 101,
    header: 'Subject: Test Invoice\r\nFrom: sender@example.com\r\nDate: Mon, 11 Aug 2026 10:00:00 +0000\r\n\r\n',
    attrs: { uid: 101, struct: [] },
  },
  {
    uid: 102,
    header: 'Subject: =?utf-8?B?SGVsbG8gV29ybGQ=?=\r\nFrom: other@example.com\r\nDate: Mon, 11 Aug 2026 11:00:00 +0000\r\n\r\n',
    attrs: { uid: 102, struct: [] },
  },
];

class FakeImap {
  constructor(opts) {
    this.opts = opts;
    this.handlers = {};
    this.ready = true;
  }

  once(evt, cb) {
    (this.handlers[evt] ||= []).push(cb);
    return this;
  }

  on(evt, cb) {
    (this.handlers[evt] ||= []).push(cb);
    return this;
  }

  removeListener() { return this; }
  removeAllListeners() { return this; }

  connect() {
    if (this.ready) {
      for (const cb of (this.handlers.ready || [])) cb();
    } else {
      for (const cb of (this.handlers.error || [])) cb(new Error('connection failed'));
    }
  }

  openBox(mailbox, _readonly, cb) {
    process.nextTick(() => cb(null, { name: mailbox }));
  }

  search(_criteria, cb) {
    process.nextTick(() => cb(null, FAKE_MESSAGES.map(m => m.uid)));
  }

  getBoxes(cb) {
    process.nextTick(() => cb(null, { INBOX: { delimiter: '/', children: null } }));
  }

  fetch(uids, _opts) {
    const emitter = { handlers: {} };
    emitter.on = (evt, cb) => {
      (emitter.handlers[evt] ||= []).push(cb);
      return emitter;
    };
    emitter.once = emitter.on;
    process.nextTick(() => {
      const targets = FAKE_MESSAGES.filter(m => uids.includes(m.uid));
      for (const msg of targets) {
        const fakeMsg = new FakeMessage(msg);
        for (const cb of (emitter.handlers.message || [])) {
          cb(fakeMsg, msg.uid);
        }
        fakeMsg.emitBody();
        fakeMsg.emitAttributes();
        fakeMsg.emitEnd();
      }
      for (const cb of (emitter.handlers.end || [])) cb();
    });
    return emitter;
  }

  addFlags(_uids, _flags, cb) {
    process.nextTick(() => cb(null));
  }

  end() {
    for (const cb of (this.handlers.end || [])) cb();
  }

  destroy() {}
}

class FakeMessage {
  constructor(data) {
    this.data = data;
    this.handlers = {};
  }

  on(evt, cb) {
    (this.handlers[evt] ||= []).push(cb);
    return this;
  }

  emitBody() {
    for (const cb of (this.handlers.body || [])) {
      const stream = {
        handlers: {},
        on: function (evt, fn) { (this.handlers[evt] ||= []).push(fn); return this; },
        emit: function (evt, arg) { for (const fn of (this.handlers[evt] || [])) fn(arg); },
      };
      process.nextTick(() => {
        stream.emit('data', Buffer.from(this.data.header, 'utf8'));
        stream.emit('end');
      });
      cb(stream);
    }
  }

  emitAttributes() {
    for (const cb of (this.handlers.attributes || [])) cb(this.data.attrs);
  }

  emitEnd() {
    for (const cb of (this.handlers.end || [])) cb();
  }
}

mock.module('imap', { namedExports: { default: FakeImap } });
const lib = await import('../lib/imap.mjs');

test('imap lib exports the expected connection entrypoints', async () => {
  for (const name of ['listMailboxes', 'checkMailbox', 'downloadUids', 'downloadAttachments', 'watchMailboxes']) {
    assert.equal(typeof lib[name], 'function', `${name} should be exported`);
  }
});

test('checkMailbox connects and fetches with a mocked IMAP server', async () => {
  const config = { host: 'imap.test', port: 993, tls: true, user: 'test-user', password: 'test-pass' };
  const messages = await lib.checkMailbox(config, 'INBOX');

  assert.equal(messages.length, 2, 'should return 2 messages');
  assert.equal(messages[0].uid, 101);
  assert.equal(messages[0].subject, 'Test Invoice');
  assert.equal(messages[0].from, 'sender@example.com');
  assert.equal(messages[1].subject, 'Hello World', 'mime-encoded subject should decode');
  assert.equal(messages[1].from, 'other@example.com');
});

test('listMailboxes flattens the box tree', async () => {
  const config = { host: 'imap.test', port: 993, tls: true, user: 'u', password: 'p' };
  const boxes = await lib.listMailboxes(config);

  assert.ok(Array.isArray(boxes));
  assert.ok(boxes.some(b => b.name === 'INBOX'));
});

test('downloadUids fetches only requested UIDs', async () => {
  const config = { host: 'imap.test', port: 993, tls: true, user: 'u', password: 'p' };
  const messages = await lib.downloadUids(config, [102], 'INBOX');

  assert.equal(messages.length, 1);
  assert.equal(messages[0].uid, 102);
});
