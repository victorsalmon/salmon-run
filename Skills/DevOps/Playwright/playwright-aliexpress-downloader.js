// aliexpress-persistent-downloader.js
//
// AliExpress receipt downloader.
//
// KEY DIFFERENCE FROM AMAZON: AliExpress AGGREGATES charges. A single bank
// statement charge (e.g. $10.77 on Mar 10) may be the sum of multiple orders
// from that day ($1.89 + $3.99 + $4.89). Individual order totals rarely match
// the bank charge directly.
//
// Strategy:
//   1. Load ALL orders (click "View orders" repeatedly until exhausted)
//   2. Parse every order: {orderId, date, amount, store, product, status}
//   3. For each manifest charge, find orders within +/- 3 day window
//   4. Subset-sum: find which combination of order amounts = the charge amount
//   5. Inject CSS highlight on matched orders
//   6. Single full-page screenshot showing all matched orders highlighted
//   7. Single JSON sidecar combining charge + matched orders with prices
//
// Naming convention (all files sort together by date+amount):
//   {date} - {charge_amount} - AliExpress - {summary}.png   (group screenshot)
//   {date} - {charge_amount} - AliExpress - {summary}.json   (combined sidecar)
//
// Selectors discovered 2026-06-18.
//
// Usage:
//   node aliexpress-persistent-downloader.js [options]
//   node aliexpress-persistent-downloader.js --discover
//   node aliexpress-persistent-downloader.js --scrape-only
//
// Options:
//   --orders <path>   Path to charges JSON manifest
//   --timeout <sec>   Max wait for manual login (default: 600)
//   --discover        Dump page DOM for selector analysis and exit
//   --scrape-only     Scrape all orders to JSON and exit (no screenshots)
//
// Env:
//   OUTPUT_DIR  — output directory for screenshots + sidecars
//   DATA_DIR    — persistent Chrome profile directory
//   ORDERS_PATH — path to charges manifest

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { logNavigate, logError, initSession, closeSession } = require('../../lib/playwright-audit.js');
const { selectorRotError } = require('../../lib/selector-utils.js');
const { reauthenticate } = require('../../lib/re-auth.js');

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---- SELECTORS (discovered 2026-06-18) ----

const SELECTORS = {
  ordersUrl: 'https://www.aliexpress.com/p/order/index.html',
  ordersUrlSpm: 'https://www.aliexpress.com/p/order/index.html?spm=a2g0o.home.headerAcount.2.650c6278FeUABP',
  orderContainer: 'div.order-item',
  detailLink: 'a[href*="/p/order/detail.html?orderId="]',
  storeLink: 'a[href*="/store/"]',
  productLink: 'a[href*="/item/"]',
  orderIdRx: /orderId=(\d+)/,
  loadMoreBtn: 'button.comet-btn-borderless',
  popupCloseSelector: 'img.pop-close-btn, .pop-close-btn, [class*="pop-close"], [class*="close-btn"], button[class*="close"]',
};

const TARGET_CHARGE_WINDOW_DAYS = 3;
const LOAD_MORE_MAX_CLICKS = 50;
const CSS_HIGHLIGHT_ID = 'ae-matched-highlight';

const DEFAULT_CHARGES = process.env.ORDERS_PATH || path.resolve(__dirname, './aliexpress-orders-to-retrieve.json');
const DEFAULT_OUT = process.env.OUTPUT_DIR || path.resolve(__dirname, '../../../../../intersite-docs/Taxes and Bookkeeping/intersite-consulting/2026 Receipts/aliexpress-ingest');
const DATA_DIR = process.env.DATA_DIR || path.resolve(__dirname, './Profile');
const LOGIN_TIMEOUT_SEC = parseInt(process.env.LOGIN_TIMEOUT || '600', 10);
const REAUTH_SCRIPT = path.resolve(__dirname, './aliexpress-reauth.js');
const REAUTH_DIR = __dirname;

if (!fs.existsSync(DEFAULT_OUT)) fs.mkdirSync(DEFAULT_OUT, { recursive: true });
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

// ---- HELPERS ----

function parsePrice(text) {
  const m = text.match(/[\d,.]+/);
  return m ? parseFloat(m[0].replace(/,/g, '')) : null;
}

function parseDate(text) {
  const months = { jan:1,january:1, feb:2,february:2, mar:3,march:3, apr:4,april:4, may:5, jun:6,june:6,
    jul:7,july:7, aug:8,august:8, sep:9,september:9, oct:10,october:10, nov:11,november:11, dec:12,december:12 };
  // Try "Mon DD, YYYY" first
  let m = text.match(/(\w+)\s+(\d{1,2}),?\s*(\d{4})/);
  if (m) {
    const mn = months[m[1].toLowerCase().substring(0, 3)];
    if (mn) return new Date(parseInt(m[3]), mn - 1, parseInt(m[2]));
  }
  // Try "M/D/YYYY" or "M/D/YY"
  m = text.match(/(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m) return new Date(parseInt(m[3]), parseInt(m[1]) - 1, parseInt(m[2]));
  return null;
}

function formatDateISO(dateStr) {
  const p = dateStr.split('/');
  return p.length === 3 ? `${p[2]}-${p[0].padStart(2,'0')}-${p[1].padStart(2,'0')}` : dateStr;
}

function dateDiffDays(d1, d2) {
  return Math.abs((d1.getTime() - d2.getTime()) / 86400000);
}

function round2(n) { return Math.round(n * 100) / 100; }

function findSubsetSum(amounts, target, tolerance = 0.02) {
  for (let mask = 1; mask < (1 << amounts.length); mask++) {
    let sum = 0;
    for (let i = 0; i < amounts.length; i++) {
      if (mask & (1 << i)) sum += amounts[i];
    }
    if (Math.abs(sum - target) <= tolerance) {
      const indices = [];
      for (let i = 0; i < amounts.length; i++) {
        if (mask & (1 << i)) indices.push(i);
      }
      return indices;
    }
  }
  return null;
}

// ---- ARGS ----

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { chargesFile: DEFAULT_CHARGES, discover: false, scrapeOnly: false };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--orders') { opts.chargesFile = path.resolve(args[++i]); continue; }
    if (args[i] === '--timeout') { opts.loginTimeout = parseInt(args[++i], 10); continue; }
    if (args[i] === '--discover') { opts.discover = true; continue; }
    if (args[i] === '--scrape-only') { opts.scrapeOnly = true; continue; }
    if (args[i].startsWith('--')) { console.error('Unknown option:', args[i]); process.exit(1); }
  }
  return opts;
}

// ---- DISCOVERY MODE ----

const DOM_DUMP_PATH = process.env.DOM_DUMP_DIR ? path.resolve(process.env.DOM_DUMP_DIR, `aliexpress-discover-${Date.now()}.json`) : null;

async function runDiscovery(page) {
  console.log('\n=== DISCOVERY MODE ===\n');
  await sleep(3000);
  console.log(`URL: ${page.url()}`);
  console.log(`Title: ${await page.title().catch(() => '?')}\n`);

  // Dump body text to understand what we're seeing
  const bodyText = await page.evaluate(() => document.body.innerText.substring(0, 2000));
  console.log(`Page text:\n${bodyText.substring(0, 1000)}\n`);

  // Check all possible order item selectors
  const candidates = ['div.order-item', 'a.order-item.order-item-mobile', 'a[href*="/p/order/detail.html?orderId="]', '[class*="order-item"]'];
  for (const sel of candidates) {
    const count = await page.evaluate((s) => document.querySelectorAll(s).length, sel);
    console.log(`  "${sel}": ${count}`);
  }

  // Dump the button state
  const btnInfo = await page.evaluate(() => {
    const btns = document.querySelectorAll('button');
    return Array.from(btns).map(b => ({
      class: b.className.substring(0, 80),
      text: (b.textContent||'').trim().substring(0, 60),
      visible: b.offsetParent !== null,
      rect: b.getBoundingClientRect ? JSON.stringify({ top: b.getBoundingClientRect().top, bottom: b.getBoundingClientRect().bottom }) : '',
    })).filter(b => b.text || b.class.includes('borderless'));
  });
  console.log(`\nButtons on page:`);
  btnInfo.forEach((b,i) => console.log(`  [${i}] "${b.text}" visible=${b.visible} rect=${b.rect} class="${b.class}"`));

  // Dump all <a> tags
  const links = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('a')).map(el => ({
      href: (el.getAttribute('href') || '').substring(0, 120),
      text: (el.textContent || '').trim().substring(0, 60),
      class: (el.className || '').substring(0, 60),
    })).filter(l => l.text || l.href).slice(0, 30);
  });
  console.log(`\nLinks (${links.length} shown):`);
  links.forEach((l,i) => console.log(`  [${i}] "${l.text}" → ${l.href}  class="${l.class}"`));

  console.log('\n--- Discovery complete ---');
  console.log('Update SELECTORS in aliexpress-persistent-downloader.js if needed.\n');

  if (DOM_DUMP_PATH) {
    const dump = { url: page.url(), title: await page.title().catch(() => '?'), bodyText: bodyText.substring(0, 1000), candidates, btnInfo, links, capturedAt: new Date().toISOString() };
    fs.writeFileSync(DOM_DUMP_PATH, JSON.stringify(dump, null, 2), 'utf8');
    console.log(`DOM dump written to: ${DOM_DUMP_PATH}`);
  }
}

// ---- LOGIN ----

async function waitForLogin(page, timeoutSec) {
  console.log('\nSign in to AliExpress in the Chrome window.');
  console.log(`Timeout: ${timeoutSec}s\n`);
  const start = Date.now();
  let waited = 0;
  while ((Date.now() - start) < timeoutSec * 1000) {
    await sleep(5000);
    waited += 5;
    try {
      const url = (page.url() || '').toLowerCase();
      const txt = await page.evaluate(() => document.body.innerText.substring(0,1000)).catch(() => '');
      const lower = txt.toLowerCase();
      if (!url.includes('login') && !url.includes('passport') && !url.includes('signin') &&
          (url.includes('order') || lower.includes('my orders') || lower.includes('order item'))) {
        console.log(`  Login detected after ~${waited}s.`);
        return true;
      }
      if (waited % 30 === 0) console.log(`  Still waiting... (${waited}s)`);
    } catch {}
  }
  console.log(`Timed out after ${timeoutSec}s.`);
  return false;
}

// ---- DISMISS POPUPS ----

async function dismissPopups(page) {
  const closed = await page.evaluate((sel) => {
    const imgs = document.querySelectorAll(sel);
    let count = 0;
    imgs.forEach(el => { if (el.offsetParent !== null) { el.click(); count++; } });
    return count;
  }, SELECTORS.popupCloseSelector);
  if (closed > 0) {
    console.log(`  Dismissed ${closed} popup(s)`);
    await sleep(2000);
  }
  return closed;
}

// ---- LOAD ALL ORDERS ----

async function getOldestChargeDate(charges) {
  let oldest = null;
  for (const c of charges) {
    const d = parseDate(c.date) || parseDate(formatDateISO(c.date));
    if (d && (!oldest || d < oldest)) oldest = d;
  }
  return oldest;
}

async function getOrderContainerCount(page) {
  return await page.evaluate((sel) => document.querySelectorAll(sel).length, SELECTORS.orderContainer);
}

async function getLastOrderDate(page) {
  return await page.evaluate(() => {
    const containers = document.querySelectorAll('div.order-item');
    if (!containers.length) return null;
    const last = containers[containers.length - 1];
    const text = last.textContent || '';
    const m = text.match(/Date:\s*(.+?)(?:\n|$)/);
    return m ? m[1].trim() : null;
  });
}

async function getFirstOrderDate(page) {
  return await page.evaluate(() => {
    const first = document.querySelector('div.order-item');
    if (!first) return null;
    const text = first.textContent || '';
    const m = text.match(/Date:\s*(.+?)(?:\n|$)/);
    return m ? m[1].trim() : null;
  });
}

async function loadAllOrders(page, charges) {
  let total = await getOrderContainerCount(page);
  console.log(`  Initial orders visible: ${total}`);

  if (total === 0) {
    // Try clicking "View orders" once — orders may be collapsed
    const btnClicked = await page.evaluate(() => {
      const btn = document.querySelector('button.comet-btn-borderless');
      if (btn && (btn.textContent||'').trim().toLowerCase().includes('view orders') && btn.offsetParent !== null) {
        btn.scrollIntoView({ block: 'center' });
        setTimeout(() => btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })), 200);
        return true;
      }
      return false;
    });
    if (btnClicked) {
      await sleep(5000);
      total = await getOrderContainerCount(page);
      console.log(`  After initial click: ${total} orders`);
    }
  }

  if (total === 0) return 0;

  const oldestTarget = await getOldestChargeDate(charges);
  if (oldestTarget) console.log(`  Oldest target charge: ${oldestTarget.toISOString().substring(0,10)}`);

  // Show date range of currently visible orders
  const firstDate = await getFirstOrderDate(page);
  const lastDate = await getLastOrderDate(page);
  console.log(`  Visible date range: ${firstDate || '?'} → ${lastDate || '?'}`);

  // Date-based pagination
  for (let i = 0; i < LOAD_MORE_MAX_CLICKS; i++) {
    if (oldestTarget) {
      const ldr = await getLastOrderDate(page);
      if (ldr) {
        const ld = parseDate(ldr);
        if (ld && ld < oldestTarget) {
          console.log(`  Last order (${ldr}) is past oldest target — stopping`);
          break;
        }
      }
    }

    const btnInfo = await page.evaluate(() => {
      const btn = document.querySelector('button.comet-btn-borderless');
      if (!btn) return { exists: false };
      return {
        exists: true,
        text: (btn.textContent || '').trim().substring(0, 30),
        visible: btn.offsetParent !== null,
      };
    });

    if (!btnInfo.exists || !btnInfo.visible || !btnInfo.text.toLowerCase().includes('view orders')) break;

    await page.evaluate(() => {
      const btn = document.querySelector('button.comet-btn-borderless');
      if (btn) {
        btn.scrollIntoView({ block: 'center' });
        setTimeout(() => btn.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })), 300);
      }
    });
    await sleep(6000);

    const newTotal = await getOrderContainerCount(page);
    if (newTotal === total) {
      await sleep(5000);
      const retryTotal = await getOrderContainerCount(page);
      if (retryTotal === total) break;
      total = retryTotal;
    } else {
      total = newTotal;
    }
    const ld = await getLastOrderDate(page);
    console.log(`  Click ${i+1}: ${total} orders, last date: ${ld || '?'}`);
  }

  console.log(`  Total orders: ${total}`);
  return total;
}

// ---- SCRAPE ALL ORDERS ----

async function scrapeAllOrders(page) {
  return await page.evaluate(() => {
    const containers = document.querySelectorAll('div.order-item');
    return Array.from(containers).map(el => {
      const text = el.textContent || '';

      // Extract orderId from the "Details" link
      const detailLink = el.querySelector('a[href*="/p/order/detail.html?orderId="]');
      const href = detailLink ? (detailLink.getAttribute('href') || '') : '';
      const m = href.match(/orderId=(\d+)/);
      const orderId = m ? m[1] : '';

      // Extract date — format "Date: Jun 13, 2026"
      const dateM = text.match(/Date:\s*(.+?)(?:\n|$)/);
      const dateRaw = dateM ? dateM[1].trim() : '';

      // Extract total — format "Total:C$30.66" or "Total:C$ 1.89"
      const totalM = text.match(/Total:\s*C?\$?\s*([\d,.]+)/);
      const total = totalM ? totalM[1].trim() : '';

      // Extract store name
      const storeLink = el.querySelector('a[href*="/store/"]');
      const store = storeLink ? (storeLink.textContent || '').trim() : '';

      // Extract product name — find the product link WITH text (not the image link)
      const productLinks = el.querySelectorAll('a[href*="/item/"]');
      let product = '';
      for (const pl of productLinks) {
        const txt = (pl.textContent || '').trim();
        if (txt.length > 3) { product = txt; break; }
      }

      // Extract status — usually the first status-like text
      const statusM = text.match(/^(.+?)(?:\n|$)/);
      const status = (statusM && ['Awaiting delivery', 'Completed', 'Processing', 'To pay', 'Shipped', 'Cancelled'].some(s => statusM[1].includes(s)))
        ? statusM[1].trim() : '';

      return { orderId, dateRaw, priceText: total, store, product, status: status || '', href };
    });
  }).then(rows => rows.map(o => {
    const parsed = parseDate(o.dateRaw);
    return {
      ...o,
      date: parsed,
      dateISO: parsed ? `${parsed.getFullYear()}-${String(parsed.getMonth()+1).padStart(2,'0')}-${String(parsed.getDate()).padStart(2,'0')}` : '',
      price: parsePrice(o.priceText),
    };
  }));
}

// ---- MATCH CHARGE TO ORDERS ----

function matchCharge(charge, scrapedOrders) {
  const chargeDate = parseDate(charge.date) || parseDate(formatDateISO(charge.date));
  if (!chargeDate) return null;
  const target = parseFloat(charge.amount);
  const candidates = scrapedOrders.filter(o => o.date && dateDiffDays(o.date, chargeDate) <= TARGET_CHARGE_WINDOW_DAYS);
  if (!candidates.length) return null;
  const match = findSubsetSum(candidates.map(o => o.price), target);
  return match ? match.map(i => candidates[i]) : null;
}

// ---- INJECT HIGHLIGHT + SCREENSHOT ----

async function injectHighlight(page, matchedOrders) {
  await page.evaluate((id) => {
    const el = document.getElementById(id);
    if (el) el.remove();
  }, CSS_HIGHLIGHT_ID);

  // Highlight the container div.order-item that holds a detail link with the matched orderId
  let css = `<style id="${CSS_HIGHLIGHT_ID}">\n`;
  for (const mo of matchedOrders) {
    css += `div.order-item:has(a[href*="${mo.orderId}"]) {
  outline: 3px solid #ff0000 !important;
  outline-offset: -3px !important;
  background-color: #ffffcc !important;
  border-radius: 4px !important;
  box-shadow: 0 0 8px rgba(255,0,0,0.5) !important;
}\n`;
  }
  css += '</style>';

  await page.evaluate((html) => {
    document.head.insertAdjacentHTML('beforeend', html);
  }, css);

  await sleep(500);

  if (matchedOrders.length > 0) {
    await page.evaluate((orderId) => {
      const el = document.querySelector(`a[href*="${orderId}"]`);
      if (el) el.scrollIntoView({ block: 'center', behavior: 'instant' });
    }, matchedOrders[0].orderId);
    await sleep(1000);
  }
}

async function clearHighlight(page) {
  await page.evaluate((id) => {
    const el = document.getElementById(id);
    if (el) el.remove();
  }, CSS_HIGHLIGHT_ID);
}

// ---- TAKE GROUP SCREENSHOT + SIDECAR ----

async function captureCharge(page, charge, matchedOrders, outDir) {
  const dt = formatDateISO(charge.date);
  const am = parseFloat(charge.amount).toFixed(2);
  const summary = (charge.summary || charge.description || 'AliExpress Charge').replace(/[^\w\s-]/g, '').trim().substring(0, 40);
  const baseFn = `${dt} - ${am} - AliExpress - ${summary}`;

  // Inject CSS highlight on matched orders
  await injectHighlight(page, matchedOrders);

  // Full-page screenshot — all matched orders highlighted
  const pngPath = path.join(outDir, `${baseFn}.png`);
  await page.screenshot({ path: pngPath, fullPage: true });

  // Validate output
  try {
    const stat = fs.statSync(pngPath);
    if (stat.size === 0) {
      console.log(`  WARNING: ${path.basename(pngPath)} is empty (0 bytes)`);
    } else {
      console.log(`  Screenshot: ${path.basename(pngPath)} (${(stat.size / 1024).toFixed(1)} KB)`);
    }
  } catch (err) {
    console.log(`  WARNING: ${path.basename(pngPath)} — file not found: ${err.message}`);
  }

  // Clear highlight for next charge
  await clearHighlight(page);

  // Combined JSON sidecar: charge info + all matched orders
  const sidecar = {
    charge: {
      charge_id: charge.charge_id,
      date: charge.date,
      amount: charge.amount,
      description: charge.description,
      seller: charge.seller || 'AliExpress',
      summary: charge.summary || '',
      account: charge.account || '',
    },
    matched_orders: matchedOrders.map(o => ({
      orderId: o.orderId,
      date: o.dateISO,
      dateRaw: o.dateRaw,
      price: round2(o.price),
      product: o.product,
      store: o.store,
      status: o.status,
      sku: o.sku || '',
      qty: o.qty || '',
      href: o.href,
      orderUrl: o.href.startsWith('http') ? o.href : `https://www.aliexpress.com${o.href.startsWith('/') ? '' : '/'}${o.href}`,
    })),
    total_matched: round2(matchedOrders.reduce((s, o) => s + o.price, 0)),
    charge_amount: charge.amount,
    match_tolerance: 0.02,
    window_days: TARGET_CHARGE_WINDOW_DAYS,
    captured_at: new Date().toISOString(),
  };

  const jsonPath = path.join(outDir, `${baseFn}.json`);
  fs.writeFileSync(jsonPath, JSON.stringify(sidecar, null, 2), 'utf8');
  console.log(`  Sidecar:   ${path.basename(jsonPath)}`);

  return baseFn;
}

// ---- MAIN ----

async function main() {
  const opts = parseArgs();
  initSession('web', 'aliexpress-downloader');

  const raw = JSON.parse(fs.readFileSync(opts.chargesFile, 'utf8'));
  const charges = (raw.aliexpress_charges || []).filter(c => c.charge_id);
  charges.sort((a, b) => {
    const da = a.date.split('/'), db = b.date.split('/');
    return new Date(db[2], db[0]-1, db[1]) - new Date(da[2], da[0]-1, da[1]);
  });
  console.log(`\n${charges.length} AliExpress charges (newest -> oldest)\n`);

  let browser = await chromium.launchPersistentContext(DATA_DIR, {
    headless: false,
    args: ['--disable-blink-features=AutomationControlled']
  });
  let pages = browser.pages();
  let page = pages.length > 0 ? pages[0] : await browser.newPage();

  // Navigate — try both URLs
  console.log('Opening AliExpress order list...');
  for (const orderUrl of [SELECTORS.ordersUrl, SELECTORS.ordersUrlSpm]) {
    try { await logNavigate(page, orderUrl, { domain:'web', subdomain:'aliexpress', session:'aliexpress-downloader' }); break; }
    catch { await page.goto(orderUrl, { timeout:30000, waitUntil:'domcontentloaded' }).catch(() => {}); await sleep(3000); }
  }
  await sleep(5000);

  // Dismiss any popups that may be blocking
  await dismissPopups(page);

  // Login check
  const url = (page.url() || '').toLowerCase();
  if (url.includes('login') || url.includes('passport') || url.includes('signin')) {
    console.log('\n=== SIGN-IN REQUIRED ===');
    if (!await waitForLogin(page, LOGIN_TIMEOUT_SEC)) {
      console.log('Login not completed. Exiting.');
      await browser.close().catch(() => {});
      closeSession('aliexpress-downloader');
      process.exit(1);
    }
    // Dismiss popups again after login
    await sleep(3000);
    await dismissPopups(page);
  }
  console.log('Logged in.\n');

  // Discovery mode
  if (opts.discover) {
    await dismissPopups(page);
    await loadAllOrders(page, charges);
    await runDiscovery(page);
    await browser.close().catch(() => {});
    closeSession('aliexpress-downloader');
    process.exit(0);
  }

  // Dismiss popups before loading orders
  await dismissPopups(page);

  // Load + scrape — pass charges for date-based pagination
  const total = await loadAllOrders(page, charges);
  if (total === 0) {
    console.log('No orders found.');
    await browser.close().catch(() => {});
    closeSession('aliexpress-downloader');
    process.exit(1);
  }

  console.log('\nScraping order data...');
  let scrapedOrders = await scrapeAllOrders(page);
  console.log(`Scraped ${scrapedOrders.length} orders`);

  // Scrape-only
  if (opts.scrapeOnly) {
    const jsonPath = path.join(DEFAULT_OUT, `aliexpress-scraped-orders-${Date.now()}.json`);
    fs.writeFileSync(jsonPath, JSON.stringify(scrapedOrders, null, 2), 'utf8');
    console.log(`Saved: ${jsonPath}`);
    await browser.close().catch(() => {});
    closeSession('aliexpress-downloader');
    process.exit(0);
  }

  // Date range
  const valid = scrapedOrders.filter(o => o.date);
  if (valid.length) {
    const ds = valid.map(o => o.date.getTime()).sort((a,b) => a - b);
    console.log(`  Date range: ${new Date(ds[0]).toISOString().substring(0,10)} → ${new Date(ds[ds.length-1]).toISOString().substring(0,10)}\n`);
  }

  // Checkpoint
  const CHECKPOINT = path.join(DEFAULT_OUT, 'download-checkpoint.json');
  let completed = new Set();
  if (fs.existsSync(CHECKPOINT)) {
    try { const cp = JSON.parse(fs.readFileSync(CHECKPOINT,'utf8')); completed = new Set(cp.completed || []); console.log(`Resuming — ${completed.size} already done\n`); }
    catch(e) {}
  }

  const startTime = Date.now();
  let matchCount = 0, unmatchCount = 0;

  for (const c of charges) {
    if (completed.has(c.charge_id)) {
      console.log(`[${completed.size}/${charges.length}] ${c.charge_id} — skip (checkpoint)`);
      continue;
    }
    console.log(`\n--- ${c.description || c.charge_id} (${c.date} $${parseFloat(c.amount).toFixed(2)}) ---`);

    // Session health check
    const sessionLost = await page.evaluate(() => {
      const url = window.location.href.toLowerCase();
      return url.includes('login') || url.includes('passport') || url.includes('signin');
    }).catch(() => false);

    if (sessionLost) {
      console.log('Session lost — triggering re-auth.');
      await browser.close().catch(() => {});
      const ok = reauthenticate(REAUTH_SCRIPT, REAUTH_DIR, 600);
      if (!ok) {
        console.log('Re-auth failed. Aborting.');
        break;
      }
      browser = await chromium.launchPersistentContext(DATA_DIR, {
        headless: false,
        args: ['--disable-blink-features=AutomationControlled']
      });
      pages = browser.pages();
      page = pages.length > 0 ? pages[0] : await browser.newPage();
      for (const orderUrl of [SELECTORS.ordersUrl, SELECTORS.ordersUrlSpm]) {
        await page.goto(orderUrl, { timeout: 30000, waitUntil: 'domcontentloaded' }).catch(() => {});
        await sleep(3000);
      }
      await sleep(5000);
      await dismissPopups(page);
      const total = await loadAllOrders(page, charges);
      if (total === 0) {
        console.log('No orders found after re-auth.');
        break;
      }
      scrapedOrders = await scrapeAllOrders(page);
      console.log(`Re-scraped ${scrapedOrders.length} orders after re-auth`);
      continue;
    }

    const matched = matchCharge(c, scrapedOrders);
    if (!matched) {
      console.log(`  No match within +/-${TARGET_CHARGE_WINDOW_DAYS} days`);
      unmatchCount++;
      continue;
    }

    matchCount++;
    const sum = round2(matched.reduce((s, o) => s + o.price, 0));
    console.log(`  Match: ${matched.length} orders = $${sum}:`);
    for (const o of matched) {
      console.log(`    ${o.dateISO}  $${o.price.toFixed(2)}  ${o.product.substring(0,60)}`);
    }

    await captureCharge(page, c, matched, DEFAULT_OUT);

    completed.add(c.charge_id);
    fs.writeFileSync(CHECKPOINT, JSON.stringify({ completed:[...completed], updated:new Date().toISOString() }, null, 2));

    const elapsed = Math.round((Date.now() - startTime) / 1000);
    console.log(`  ${completed.size}/${charges.length} — ${elapsed}s`);
  }

  console.log(`\nDone! ${matchCount} matched, ${unmatchCount} unmatched (${completed.size}/${charges.length} total).`);
  if (completed.size === charges.length && fs.existsSync(CHECKPOINT)) fs.unlinkSync(CHECKPOINT);

  await sleep(2000);
  await browser.close().catch(() => {});
  closeSession('aliexpress-downloader');
}

main().catch(e => {
  const msg = e.message || String(e);
  if (msg.includes('selector') || msg.includes('locator') || msg.includes('waitFor') || msg.includes('Timeout')) {
    console.error(selectorRotError('main-flow — likely selector rot'));
  }
  logError(null, 'aliexpress-downloader', e, 'main-flow').catch(() => {});
  console.error(e.message);
  process.exit(1);
});
