import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;

  const acctId = "93310000000100019";
  const url = `https://www.zohoapis.com/books/v3/banktransactions?account_id=${acctId}&organization_id=925048093&per_page=200&sort_column=date&sort_order=A`;
  const txns = (await (await fetch(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json()).banktransactions || [];

  // Running balance at key dates
  const dates = ["2026-04-13", "2026-05-13"];
  for (const d of dates) {
    let bal = null;
    for (const t of txns) {
      if (t.date <= d && t.running_balance !== undefined) bal = t.running_balance;
    }
    console.log(`Zoho balance ${d}: $${bal}`);
  }

  // Transactions in the Apr 13 - May 13 period
  console.log("\nTransactions Apr 13 - May 13:");
  const periodTxns = txns.filter(t => t.date > "2026-04-13" && t.date <= "2026-05-13");
  for (const t of periodTxns) {
    console.log(`  ${t.date} | ${(t.payee || "(blank)").padEnd(35)} | ${t.debit_or_credit.padEnd(6)} | $${t.amount.toString().padStart(8)} | type=${t.transaction_type}`);
  }
}
main().catch(e => console.error(e.message));
