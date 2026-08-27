// DEPRECATED — No active consumers as of 2026-07-11 audit (0 imports found).
// Zoho REST API auth is handled by zoho-auth.js (canonical + 18 consumers).
// This file was used for Browserless CDP browser-session persistence (cookies/localStorage).
// Keep for reference; remove in a future cleanup pass if still unreferenced.

// Zoho Session Manager — persistent session across Browserless CDP connections
// Saves ALL cookies (including httpOnly) + localStorage after login, then
// re-injects them on subsequent connections to avoid Zoho's daily sign-in limit.

import fs from 'fs';
import path from 'path';
import { chromium } from 'playwright';

const SESSION_TTL_MS = 2 * 60 * 60 * 1000;
const BLOCK_WARN_MS = 30 * 60 * 1000;

const HOME = process.env.HOME || process.env.USERPROFILE || '.';
const DEFAULT_STATE_FILE = path.join(HOME, '.zoho', '.browser-session.json');

let singleton = null;

export class ZohoSession {
  constructor(stateFile) {
    this.stateFile = stateFile || DEFAULT_STATE_FILE;
    this.browser = null;
    this.page = null;
    this.session = null;
  }

  static getInstance(stateFile) {
    if (!singleton) {
      singleton = new ZohoSession(stateFile);
    }
    return singleton;
  }

  static resetInstance() {
    if (singleton) {
      singleton.disconnect().catch(() => {});
      singleton = null;
    }
  }

  isConnected() {
    return this.browser !== null && this.page !== null;
  }

  load() {
    if (!fs.existsSync(this.stateFile)) return null;
    try {
      const raw = fs.readFileSync(this.stateFile, 'utf8');
      this.session = JSON.parse(raw);
      return this.session;
    } catch {
      return null;
    }
  }

  save(page) {
    return this._capture(page);
  }

  isSessionValid() {
    if (!this.session || !this.session.savedAt) return false;
    const age = Date.now() - this.session.savedAt;
    return age < SESSION_TTL_MS && this.session.cookies && this.session.cookies.length > 10;
  }

  sessionAge() {
    if (!this.session || !this.session.savedAt) return -1;
    return Date.now() - this.session.savedAt;
  }

  delete() {
    try { fs.unlinkSync(this.stateFile); } catch {}
    this.session = null;
  }

  async connect(wsUrl) {
    this.browser = await chromium.connectOverCDP(wsUrl);
    this.page = await this.browser.newPage({ viewport: { width: 1400, height: 900 } });

    if (this.isSessionValid()) {
      console.log(`[ZohoSession] Restoring session (${(this.sessionAge()/60000).toFixed(0)}min old, ${this.session.cookies.length} cookies)...`);
      await this.page.goto('https://books.zoho.com', { waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {});
      await new Promise(r => setTimeout(r, 3000));

      try {
        const cdp = await this.page.context().newCDPSession(this.page);
        await cdp.send('Network.setCookies', { cookies: this.session.cookies });
      } catch (e) {
        console.log(`  [WARN] CDP cookie injection failed: ${e.message}`);
      }

      if (this.session.localStorage) {
        try {
          await this.page.evaluate((s) => {
            const data = JSON.parse(s);
            for (const [k, v] of Object.entries(data)) localStorage.setItem(k, v);
          }, this.session.localStorage);
        } catch {}
      }

      const orgId = this.session.orgId || '925048093';
      await this.page.goto(`https://books.zoho.com/app/${orgId}`, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
      await new Promise(r => setTimeout(r, 5000));

      let url = '';
      try { url = this.page.url(); } catch (e) { url = ''; }
      if (!url) {
        console.log('  Could not determine page URL after session restore — assuming needs login');
      } else if (url.includes('block-sessions')) {
        console.log('  Session blocked — Zoho daily sign-in limit reached. Delete session file and wait 24h.');
        this.delete();
        await this.browser.close();
        return { browser: null, page: null, blocked: true };
      } else if (!url.includes('signin') && !url.includes('login')) {
        console.log(`  Session restored — ${url.substring(0, 80)}`);
        return { browser: this.browser, page: this.page, blocked: false };
      } else {
        console.log(`  Session expired — will re-login (${url.substring(0, 60)})`);
      }
    }

    return { browser: this.browser, page: this.page, blocked: false, needsLogin: true };
  }

  async login(page, email, password, orgId) {
    console.log('[ZohoSession] Logging in...');
    await page.goto('https://accounts.zoho.com/signin?servicename=ZohoBooks', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await new Promise(r => setTimeout(r, 2000));
    await page.fill('input#login_id', email);
    await page.keyboard.press('Enter');
    await new Promise(r => setTimeout(r, 4000));
    await page.fill('input#password', password);
    await page.keyboard.press('Enter');
    await new Promise(r => setTimeout(r, 8000));

    if (page.url().includes('block-sessions')) {
      console.log('  Zoho daily sign-in limit reached. Wait 24h.');
      return false;
    }
    if (page.url().includes('signin')) {
      console.log('  Login failed — still on signin page');
      return false;
    }

    await this._capture(page);
    this.session.orgId = orgId;
    fs.writeFileSync(this.stateFile, JSON.stringify(this.session, null, 2));
    console.log(`  Logged in, session saved (${this.session.cookies.length} cookies)`);
    return true;
  }

  async disconnect() {
    try {
      if (this.page) await this.page.close();
    } catch {}
    try {
      if (this.browser) await this.browser.close();
    } catch {}
    this.page = null;
    this.browser = null;
  }

  async _capture(page) {
    let cookies = [];
    let localStorage = '';
    let jsCookies = '';

    try {
      const cdp = await page.context().newCDPSession(page);
      const result = await cdp.send('Network.getAllCookies');
      cookies = result.cookies;
    } catch {
      jsCookies = await page.evaluate(() => document.cookie).catch(() => '');
    }

    try {
      localStorage = await page.evaluate(() => JSON.stringify(window.localStorage)).catch(() => '{}');
    } catch {
      localStorage = '{}';
    }

    this.session = {
      savedAt: Date.now(),
      cookies,
      localStorage,
      orgId: this.session?.orgId || '925048093'
    };
    return this.session;
  }
}
