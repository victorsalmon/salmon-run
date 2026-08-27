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

  // Statement end dates and their actual bank balances from reconciliation-periods.md
  const statements = [
    { date: "2025-04-11", balance: 5734.22, label: "Mar 13 – Apr 11, 2025" },
    { date: "2025-05-13", balance: 4807.32, label: "Apr 11 – May 13, 2025" },
    { date: "2025-06-13", balance: 3648.11, label: "May 13 – Jun 13, 2025" },
    { date: "2025-07-11", balance: 8482.44, label: "Jun 13 – Jul 11, 2025" },
    { date: "2025-08-13", balance: 5941.26, label: "Jul 11 – Aug 13, 2025" },
    { date: "2025-09-12", balance: 5374.15, label: "Aug 13 – Sep 12, 2025" },
    { date: "2025-10-10", balance: null, label: "Sep 12 – Oct 10, 2025 (need from file)" },
    { date: "2025-11-13", balance: null, label: "Oct 10 – Nov 13, 2025 (need from file)" },
    { date: "2025-12-12", balance: null, label: "Nov 13 – Dec 12, 2025 (need from file)" },
    { date: "2026-01-13", balance: 6072.59, label: "Dec 12 – Jan 13, 2026" },
    { date: "2026-02-13", balance: 4756.72, label: "Jan 13 – Feb 13, 2026" },
    { date: "2026-03-13", balance: 4535.77, label: "Feb 13 – Mar 13, 2026" },
    { date: "2026-04-13", balance: 4202.62, label: "Mar 13 – Apr 13, 2026" },
    { date: "2026-05-13", balance: 4146.16, label: "Apr 13 – May 13, 2026" }
  ];

  console.log("=== Zoho running balance vs actual bank statement at each period end ===\n");
  console.log("Stmt End    | Actual Bank | Zoho Bal |  Gap  | Period");
  console.log("------------|-------------|----------|-------|----------------------------");

  let prevGap = null;
  for (const stmt of statements) {
    // Find the last transaction on or before this statement date
    let zohoBal = null;
    for (const t of txns) {
      if (t.date <= stmt.date && t.running_balance !== undefined) {
        zohoBal = t.running_balance;
      }
    }
    const gap = stmt.balance !== null && zohoBal !== null ? (stmt.balance - zohoBal).toFixed(2) : "N/A";
    const gapChange = (prevGap !== null && gap !== "N/A") ? (parseFloat(gap) - prevGap).toFixed(2) : "";
    const marker = gap !== "N/A" && Math.abs(parseFloat(gap)) > 0.5 ? " <--" : "";
    const zStr = zohoBal !== null ? zohoBal.toFixed(2) : "N/A";
    const aStr = stmt.balance !== null ? stmt.balance.toFixed(2) : "???";
    console.log(`${stmt.date} | $${aStr.padStart(9)} | $${zStr.padStart(8)} | ${gap.toString().padStart(5)}${marker} | ${stmt.label}`);
    if (gap !== "N/A") prevGap = parseFloat(gap);
  }

  // Also check: is there any transaction exactly for $44?
  console.log("\n=== Searching for $44 transactions ===");
  for (const t of txns) {
    const amt = parseFloat(t.amount);
    if (Math.abs(amt - 44) < 0.5) {
      console.log(`  ${t.date} | $${amt} | ${t.debit_or_credit} | ${t.payee || "(blank)"} | running: $${t.running_balance}`);
    }
  }
  // Also check for amounts near $44 (could be $44.xx)
  for (const t of txns) {
    const amt = parseFloat(t.amount);
    if (Math.abs(amt - 44) >= 0.5 && Math.abs(amt - 44) < 1) {
      console.log(`  NEAR: ${t.date} | $${amt} | ${t.debit_or_credit} | ${t.payee || "(blank)"}`);
    }
  }
}
main().catch(e => console.error(e.message));
