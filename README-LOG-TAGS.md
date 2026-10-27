# Dynatrace ANDS Log & Metric Filtering — Quick Start

Manage which Azure resources ship **logs and/or metrics** to Dynatrace by updating ANDS
monitor tag rules.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1)
- `Az.Accounts` module installed and authenticated (`Connect-AzAccount`)
- Existing ANDS monitors deployed via `Invoke-DynatraceOnboarding.ps1`
- Same `config.json` used for the original onboarding

## Common Scenarios

### Exclude resources by tag

Stop shipping logs for all resources tagged `env=dev`:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveLogs -TagName "env" -TagValue "dev"
```

### Exclude resources with any value for a tag key

Exclude all resources that have the tag `temporary` (regardless of value):

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveLogs -TagName "temporary" -TagValue "*"
```

### Disable subscription-level logs entirely

Turn off Activity Logs and Subscription Logs for specific subscriptions:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -DisableSubscriptionLogs `
    -SubscriptionFilter "sandbox"
```

### Combine both (tag exclusion + disable sub logs)

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveLogs -TagName "cost-center" -TagValue "testing" `
    -DisableSubscriptionLogs `
    -SubscriptionFilter "dev-.*"
```

### Exclude resources from metric shipment by tag

Stop shipping **metrics** for all resources tagged `env=dev`:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveMetrics -TagName "env" -TagValue "dev"
```

### Exclude a tag from BOTH logs and metrics

Apply the same exclusion tag to both log and metric rules in one run:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveLogs -RemoveMetrics -TagName "env" -TagValue "dev"
```

### Disable all metric shipment for a monitor

Turn off `sendingMetrics` entirely for matching subscriptions (independent of tags):

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -DisableMetrics `
    -SubscriptionFilter "sandbox"
```

### Re-enable logs (undo exclusion)

Remove a previously added exclusion tag:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RestoreLogs -TagName "env" -TagValue "dev"
```

Re-enable subscription-level logs:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -EnableSubscriptionLogs `
    -SubscriptionFilter "sandbox"
```

Re-include resources for metric shipment (remove a metric exclusion tag):

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RestoreMetrics -TagName "env" -TagValue "dev"
```

Re-enable all metric shipment:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -EnableMetrics `
    -SubscriptionFilter "sandbox"
```

### Preview changes (dry run)

Append `-DryRun` to any command to see what would change without applying:

```powershell
.\Invoke-DynatraceOnboarding-LoggingRules.ps1 `
    -ConfigFile .\config.json `
    -Mode Distributed `
    -RemoveLogs -TagName "env" -TagValue "dev" `
    -DryRun
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ConfigFile` | Yes | Path to config.json (same as onboarding script) |
| `-Mode` | No | `Distributed` (default), `Centralized`, or `HybridCentralized` |
| `-RemoveLogs` | — | Add an Exclude filtering tag (blocks log shipment for matching resources) |
| `-RestoreLogs` | — | Remove a previously added Exclude log filtering tag |
| `-RemoveMetrics` | — | Add an Exclude filtering tag (blocks metric shipment for matching resources) |
| `-RestoreMetrics` | — | Remove a previously added Exclude metric filtering tag |
| `-DisableSubscriptionLogs` | — | Disable Activity + Subscription logs for the subscription |
| `-EnableSubscriptionLogs` | — | Re-enable Activity + Subscription logs |
| `-DisableMetrics` | — | Disable `sendingMetrics` on the monitor (stops all metric shipment) |
| `-EnableMetrics` | — | Re-enable `sendingMetrics` on the monitor |
| `-TagName` | With `-Remove*`/`-Restore*` | Azure resource tag key to match |
| `-TagValue` | No | Azure resource tag value to match (default: `*` = any value) |
| `-SubscriptionFilter` | No | Regex to target specific subscriptions by name |
| `-DryRun` | No | Preview only — no changes applied |

## How It Works

1. **Discovers monitors** based on Mode (same logic as onboarding script)
2. **Reads existing tag rules** from each monitor (`GET .../tagRules/default`)
3. **Merges changes** — adds/removes filtering tags or toggles log settings (preserves all existing rules)
4. **PUTs updated tag rules** back to the monitor

Changes are additive: running `-RemoveLogs` multiple times with different tags accumulates exclusions. Use `-RestoreLogs` to remove specific exclusions.

## How ANDS Filtering Tags Work

Azure Native Dynatrace Service evaluates filtering tags against **Azure resource tags** on individual resources:

- A resource tagged `env=dev` in Azure + an Exclude rule for `env=dev` in the monitor → that resource's logs are **not** shipped
- Other resources in the same subscription without that tag continue shipping normally
- `TagValue = "*"` matches any value for the specified tag key

Log and metric filtering tags are evaluated independently: `logRules.filteringTags` controls
log shipment and `metricRules.filteringTags` controls metric shipment. Use `-RemoveLogs`
for logs, `-RemoveMetrics` for metrics, or both together to exclude a resource from each.

This is separate from subscription-level controls (`sendActivityLogs`, `sendSubscriptionLogs`)
and the monitor-level metric switch (`sendingMetrics`), which are all-or-nothing per monitor.
