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

  // Check Apr 9 running balance
  for (const t of allTxns) {
    if (t.date === "2025-04-01" && Math.abs(parseFloat(t.amount) - 21.78) < 0.01) {
      console.log("Entry still exists:", t.date, t.amount, t.transaction_type, "id=", t.transaction_id);
    }
    if (t.date === "2025-04-09" && t.running_balance !== undefined) {
      console.log("Apr 9 running balance: $", t.running_balance);
    }
  }
  
  // Also check the $21.78 entry
  const found = allTxns.filter(t => t.transaction_id === "93310000000590040");
  console.log("Entry 93310000000590040 exists:", found.length > 0);
}
main().catch(e => console.error(e.message));
