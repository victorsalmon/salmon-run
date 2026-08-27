/**
 * @typedef {Object} Transaction
 * @property {string} id - Provider-specific transaction identifier
 * @property {string} date - ISO 8601 transaction date
 * @property {string} description - Transaction description/memo
 * @property {number} amount - Transaction amount (positive=debit, negative=credit)
 * @property {string} currency - ISO 4217 currency code (e.g. "CAD")
 * @property {string} accountId - Provider account identifier
 * @property {string} [categoryId] - Category/account classification identifier
 * @property {string} [vendorName] - Counterparty name
 * @property {boolean} isReconciled - Whether the transaction has been reconciled
 * @property {Object} [providerMetadata] - Provider-specific raw data
 */

/**
 * @typedef {Object} Expense
 * @property {string} id - Provider-specific expense identifier
 * @property {string} date - ISO 8601 expense date
 * @property {string} vendorId - Provider vendor/contact identifier
 * @property {string} accountId - Chart of accounts category identifier
 * @property {number} amount - Expense amount
 * @property {string} [receiptPath] - Local or remote path to receipt image
 * @property {boolean} hasReceipt - Whether a receipt attachment exists
 */

/**
 * @typedef {Object} Account
 * @property {string} id - Provider-specific account identifier
 * @property {string} name - Account display name
 * @property {string} type - Account type (e.g. "bank", "credit_card", "expense", "income")
 */

/**
 * @typedef {Object} Contact
 * @property {string} id - Provider-specific contact identifier
 * @property {string} name - Contact display name
 * @property {string} email - Contact email address
 */

/**
 * @typedef {Object} ReportPeriod
 * @property {string} from - ISO 8601 start date
 * @property {string} to - ISO 8601 end date
 */

/**
 * @typedef {Object} Report
 * @property {ReportPeriod} period - Report date range
 * @property {Array<Object>} rows - Report data rows (provider-specific shape)
 */

export {};
