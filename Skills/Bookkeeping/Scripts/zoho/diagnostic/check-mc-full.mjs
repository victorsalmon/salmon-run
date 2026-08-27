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
  let page = 1;
  let hasMore = true;
  while (hasMore && page < 10) {
    const url = `https://www.zohoapis.com/books/v3/banktransactions?account_id=${mcId}&organization_id=925048093&per_page=200&page=${page}&sort_column=date&sort_order=A`;
    const data = await (await fetch(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
    const txns = data.banktransactions || [];
    allTxns.push(...txns);
    hasMore = data.page_context?.has_more_page || false;
    page++;
  }
  
  console.log(`Total MC transactions (all pages): ${allTxns.length}`);
  
  // Show last 10
  console.log("\nLast 10 transactions:");
  allTxns.slice(-10).forEach(t => console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.debit_or_credit.padEnd(6)} | ${t.transaction_type.padEnd(16)} | ${(t.payee || "").padEnd(35)} | running=$${t.running_balance}`));
  
  // Running balance at statement dates
  const dates = ["2025-04-09","2025-05-09","2025-06-09","2025-07-09","2025-08-11","2025-09-09","2025-10-09","2025-11-10","2025-12-09","2026-01-09","2026-02-09","2026-03-09","2026-04-09","2026-05-11","2026-07-03"];
  console.log("\nRunning balance at statement dates:");
  for (const d of dates) {
    let bal = null;
    for (const t of allTxns) { if (t.date <= d && t.running_balance !== undefined) bal = t.running_balance; }
    console.log(`  ${d}: $${bal}`);
  }
}
main().catch(e => console.error(e.message));
