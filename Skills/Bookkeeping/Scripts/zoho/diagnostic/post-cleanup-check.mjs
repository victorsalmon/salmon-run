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

  // 1. Check RBC bank account current state
  const acctId = "93310000000100019";
  const ba = await (await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${acctId}?organization_id=925048093`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  })).json();
  console.log("=== RBC INTERSITE ===");
  console.log(`  Book balance: $${ba.bankaccount?.balance}`);
  console.log(`  Bank balance: $${ba.bankaccount?.bank_balance}`);

  // 2. Check last few transactions for running balance
  const txns = await (await fetch(`https://www.zohoapis.com/books/v3/banktransactions?account_id=${acctId}&organization_id=925048093&per_page=5&sort_column=date&sort_order=D`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  })).json();
  console.log("\n  Last 5 transactions:");
  for (const t of (txns.banktransactions || [])) {
    console.log(`    ${t.date} | ${t.transaction_type.padEnd(16)} | $${t.amount.toString().padStart(8)} | running: $${t.running_balance}`);
  }

  // 3. Check MC 6258
  const mcId = "93310000000100013";
  const mcBa = await (await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${mcId}?organization_id=925048093`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  })).json();
  console.log("\n=== MC 6258 ===");
  console.log(`  Book balance: $${mcBa.bankaccount?.balance}`);
  console.log(`  Bank balance: $${mcBa.bankaccount?.bank_balance}`);

  // 4. Trial balance key accounts (from freshly synced file)
  console.log("\n=== KEY TB ACCOUNTS (FY ending Mar 31, 2026) ===");
}
main().catch(e => console.error(e.message));
