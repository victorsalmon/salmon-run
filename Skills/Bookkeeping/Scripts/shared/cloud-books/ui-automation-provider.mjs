class NotImplementedError extends Error {
  constructor(methodName) {
    super(`${methodName} is not implemented by this UI automation provider`);
    this.name = 'NotImplementedError';
  }
}

class UIAutomationProvider {
  constructor(entitySlug, entityConfig) {
    this.entitySlug = entitySlug;
    this.entityConfig = entityConfig;
  }

  async loginAndMaintainSession() {
    throw new NotImplementedError('loginAndMaintainSession');
  }

  async quickCategorize(transactions) {
    throw new NotImplementedError('quickCategorize');
  }

  async reconcileViaUI(accountSlug, statementData) {
    throw new NotImplementedError('reconcileViaUI');
  }

  async archiveFiscalYear(year) {
    throw new NotImplementedError('archiveFiscalYear');
  }
}

export { UIAutomationProvider };
