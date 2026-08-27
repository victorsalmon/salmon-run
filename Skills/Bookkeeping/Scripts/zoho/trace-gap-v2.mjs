import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");

async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: creds.refreshToken,
    grant_type: "refresh_token"
  });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const data = await resp.json();
  const token = data.access_token;

  const url = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=200&sort_column=date&sort_order=A";
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  const txns = result.banktransactions || [];

  const statements = [
    { date: "2025-04-11", balance: 5734.22, label: "Mar 13 – Apr 11" },
    { date: "2025-05-13", balance: 4807.32, label: "Apr 11 – May 13" },
    { date: "2025-06-13", balance: 3648.11, label: "May 13 – Jun 13" },
    { date: "2025-07-11", balance: 8482.44, label: "Jun 13 – Jul 11" },
    { date: "2025-08-13", balance: 5941.26, label: "Jul 11 – Aug 13" },
    { date: "2025-09-12", balance: 5374.15, label: "Aug 13 – Sep 12" },
    { date: "2025-10-10", balance: 5156.95, label: "Sep 12 – Oct 10" },
    { date: "2025-11-13", balance: 4416.33, label: "Oct 10 – Nov 13" },
    { date: "2025-12-12", balance: 4863.74, label: "Nov 13 – Dec 12" },
    { date: "2026-01-13", balance: 6072.59, label: "Dec 12 – Jan 13" },
    { date: "2026-02-13", balance: 4756.72, label: "Jan 13 – Feb 13" },
    { date: "2026-03-13", balance: 4535.77, label: "Feb 13 – Mar 13" },
    { date: "2026-04-13", balance: 4202.62, label: "Mar 13 – Apr 13" },
    { date: "2026-05-13", balance: 4146.16, label: "Apr 13 – May 13" }
  ];

  console.log("Stmt End    | Actual  | Zoho    |  Gap  | Delta  | Period");
  console.log("------------|---------|---------|-------|--------|-------------------");

  let prevGap = null;
  for (const stmt of statements) {
    let zohoBal = null;
    for (const t of txns) {
      if (t.date <= stmt.date && t.running_balance !== undefined) {
        zohoBal = t.running_balance;
      }
    }
    const gap = stmt.balance !== null && zohoBal !== null ? (stmt.balance - zohoBal) : null;
    const gapStr = gap !== null ? gap.toFixed(2) : "N/A";
    const deltaStr = (prevGap !== null && gap !== null) ? (gap - prevGap).toFixed(2) : "";
    const marker = gap !== null && Math.abs(gap) > 0.5 ? " ◄" : "";
    const aStr = stmt.balance.toFixed(2);
    const zStr = zohoBal !== null ? zohoBal.toFixed(2) : "N/A";
    console.log(`${stmt.date} | $${aStr.padStart(7)} | $${zStr.padStart(7)} | ${gapStr.padStart(5)} | ${deltaStr.padStart(6)}${marker} | ${stmt.label}`);
    if (gap !== null) prevGap = gap;
  }

  // For each period where the gap changed, find new transactions in that period
  console.log("\n=== Gap change analysis ===");
  const gapChanges = [
    { period: "Jun 13 – Jul 11", from: "2025-06-13", to: "2025-07-11", delta: 10, gapAfter: 2 },
    { period: "Sep 12 – Jan 13", from: "2025-09-12", to: "2026-01-13", delta: 20, gapAfter: 22 },
    { period: "Dec 12 – Jan 13", from: "2025-12-12", to: "2026-01-13", delta: null, gapAfter: 22 },
    { period: "Jan 13 – Feb 13", from: "2026-01-13", to: "2026-02-13", delta: 10, gapAfter: 32 },
    { period: "Mar 13 – Apr 13", from: "2026-03-13", to: "2026-04-13", delta: 12, gapAfter: 44 }
  ];

  for (const gc of gapChanges) {
    console.log(`\n--- ${gc.period} (gap change: ${gc.delta !== null ? "$" + gc.delta : "?"}) ---`);
    const periodTxns = txns.filter(t => t.date > gc.from && t.date <= gc.to);
    for (const t of periodTxns) {
      const amt = parseFloat(t.amount);
      const payee = t.payee || "(blank)";
      console.log(`  ${t.date} | ${t.debit_or_credit.padEnd(6)} | $${amt.toFixed(2).padStart(8)} | ${payee} | type=${t.transaction_type}`);
    }
  }

  // Check for $10, $12, $20 transactions
  console.log("\n=== Searching for transactions matching gap deltas ($10, $12, $20) ===");
  const targets = [10, 12, 20, 8, 22, 32, 44];
  for (const t of txns) {
    const amt = parseFloat(t.amount);
    for (const target of targets) {
      if (Math.abs(amt - target) < 1) {
        console.log(`  $${target} match: ${t.date} | $${amt} | ${t.debit_or_credit} | ${t.payee || "(blank)"} | type=${t.transaction_type}`);
      }
    }
  }
}
main().catch(e => console.error(e.message));
