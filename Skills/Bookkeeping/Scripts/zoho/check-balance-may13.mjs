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

  // Fetch all RBC transactions sorted by date ascending to get running balance through time
  const url = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=200&sort_column=date&sort_order=A";
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  const txns = result.banktransactions || [];

  // Find the running balance as of May 13, 2026
  let asOfMay13 = null;
  let currentBal = null;
  let postMay13Outflows = 0;
  
  for (const t of txns) {
    if (t.date <= "2026-05-13" && t.running_balance !== undefined) {
      asOfMay13 = t.running_balance;
    }
    if (t.date > "2026-05-13") {
      const amt = parseFloat(t.amount);
      if (t.debit_or_credit === "credit") {
        postMay13Outflows += amt;
      }
    }
    if (t.running_balance !== undefined) {
      currentBal = t.running_balance;
    }
  }

  console.log("Zoho balance as of May 13, 2026:", asOfMay13);
  console.log("Current Zoho balance:", currentBal);
  console.log("Post-May 13 credit outflows (Zoho):", postMay13Outflows);
  console.log("Actual bank balance (May 13 statement): 4,146.16");
  if (asOfMay13 !== null) {
    const gap = 4146.16 - asOfMay13;
    console.log("Gap as of May 13:", gap.toFixed(2));
    console.log("(Zoho has", asOfMay13 < 4146.16 ? "LESS" : "MORE", "than the bank by", Math.abs(gap).toFixed(2), ")");
  }

  // Show last 10 transactions with running balance
  const last10 = txns.slice(-10);
  console.log("\nLast 10 transactions (oldest first):");
  for (const t of last10) {
    console.log(`  ${t.date} | ${(t.payee || "(blank)").padEnd(45)} | ${t.debit_or_credit.padEnd(6)} | $${t.amount.toString().padStart(8)} | running: $${t.running_balance}`);
  }
}
main().catch(e => console.error(e.message));
