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
  const ba = await (await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${mcId}?organization_id=925048093`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
  console.log("MC 6258 account:");
  console.log(`  book balance: ${ba.bankaccount?.balance}`);
  console.log(`  bank balance: ${ba.bankaccount?.bank_balance}`);
  console.log(`  account_type: ${ba.bankaccount?.account_type}`);
  console.log(`  account_sub_type: ${ba.bankaccount?.account_sub_type}`);

  // Get transactions sorted by date to see running balance at statement dates
  const txns = (await (await fetch(`https://www.zohoapis.com/books/v3/banktransactions?account_id=${mcId}&organization_id=925048093&per_page=200&sort_column=date&sort_order=A`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json()).banktransactions || [];
  
  console.log(`\nTotal MC transactions: ${txns.length}`);
  
  // Check running balance at key statement dates
  const mcStatements = [
    { date: "2025-04-09", label: "Apr 9, 2025" },
    { date: "2025-05-09", label: "May 9, 2025" },
    { date: "2025-06-09", label: "Jun 9, 2025" },
    { date: "2025-07-09", label: "Jul 9, 2025" },
    { date: "2025-08-11", label: "Aug 11, 2025" },
    { date: "2025-09-09", label: "Sep 9, 2025" },
    { date: "2025-10-09", label: "Oct 9, 2025" },
    { date: "2025-11-10", label: "Nov 10, 2025" },
    { date: "2025-12-09", label: "Dec 9, 2025" },
    { date: "2026-01-09", label: "Jan 9, 2026" },
    { date: "2026-02-09", label: "Feb 9, 2026" },
    { date: "2026-03-09", label: "Mar 9, 2026" },
    { date: "2026-04-09", label: "Apr 9, 2026" },
    { date: "2026-05-11", label: "May 11, 2026" }
  ];
  
  console.log("\nMC running balance at statement dates:");
  for (const s of mcStatements) {
    let bal = null;
    for (const t of txns) {
      if (t.date <= s.date && t.running_balance !== undefined) bal = t.running_balance;
    }
    console.log(`  ${s.date} (${s.label}): $${bal}`);
  }
  
  // Show first and last few transactions
  console.log("\nFirst 3 MC transactions:");
  txns.slice(0, 3).forEach(t => console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.debit_or_credit.padEnd(6)} | ${t.transaction_type.padEnd(16)} | ${(t.payee || "").padEnd(30)} | running=$${t.running_balance}`));
  
  console.log("\nLast 5 MC transactions:");
  txns.slice(-5).forEach(t => console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.debit_or_credit.padEnd(6)} | ${t.transaction_type.padEnd(16)} | ${(t.payee || "").padEnd(30)} | running=$${t.running_balance}`));
}
main().catch(e => console.error(e.message));
