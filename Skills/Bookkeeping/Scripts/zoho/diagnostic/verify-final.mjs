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

  // Get the last few transactions to see current running balance
  const url = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=10&sort_column=date&sort_order=D";
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  
  console.log("Last transactions (newest first):");
  for (const t of (result.banktransactions || [])) {
    console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.transaction_type.padEnd(16)} | ${(t.payee || "(blank)").padEnd(30)} | running: $${t.running_balance}`);
  }
  
  // Check if the $8 opening_balance entry still exists
  const url2 = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=200&sort_column=date&sort_order=A";
  const getResp2 = await fetch(url2, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result2 = await getResp2.json();
  const txns = result2.banktransactions || [];
  
  const opening8 = txns.filter(t => t.transaction_id === "93310000000590040");
  console.log("\n$8 opening_balance entry still exists:", opening8.length > 0 ? "YES" : "NO");
  
  // Check all statement periods
  const statements = [
    { date: "2025-04-11", balance: 5734.22 },
    { date: "2025-07-11", balance: 8482.44 },
    { date: "2025-10-10", balance: 5156.95 },
    { date: "2026-01-13", balance: 6072.59 },
    { date: "2026-03-13", balance: 4535.77 },
    { date: "2026-05-13", balance: 4146.16 }
  ];
  
  console.log("\n=== Gap check after ALL fixes ===");
  for (const stmt of statements) {
    let zohoBal = null;
    for (const t of txns) {
      if (t.date <= stmt.date && t.running_balance !== undefined) {
        zohoBal = t.running_balance;
      }
    }
    const gap = stmt.balance - zohoBal;
    console.log(`  ${stmt.date}: bank=$${stmt.balance.toFixed(2)} zoho=$${zohoBal.toFixed(2)} gap=$${gap.toFixed(2)}`);
  }
}
main().catch(e => console.error(e.message));
