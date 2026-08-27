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

  // Show ALL transactions up to Apr 9, 2025 (first statement date)
  console.log("Zoho MC transactions up to Apr 9, 2025:");
  for (const t of allTxns) {
    if (t.date <= "2025-04-09") {
      console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.debit_or_credit.padEnd(6)} | ${t.transaction_type.padEnd(16)} | ${(t.payee || "").padEnd(35)} | running=$${t.running_balance}`);
    }
  }
}
main().catch(e => console.error(e.message));
