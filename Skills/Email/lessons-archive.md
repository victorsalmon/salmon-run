---
name: email/lessons-archive
description: Archived Lessons Learned from Email skill suite development. This file preserves the full historical record; active skill files (_email.md, check-imap.md) keep only actionable reference material.
---

# Lessons Learned — Email Skill Suite (Archived)

This file captures all Lessons Learned, Root Cause Analyses, and Corrections from the Email skill suite. New lessons should be added to this archive and kept out of the active skill files to keep them lean.

---

## 2026-06-10 — IMAP Reliability & Container Integration

### IMAP Connection & 'end' Event Reliability

- **`imap.end()` + 'end' event**: The `Imap` instance's 'end' event does not reliably fire after `imap.end()` (LOGOUT). Never `await new Promise(resolve => { imap.once('end', resolve); imap.end(); })` — this hangs indefinitely. Just call `imap.end()` without awaiting the event.
- **`fetchMessagesAsync` hang**: The `imap.mjs` wrapper's `fetchMessagesAsync` hangs because the `imap.fetch()` 'end' event is unreliable. Workaround: use the `Imap` constructor directly with inline Promise wrappers for connect/openBox/search, bypassing `imap.mjs` entirely.
- **`checkMailbox` hangs on fetch**: `checkMailbox()` always calls `fetchMessagesAsync()` for messages with unseen UIDs. The `imap.fetch()` 'end' event can hang. For a simple count (dry-run), bypass `checkMailbox` and use `Imap.connect()` → `openBox()` → `search(['UNSEEN'])` → `imap.end()` directly.

### TLS / SSL Compatibility

- **`rejectUnauthorized` default**: `buildConnection()` in `imap.mjs` hardcodes `tlsOptions: { rejectUnauthorized: config.rejectUnauthorized !== false }`, defaulting to `true`. When integrating IMAP into new containers, always pass `rejectUnauthorized: false` in the config if the IMAP server uses a self-signed cert — otherwise the TLS handshake hangs.
- **Dovecot with node-imap v0.8.19**: The `node-imap` library v0.8.19 has compatibility issues with Dovecot IMAP when `rejectUnauthorized` is `true`. The TLS handshake completes but authentication hangs. Set `tlsOptions: { rejectUnauthorized: false }` explicitly.

### HTTP / Container Integration

- **HTTP endpoint IMAP integration**: When adding IMAP checking to an Express route, use inline Promise wrappers (`new Promise((resolve, reject) => { imap.once('ready', resolve); ... })`) rather than the reusable wrapper functions, because the 'end' event pattern hangs in the container context.
- **Docker secret bundle lifecycle**: Updating a secrets bundle for a running service: `docker service update --secret-rm <name> <service>` → `docker secret rm <name>` → `docker secret create <name> <file>` → `docker service update --secret-add <name> <service>`. The new secret is picked up on the next container restart.
- **Verify env vars in PID 1**: After entrypoint hydration, verify env vars are set on the server process: `cat /proc/1/environ | tr '\0' '\n' | grep <VAR>`. `docker exec` starts a clean shell without the entrypoint's exports.

---

## 2026-06-03 — Initial Development

### Filename & Message Handling

- **Filename collisions**: `downloadAttachments()` with same-subject messages creates identical filenames. Always verify the download count matches the message count. Fixed by embedding UID in output filenames.
- **Re-download seen messages**: `checkMailbox()` defaults to `['UNSEEN']`. Use `checkMailbox(config, mailbox, true)` for `['ALL']`, or `downloadUids()` by UID range. CLI: `--uid-range=2-25`.

### MIME Subject Encoding

- **MIME subject decode**: Subjects like `=?UTF-8?B?...?=` are not human-readable. The `mimeDecode()` function handles both Base64 (`B`) and Quoted-printable (`Q`) encodings. Available in both lib and CLI.

### Error Handling

- **Error transparency**: Silent `.catch()` on failures hides problems. Always log the actual error even if you handle it.

### Development Setup

- **Host-side dependency install**: Run `npm install --prefix Skills/Email/Scripts` once. Then the tools work on any host with Node.js.
