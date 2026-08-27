import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;

  const mcId = "93310000000100013";
  const allTxns = [];
  let page = 1, hasMore = true;
  while (hasMore && page < 10) {
    const data = await (await fetch(`https://www.zohoapis.com/books/v3/banktransactions?account_id=${mcId}&organization_id=925048093&per_page=200&page=${page}&sort_column=date&sort_order=A`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
    allTxns.push(...(data.banktransactions || []));
    hasMore = data.page_context?.has_more_page || false;
    page++;
  }

  // Statement ending balances from reconciliation-periods.md
  const stmts = [
    { date: "2025-05-09", bal: 64.56, label: "May 9, 2025" },
    { date: "2025-06-09", bal: 798.05, label: "Jun 9, 2025" },
    { date: "2025-07-09", bal: 79.17, label: "Jul 9, 2025" },
    { date: "2025-08-11", bal: 1165.17, label: "Aug 11, 2025" },
    { date: "2025-09-09", bal: 144.93, label: "Sep 9, 2025" },
    { date: "2025-10-09", bal: 360.73, label: "Oct 9, 2025" },
    { date: "2025-11-10", bal: 158.75, label: "Nov 10, 2025" },
    { date: "2025-12-09", bal: 85.41, label: "Dec 9, 2025" },
    { date: "2026-01-09", bal: 373.45, label: "Jan 9, 2026" },
    { date: "2026-02-09", bal: 1814.09, label: "Feb 9, 2026" },
    { date: "2026-03-09", bal: 26.66, label: "Mar 9, 2026" },
    { date: "2026-04-09", bal: 21.30, label: "Apr 9, 2026" },
    { date: "2026-05-11", bal: 194.36, label: "May 11, 2026" }
  ];

  console.log("MC 6258 — Zoho vs Statement at each period end:\n");
  console.log("Date       | Stmt Bal | Zoho Bal |   Gap | Period");
  console.log("-----------|----------|----------|-------|-------------------");
  
  for (const s of stmts) {
    let z = null;
    for (const t of allTxns) { if (t.date <= s.date && t.running_balance !== undefined) z = t.running_balance; }
    const gap = z !== null ? (s.bal - z) : null;
    const gapStr = gap !== null ? (gap > 0 ? `+${gap.toFixed(2)}` : gap.toFixed(2)) : "N/A";
    const zStr = z !== null ? z.toFixed(2) : "N/A";
    console.log(`${s.date} | $${s.bal.toString().padStart(7)} | $${zStr.padStart(7)} | ${gapStr.padStart(6)} | ${s.label}`);
  }

  // Current state
  console.log("\nCurrent:");
  const last = allTxns[allTxns.length - 1];
  console.log(`  Last transaction: ${last.date} | running=$${last.running_balance}`);
  console.log(`  Bank balance (per Zoho field): $208.22`);
  console.log(`  Gap to bank: ${(208.22 - last.running_balance).toFixed(2)}`);
}
main().catch(e => console.error(e.message));
