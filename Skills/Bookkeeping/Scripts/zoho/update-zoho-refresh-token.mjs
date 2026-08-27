const refreshToken = process.argv[2];
if (!refreshToken) {
  console.error('Usage: node update-zoho-refresh-token.mjs <refresh_token>');
  process.exit(1);
}

// The refresh token is stored in the Docker secrets bundle.
// To update it, update the AWS SM secret ZOHO_BOOKS_REFRESH, then redeploy.
// OAuth tokens are kept in-memory only (no disk cache), so no cache to clear.

console.log('\nTo persist the new refresh token permanently:');
console.log('  1. Update the AWS Secrets Manager secret ZOHO_BOOKS_REFRESH with:');
console.log(`     ${refreshToken}`);
console.log('  2. Re-deploy the fleet to propagate to the proxy container.');
console.log('\nFor immediate use, the new refresh token is also printed above.');
console.log('The zoho-auth.js module will auto-refresh on next API call.');
