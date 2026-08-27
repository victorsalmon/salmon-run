const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Project-aware volume name: <PROJECT>_zoho_token_cache. FRAD is only a
// documented fallback default; INSTALL_PROJECT overrides it so a different
// project code never reuses another project's cached token.
const PROJECT_CODE = process.env.INSTALL_PROJECT || 'FRAD';
const VOLUME_NAME = `${PROJECT_CODE}_zoho_token_cache`;
const TOKEN_FILE = '.zoho-token.json';
const HELPER_IMAGE = 'alpine:latest';

function volumeExists() {
  try {
    execSync(`docker volume inspect ${VOLUME_NAME}`, { encoding: 'utf8', timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

function ensureVolume() {
  // Idempotent, race-safe: inspect-then-create, tolerating a concurrent
  // create ("already exists") instead of a check-then-create split.
  if (volumeExists()) return;
  try {
    execSync(
      `docker volume create --label com.interclaw.stack=${PROJECT_CODE} --label com.interclaw.volume-type=cache ${VOLUME_NAME}`,
      { timeout: 10000 }
    );
    console.error(`[zoho-token-cache] Created volume: ${VOLUME_NAME}`);
  } catch {
    // Another process may have won the create race; verify before proceeding.
    if (!volumeExists()) throw new Error(`Failed to create volume ${VOLUME_NAME}`);
  }
}

function read() {
  try {
    ensureVolume();
    const output = execSync(
      `docker run --rm -v ${VOLUME_NAME}:/cache ${HELPER_IMAGE} cat /cache/${TOKEN_FILE} 2>nul`,
      { encoding: 'utf8', timeout: 15000 }
    );
    if (!output.trim()) return null;
    return JSON.parse(output);
  } catch {
    return null;
  }
}

function write(token, expiresAt) {
  try {
    ensureVolume();
    const json = JSON.stringify({ token, expiresAt });
    // Unique per-process temp name, then an atomic rename inside the volume:
    // concurrent writers cannot interleave onto the canonical file, and a
    // reader never observes a half-written token (last-writer-wins).
    const suffix = `${process.pid}-${Date.now()}`;
    const tmpLocal = path.join(os.tmpdir(), `zoho-token-write-${suffix}.json`);
    const tmpRemote = `${TOKEN_FILE}.tmp.${suffix}`;
    fs.writeFileSync(tmpLocal, json, 'utf8');
    const cid = execSync(
      `docker create -v ${VOLUME_NAME}:/cache ${HELPER_IMAGE} 2>nul`,
      { encoding: 'utf8', timeout: 10000 }
    ).trim();
    execSync(`docker cp "${tmpLocal}" ${cid}:/cache/${tmpRemote}`, { timeout: 10000 });
    execSync(
      `docker run --rm -v ${VOLUME_NAME}:/cache ${HELPER_IMAGE} mv -f /cache/${tmpRemote} /cache/${TOKEN_FILE}`,
      { timeout: 10000 }
    );
    execSync(`docker rm -f ${cid} >nul 2>nul`, { timeout: 10000 });
    fs.unlinkSync(tmpLocal);
    return true;
  } catch {
    return false;
  }
}

function clear() {
  try {
    ensureVolume();
    execSync(
      `docker run --rm -v ${VOLUME_NAME}:/cache ${HELPER_IMAGE} rm -f /cache/${TOKEN_FILE}`,
      { timeout: 15000 }
    );
  } catch (err) {
    console.error(`[zoho-token-cache] Failed to clear token: ${err.message}`);
  }
}

module.exports = { read, write, clear, VOLUME_NAME };
