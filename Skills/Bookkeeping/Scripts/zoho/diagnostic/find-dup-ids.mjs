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

  // Find the 5 duplicate expense entries and the $8 opening_balance
  // Duplicate pairs (transfer_fund + expense for same amount near same date):
  const pairs = [
    { date: "2025-06-30", amt: 10, type: "transfer_fund" },
    { date: "2025-07-02", amt: 10, type: "expense" },
    { date: "2025-10-01", amt: 10, type: "transfer_fund" },
    { date: "2025-10-02", amt: 10, type: "expense" },
    { date: "2025-12-30", amt: 10, type: "transfer_fund" },
    { date: "2025-12-31", amt: 10, type: "expense" },
    { date: "2026-01-30", amt: 10, type: "transfer_fund" },
    { date: "2026-02-02", amt: 10, type: "expense" },
    { date: "2026-03-30", amt: 12, type: "transfer_fund" },
    { date: "2026-03-31", amt: 12, type: "expense" }
  ];

  console.log("=== Finding target transactions ===");
  const toDelete = [];
  for (const p of pairs) {
    for (const t of txns) {
      const amt = parseFloat(t.amount);
      if (t.date === p.date && Math.abs(amt - p.amt) < 0.5 && t.transaction_type === p.type) {
        const label = `${t.date} | $${amt} | ${t.transaction_type.padEnd(15)} | id=${t.transaction_id}`;
        if (p.type === "expense") {
          console.log(`DELETE: ${label}`);
          toDelete.push(t.transaction_id);
        } else {
          console.log(`KEEP:   ${label}`);
        }
      }
    }
  }

  // Also the $8 opening_balance entry
  for (const t of txns) {
    const amt = parseFloat(t.amount);
    if (t.transaction_id === "93310000000590040") {
      console.log(`DELETE: ${t.date} | $${amt} | ${t.transaction_type.padEnd(15)} | id=${t.transaction_id} (phantom opening)`);
      toDelete.push(t.transaction_id);
    }
  }

  console.log(`\n=== IDs to delete (${toDelete.length} total) ===`);
  console.log(JSON.stringify(toDelete));
}
main().catch(e => console.error(e.message));
