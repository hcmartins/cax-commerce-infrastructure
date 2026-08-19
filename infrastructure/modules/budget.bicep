// Monthly cost budget scoped to this resource group, with direct email alerts at 80%
// actual and 100% forecasted spend. No Action Group is used — Consumption budgets support
// emailing contacts directly, which is simpler and sufficient for an MVP alert.
targetScope = 'resourceGroup'

@description('Budget name')
param budgetName string

@description('Monthly budget amount in the subscription\'s billing currency')
param amount int

@description('Email addresses notified when thresholds are crossed')
param contactEmails array

@description('First day of the current month, e.g. 2026-08-01. Budgets require a month-aligned start date.')
param startDate string = utcNow('yyyy-MM-01')

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
      endDate: dateTimeAdd(startDate, 'P10Y')
    }
    notifications: {
      actual_80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        contactEmails: contactEmails
        thresholdType: 'Actual'
      }
      forecasted_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        contactEmails: contactEmails
        thresholdType: 'Forecasted'
      }
    }
  }
}
