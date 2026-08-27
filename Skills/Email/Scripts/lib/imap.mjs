import Imap from 'imap';
import fs, { createWriteStream, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

function buildConnection(config) {
  return new Imap({
    user: config.user,
    password: config.password,
    host: config.host,
    port: config.port || 993,
    tls: config.tls !== false,
    tlsOptions: { rejectUnauthorized: config.rejectUnauthorized !== false },
    connTimeout: config.connTimeout || 30000,
    authTimeout: config.authTimeout || 10000,
  });
}

function connectAsync(imap) {
  return new Promise((resolve, reject) => {
    imap.once('ready', () => resolve());
    imap.once('error', (err) => reject(err));
    imap.connect();
  });
}

function openBoxAsync(imap, mailbox) {
  return new Promise((resolve, reject) => {
    imap.openBox(mailbox || 'INBOX', false, (err, box) => {
      if (err) reject(err);
      else resolve(box);
    });
  });
}

function searchAsync(imap, criteria) {
  return new Promise((resolve, reject) => {
    imap.search(criteria, (err, results) => {
      if (err) reject(err);
      else resolve(results || []);
    });
  });
}

function getBoxesAsync(imap) {
  return new Promise((resolve, reject) => {
    imap.getBoxes((err, boxes) => {
      if (err) reject(err);
      else resolve(boxes);
    });
  });
}

function fetchMessagesAsync(imap, uids) {
  return new Promise((resolve, reject) => {
    const messages = [];
    const f = imap.fetch(uids, { bodies: 'HEADER.FIELDS (SUBJECT FROM DATE)', struct: true });
    f.on('message', (msg, seqno) => {
      const message = { seqno, uid: null, subject: '', from: '', date: null, attachments: [] };
      msg.on('body', (stream) => {
        let buffer = '';
        stream.on('data', (chunk) => { buffer += chunk.toString('utf8'); });
        stream.on('end', () => {
          const subjectMatch = buffer.match(/^Subject:\s*(.+)$/im);
          const fromMatch = buffer.match(/^From:\s*(.+)$/im);
          const dateMatch = buffer.match(/^Date:\s*(.+)$/im);
          if (subjectMatch) message.subject = mimeDecode(subjectMatch[1].trim());
          if (fromMatch) message.from = mimeDecode(fromMatch[1].trim());
          if (dateMatch) message.date = dateMatch[1].trim();
        });
      });
      msg.on('attributes', (attrs) => {
        message.uid = attrs.uid;
        if (attrs.struct) {
          collectAttachments(attrs.struct, message.attachments, '');
        }
      });
      msg.on('end', () => {
        messages.push(message);
      });
    });
    f.once('error', (err) => reject(err));
    f.once('end', () => resolve(messages));
  });
}

function collectAttachments(struct, target, prefix) {
  if (!struct) return;
  for (let i = 0; i < struct.length; i++) {
    const part = struct[i];
    if (Array.isArray(part)) {
      collectAttachments(part, target, prefix);
    } else if (part && part.disposition && part.disposition.type === 'attachment') {
      const filename = (part.disposition.params && part.disposition.params.filename)
        || (part.params && part.params.name)
        || `attachment_${i}`;
      const partID = part.partID || `${prefix}${i + 1}`;
      target.push({
        partID,
        filename,
        encoding: (part.encoding || 'BASE64').toUpperCase(),
        size: part.size || 0,
        type: ((part.type || '') + '/' + (part.subtype || '')).toLowerCase(),
      });
    } else if (part && part.type && part.subtype
      && part.type.toUpperCase() === 'APPLICATION' && part.subtype.toUpperCase() === 'PDF'
      && part.disposition && part.disposition.type === 'inline') {
      const filename = (part.params && part.params.name) || 'document.pdf';
      const partID = part.partID || `${prefix}${i + 1}`;
      target.push({
        partID,
        filename,
        encoding: (part.encoding || 'BASE64').toUpperCase(),
        size: part.size || 0,
        type: 'application/pdf',
      });
    }
  }
}

function getPartDataAsync(imap, uid, partID) {
  return new Promise((resolve, reject) => {
    const f = imap.fetch(uid, { bodies: partID });
    let data = null;
    f.on('message', (msg) => {
      msg.on('body', (stream) => {
        const chunks = [];
        stream.on('data', (chunk) => chunks.push(chunk));
        stream.on('end', () => {
          data = Buffer.concat(chunks);
        });
      });
    });
    f.once('error', (err) => reject(err));
    f.once('end', () => resolve(data));
  });
}

function addFlagsAsync(imap, uids, flags) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      imap.removeListener('error', reject);
      reject(new Error('addFlags timeout'));
    }, 15000);
    imap.addFlags(uids, flags, (err) => {
      clearTimeout(timer);
      if (err) reject(err);
      else resolve();
    });
  });
}

function endAsync(imap) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      imap.removeAllListeners('end');
      try { imap.destroy(); } catch {}
      resolve();
    }, 15000);
    imap.once('end', () => {
      clearTimeout(timer);
      resolve();
    });
    imap.end();
  });
}

export async function listMailboxes(config) {
  const imap = buildConnection(config);
  await connectAsync(imap);
  const boxes = await getBoxesAsync(imap);
  await endAsync(imap);
  return flattenBoxTree(boxes, '');
}

function flattenBoxTree(boxes, prefix) {
  const result = [];
  for (const [name, box] of Object.entries(boxes)) {
    const delimiter = box.delimiter || '/';
    const fullName = prefix ? `${prefix}${delimiter}${name}` : name;
    const entry = { name: fullName, delimiter };
    if (box.children) {
      const children = flattenBoxTree(box.children, fullName);
      entry.children = children.map(c => c.name);
      result.push(...children);
    }
    result.push(entry);
  }
  return result;
}

export async function checkMailbox(config, mailbox = 'INBOX', all = false) {
  const imap = buildConnection(config);
  await connectAsync(imap);
  await openBoxAsync(imap, mailbox);
  const criteria = all ? ['ALL'] : ['UNSEEN'];
  const uids = await searchAsync(imap, criteria);
  if (!uids || uids.length === 0) {
    await endAsync(imap);
    return [];
  }
  const messages = await fetchMessagesAsync(imap, uids);
  await endAsync(imap);
  return messages;
}

export async function downloadUids(config, uids, mailbox = 'INBOX') {
  const imap = buildConnection(config);
  await connectAsync(imap);
  await openBoxAsync(imap, mailbox);
  const messages = await fetchMessagesAsync(imap, uids);
  await endAsync(imap);
  return messages;
}

function mimeDecode(str) {
  if (!str || !str.includes('=?')) return str;
  return str.replace(/=\?([^?]+)\?(B|Q)\?([^?]*)\?=/g, (_, charset, enc, text) => {
    try {
      if (enc === 'B') return Buffer.from(text, 'base64').toString('utf8');
      if (enc === 'Q') return decodeURIComponent(text.replace(/=([0-9A-F]{2})/g, '%$1'));
    } catch { return text; }
  });
}

function sanitizeFilename(name) {
  return name
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '')
    .slice(0, 100) || 'attachment';
}

const IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/jpg']);

export async function watchMailboxes(mailboxConfigs, stateFile) {
  const results = [];
  let state = {};
  if (stateFile) {
    try { state = JSON.parse(await fs.promises.readFile(stateFile, 'utf8')); }
    catch { state = {}; }
  }
  for (const cfg of mailboxConfigs) {
    try {
      const imap = buildConnection(cfg);
      await connectAsync(imap);
      await openBoxAsync(imap, cfg.mailbox || 'INBOX');
      const lastUid = state[cfg.key || cfg.user] || 0;
      const criteria = lastUid > 0 ? ['UID', `${lastUid + 1}:*`] : ['UNSEEN'];
      const uids = await searchAsync(imap, criteria);
      if (uids && uids.length > 0) {
        const messages = await fetchMessagesAsync(imap, uids);
        for (const msg of messages) {
          const downloadDir = cfg.download_dir || join('incoming', cfg.key || cfg.user, String(Date.now()));
          mkdirSync(downloadDir, { recursive: true });
          const files = [];
          for (const att of msg.attachments) {
            if (att.type !== 'application/pdf' && !att.filename.toLowerCase().endsWith('.pdf')) continue;
            try {
              const raw = await getPartDataAsync(imap, msg.uid, att.partID);
              if (!raw || raw.length === 0) continue;
              const decoded = att.encoding === 'BASE64'
                ? Buffer.from(raw.toString('utf8').replace(/\s/g, ''), 'base64')
                : raw;
              const safeName = `${new Date(msg.date || Date()).toISOString().split('T')[0]}_${msg.uid}_${att.filename}`;
              const filePath = join(downloadDir, safeName);
              createWriteStream(filePath).end(decoded);
              files.push(filePath);
            } catch (err) {
              results.push({ mailbox: cfg.key, uid: msg.uid, error: err.message });
            }
          }
          if (cfg.onAttachment) {
            for (const fp of files) await cfg.onAttachment(fp, msg);
          }
          if (msg.uid && msg.uid > lastUid) state[cfg.key || cfg.user] = msg.uid;
        }
        await addFlagsAsync(imap, uids, ['\\Seen']).catch(() => {});
      }
      await endAsync(imap);
    } catch (err) {
      results.push({ mailbox: cfg.key, error: err.message });
    }
  }
  if (stateFile) {
    await fs.promises.mkdir(require('path').dirname(stateFile), { recursive: true });
    await fs.promises.writeFile(stateFile, JSON.stringify(state, null, 2));
  }
  return results;
}

export async function downloadAttachments(config, uids, outputDir, includeImages = true) {
  mkdirSync(outputDir, { recursive: true });
  const imap = buildConnection(config);
  await connectAsync(imap);
  await openBoxAsync(imap, 'INBOX');
  const messages = await fetchMessagesAsync(imap, uids);
  const results = [];
  for (const msg of messages) {
    const files = [];
    const datePrefix = msg.date
      ? new Date(msg.date).toISOString().split('T')[0]
      : new Date().toISOString().split('T')[0];
    const subjectSlug = sanitizeFilename(msg.subject || 'no-subject').slice(0, 60);
    const attInfos = [];
    for (const att of msg.attachments) {
      if (att.type === 'application/pdf' || att.filename.toLowerCase().endsWith('.pdf')) {
        attInfos.push(att);
      } else if (includeImages && (IMAGE_TYPES.has(att.type) || /\.(jpg|jpeg|png)$/i.test(att.filename))) {
        attInfos.push(att);
      }
    }
    for (let i = 0; i < attInfos.length; i++) {
      const att = attInfos[i];
      try {
        const raw = await getPartDataAsync(imap, msg.uid, att.partID);
        if (!raw || raw.length === 0) continue;
        let decoded;
        if (att.encoding === 'BASE64') {
          decoded = Buffer.from(raw.toString('utf8').replace(/\s/g, ''), 'base64');
        } else {
          decoded = raw;
        }
        const uidTag = msg.uid ? `${msg.uid}_` : '';
        const ext = att.type === 'application/pdf' ? '.pdf' : '.jpg';
        const safeName = `${datePrefix}_${uidTag}${subjectSlug}_${i + 1}${ext}`;
        const filePath = join(outputDir, safeName);
        createWriteStream(filePath).end(decoded);
        files.push(filePath);
      } catch (err) {
        results.push({ uid: msg.uid, subject: msg.subject, error: err.message, files: [] });
      }
    }
    if (files.length > 0) {
      results.push({ uid: msg.uid, subject: msg.subject, files });
    }
  }
  try {
    await addFlagsAsync(imap, uids, ['\\Seen']);
  } catch (_) {
  }
  await endAsync(imap);
  return results;
}
