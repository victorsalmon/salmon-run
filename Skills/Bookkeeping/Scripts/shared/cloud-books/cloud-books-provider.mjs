class ProviderAuthError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProviderAuthError';
  }
}

class ProviderRateLimitError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProviderRateLimitError';
  }
}

class ProviderTemporaryError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProviderTemporaryError';
  }
}

class NotImplementedError extends Error {
  constructor(methodName) {
    super(`${methodName} is not implemented by this provider`);
    this.name = 'NotImplementedError';
  }
}

class CloudBooksProvider {
  async authenticate() { throw new NotImplementedError('authenticate'); }
  async refreshToken() { throw new NotImplementedError('refreshToken'); }
  getAuthHeaders() { throw new NotImplementedError('getAuthHeaders'); }

  async listBankAccounts() { throw new NotImplementedError('listBankAccounts'); }
  async getChartOfAccounts() { throw new NotImplementedError('getChartOfAccounts'); }
  async listTransactions(accountSlug, from, to) { throw new NotImplementedError('listTransactions'); }
  async categorizeTransaction(transactionId, categoryId) { throw new NotImplementedError('categorizeTransaction'); }
  async createExpense(expenseData) { throw new NotImplementedError('createExpense'); }
  async getExpenses(from, to) { throw new NotImplementedError('getExpenses'); }
  async attachReceipt(expenseId, filePath) { throw new NotImplementedError('attachReceipt'); }

  async listContacts() { throw new NotImplementedError('listContacts'); }
  async findOrCreateContact(contactData) { throw new NotImplementedError('findOrCreateContact'); }

  async getProfitAndLoss(from, to) { throw new NotImplementedError('getProfitAndLoss'); }
  async getTrialBalance(from, to) { throw new NotImplementedError('getTrialBalance'); }
  async getBalanceSheet(from, to) { throw new NotImplementedError('getBalanceSheet'); }
  async getGeneralLedger(from, to) { throw new NotImplementedError('getGeneralLedger'); }

  async startReconciliation(accountId, statement) { throw new NotImplementedError('startReconciliation'); }
  async completeReconciliation(reconciliationId) { throw new NotImplementedError('completeReconciliation'); }

  getCapabilities() { throw new NotImplementedError('getCapabilities'); }
  createUIAutomation() { return null; }
}

export { CloudBooksProvider, ProviderAuthError, ProviderRateLimitError, ProviderTemporaryError, NotImplementedError };
