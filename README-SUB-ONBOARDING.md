# Azure Native Dynatrace Service - PowerShell Subscription Onboarding

PowerShell script that auto-discovers Azure subscriptions and onboards each to a Dynatrace SaaS environment. Designed for enterprise scale with parallel execution, crash-safe resumability, and ARM throttle handling.

Compatible with **Windows PowerShell 5.1** (sequential) and **PowerShell 7+** (parallel).

## Three Modes

Most enterprise Azure customers use a micro-account model — one subscription per application or workload — for resource isolation and cost control. This is the standard hub-and-spoke pattern across both Azure and AWS, and enterprise tenants routinely have hundreds or even 1000+ subscriptions. This script supports three onboarding architectures to handle environments at any scale:

|                         | Centralized                                  | HybridCentralized                                        | Distributed                          |
| ----------------------- | -------------------------------------------- | -------------------------------------------------------- | ------------------------------------ |
| **Mechanism**           | `monitoredSubscriptions` on a single monitor | Auto-batches into groups of 15, one linked monitor/batch | Separate `monitors` resource per sub |
| **Subscription cap**    | 20 per monitor                               | **None** (15 per batch monitor)                          | **None**                             |
| **RGs created**         | 0                                            | ceil(N/15)                                               | N                                    |
| **Tag rules**           | Inherited from parent                        | Per-batch (inherited by members)                         | Per-subscription                     |
| **Managed identities**  | 1                                            | ceil(N/15)                                               | N                                    |
| **Management overhead** | Low                                          | Low                                                      | Higher                               |
| **Best for**            | Small environments (≤20 subs)                | **Enterprise (20-300+ subs)**                            | Maximum isolation                    |

```powershell
# Centralized (default, max 20 subs)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json

# HybridCentralized (recommended for 20+ subs, 15 subs per batch)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized

# Distributed (1 monitor per sub, no cap)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed
```

## Enterprise Scale Features

### Parallel Execution
Process multiple subscriptions concurrently. Requires PowerShell 7+; falls back to sequential on PS 5.1. Note: HybridCentralized runs sequentially (batch-by-batch) regardless of PowerShell version.

```powershell
# HybridCentralized (recommended for 20+ subs, runs sequentially by design)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized

# Distributed with 10 subs at a time
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed -ThrottleLimit 10

# Sequential (safe for debugging)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -ThrottleLimit 1
```

### Resumability
A state file (`onboarding-state.json`) tracks completed and failed subscriptions. If the script fails or is interrupted, re-run the same command — completed subs are skipped, failed subs are retried.

```powershell
# First run: processes 500 subs, fails at #347
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed

# Second run: skips 346 completed, retries #347, continues through #500
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed

# Start completely fresh (clear state)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed -ResetState
```

### ARM Throttle Handling
Automatic exponential backoff on HTTP 429 (Too Many Requests) and 5xx errors. Respects `Retry-After` headers. Retries up to 5 times per API call with delays of 10s, 20s, 40s, 80s, 160s.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+ (7+ recommended for parallelism)
- Az.Accounts and Az.Resources modules:
  `Install-Module -Name Az.Accounts, Az.Resources -Scope CurrentUser -Force`
- Owner or Contributor + User Access Administrator on target subscriptions
- An existing Azure Native Dynatrace Service monitor resource (the "source")
- For HybridCentralized and Distributed modes: the Dynatrace environment's **ingestion key** (see [Finding Your Ingestion Key](#finding-your-ingestion-key))

## Quick Start

```powershell
# 1. Install Az sub-modules (one-time, much faster than full Az)
Install-Module -Name Az.Accounts  -Scope CurrentUser -Force
Install-Module -Name Az.Resources -Scope CurrentUser -Force

# 2. Set execution policy and unblock (one-time)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Unblock-File .\Invoke-DynatraceOnboarding.ps1

# 3. Connect to Azure
Connect-AzAccount

# 4. Copy and edit config
Copy-Item .\config-example.json .\config.json
# Fill in your values (see Config File section)

# 5. Dry run (preview)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -DryRun

# 6. Run
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized
```

## Config File

Generate a new API token for ingestion for the new subscriptions first. Go to **Apps > Access tokens** and select **Clone** to clone an existing API token; there should be 2 there already. Copy the value of this API token and place it in `dynatrace_environment_ingestion_key` line in `config.json`. 

![alt text](image-1.png)

A single config file works for all three modes. HybridCentralized and Distributed modes use the additional `dynatrace_environment_*` fields. Fields not present in the JSON are safely ignored.

```json
{
  "dynatrace_subscription_id":     "00000000-...",
  "dynatrace_resource_group_name": "rg-dynatrace-prod",
  "dynatrace_monitor_name":        "dt-monitor-prod",
  "dynatrace_region":              "eastus",

  "dynatrace_environment_id":              "abc12345",
  "dynatrace_environment_ingestion_key":   "dt0c01.XXX.YYY",
  "dynatrace_landing_url":                 "https://abc12345.apps.dynatrace.com",

  "resource_name_prefix":        "dt-monitor",
  "target_resource_group_name":  "rg-dynatrace",
  "create_resource_group":       true,

  "plan": {
    "name": "azportalintegration_dynatrace_payg",
    "publisher": "dynatrace",
    "product": "dynatrace_portal_integration",
    "promotionCode": ""
  },
  "plan_data": {
    "usageType": "Committed",
    "billingCycle": "Monthly",
    "planDetails": "azportalintegration_dynatrace_payg",
    "effectiveDate": "2024-10-01T00:00:00Z"
  },

  "user_email":      "admin@XXXXX.com",
  "user_first_name": "Admin",
  "user_last_name":  "User",

  "subscription_filter":          "prod",
  "subscription_exclude_pattern": "sandbox",

  "defaults": {
    "send_activity_logs":        true,
    "send_subscription_logs":    true,
    "send_metrics":              true,
    "auto_muting":               true,
    "create_diagnostic_setting": true
  },

  "subscription_overrides": {}
}
```

### Field Reference

| Field                                 | Required | Mode        | Description                                                    |
| ------------------------------------- | -------- | ----------- | -------------------------------------------------------------- |
| `dynatrace_subscription_id`           | Yes      | Both        | Subscription hosting the source monitor.                       |
| `dynatrace_resource_group_name`       | Yes      | Both        | RG of the source monitor.                                      |
| `dynatrace_monitor_name`              | Yes      | Both        | Source monitor name.                                           |
| `dynatrace_region`                    | No       | Both        | Azure region (auto-read from source if omitted).               |
| `dynatrace_environment_id`            | Yes*     | Hybrid/Dist | Dynatrace tenant ID (e.g. `abcXXXXX`).                         |
| `dynatrace_environment_ingestion_key` | Yes*     | Hybrid/Dist | Environment ingestion key.                                     |
| `dynatrace_landing_url`               | No       | Hybrid/Dist | Defaults to `https://{env_id}.apps.dynatrace.com`.             |
| `dynatrace_logs_ingestion_endpoint`   | No       | Hybrid/Dist | Auto-read from source if omitted.                              |
| `dynatrace_account_id`                | No       | Hybrid/Dist | Auto-read from source if omitted.                              |
| `dynatrace_region_id`                 | No       | Hybrid/Dist | Auto-read from source if omitted.                              |
| `resource_name_prefix`                | No       | Hybrid/Dist | Monitor name prefix (default: `dt-monitor`).                   |
| `target_resource_group_name`          | No       | Hybrid/Dist | RG in each target/anchor sub (default: `rg-dynatrace`).        |
| `create_resource_group`               | No       | Hybrid/Dist | Auto-create RG (default: `true`).                              |
| `plan`                                | No       | Hybrid/Dist | Marketplace plan block (auto-detected, see below).             |
| `plan_data`                           | No       | Hybrid/Dist | Marketplace plan data (auto-detected, see below).              |
| `user_email`                          | No       | Hybrid/Dist | Email for monitor userInfo (default: Az login email).          |
| `user_first_name`                     | No       | Hybrid/Dist | First name for monitor userInfo (default: derived from email). |
| `user_last_name`                      | No       | Hybrid/Dist | Last name for monitor userInfo (default: `AzureUser`).         |
| `subscription_filter`                 | No       | Both        | Regex inclusion filter. Set to `""` to have nothing filtered.  |
| `subscription_exclude_pattern`        | No       | Both        | Regex exclusion filter. Set to `""` to have nothing filtered.  |
| `defaults`                            | No       | Both        | Default log/metric settings.                                   |
| `subscription_overrides`              | No       | Both        | Per-sub overrides keyed by GUID.                               |

*Auto-read from source monitor if available.

### Marketplace Plan Detection

HybridCentralized and Distributed modes create **linked monitors** that must carry the same Marketplace plan as the source monitor. The script uses a 3-layer approach to obtain plan data:

| Layer | Source                    | When used                                                                      |
| ----- | ------------------------- | ------------------------------------------------------------------------------ |
| 1     | ARM REST API GET response | First attempt — checks `plan` block on the source monitor                      |
| 2     | `Get-AzResource` fallback | If Layer 1 returns nothing (common — some RPs omit `plan` from REST responses) |
| 3     | `config.json` override    | Always wins if present — use when auto-detection fails                         |

**If auto-detection fails**, the script prints the exact JSON to add to `config.json` and stops. To find your plan details manually:

```powershell
# Check your source monitor's plan
Get-AzResource -ResourceGroupName "<source-rg>" -Name "<source-monitor>" `
    -ResourceType "Dynatrace.Observability/monitors" | Select-Object -ExpandProperty Plan
```

Common Marketplace plans:

| Plan Name                            | Publisher   | Product                        |
| ------------------------------------ | ----------- | ------------------------------ |
| `azportalintegration_dynatrace_payg` | `dynatrace` | `dynatrace_portal_integration` |
| `azportalintegration_privatepreview` | `dynatrace` | `dynatrace_portal_integration` |

## CLI Parameters

| Parameter                     | Type   | Default                   | Description                                          |
| ----------------------------- | ------ | ------------------------- | ---------------------------------------------------- |
| `-ConfigFile`                 | string | required                  | Path to JSON config                                  |
| `-Mode`                       | string | `Centralized`             | `Centralized`, `HybridCentralized`, or `Distributed` |
| `-ThrottleLimit`              | int    | `5`                       | Max parallel subs (PS 7+ only)                       |
| `-StateFile`                  | string | `./onboarding-state.json` | State file path for resumability                     |
| `-ResetState`                 | switch | `$false`                  | Clear state and start fresh                          |
| `-SubscriptionFilter`         | string | from config               | Regex inclusion (overrides config)                   |
| `-SubscriptionExcludePattern` | string | from config               | Regex exclusion (overrides config)                   |
| `-IncludeDisabled`            | switch | `$false`                  | Include disabled subs                                |
| `-DryRun`                     | switch | `$false`                  | Preview only                                         |
| `-Action`                     | string | `Onboard`                 | `Onboard` or `Offboard`                              |
| `-ForceDeleteResourceGroups`  | switch | `$false`                  | Delete RGs on offboard                               |

## What Each Mode Does

### Centralized

| Phase | Action                                                   |
| ----- | -------------------------------------------------------- |
| 1     | Verify Azure connection                                  |
| 2     | Resolve source monitor + managed identity                |
| 3     | Discover subs, apply filters                             |
| 3b    | Enable metrics/logs on parent monitor tag rules          |
| 4a    | Assign Monitoring Reader per sub                         |
| 4b    | PUT `monitoredSubscriptions/default`                     |
| 4c    | Register `Microsoft.Insights`, create diagnostic setting |

### HybridCentralized (Recommended for 20+ subs)

Combines the simplicity of Centralized with the scalability of Distributed. Auto-batches subscriptions into groups of 15, creating one linked monitor per batch. Each batch has an "anchor" subscription that hosts the monitor, and up to 14 "member" subscriptions linked via `monitoredSubscriptions`.

| Phase | Action                                                               |
| ----- | -------------------------------------------------------------------- |
| 1     | Verify Azure connection                                              |
| 2     | Resolve source monitor, read environment details                     |
| 3     | Discover subs, apply filters                                         |
| 4a    | **Discovery:** Scan for existing batch monitors (retry-safe)         |
| 4b    | Route pending subs to existing batches with capacity                 |
| 4c    | Create new batches for remaining subs (RG + monitor + tag rules)     |
| 4d    | Assign Monitoring Reader + link members via `monitoredSubscriptions` |

**Batch sizing:** 15 subs per batch (5-sub buffer below the 20-sub API limit) to prevent data flow interruptions at the boundary.

**Retry-safe:** On re-run, the script discovers existing batch monitors and routes failed subs to them — no duplicate monitors are created.

### Distributed

| Phase | Action                                                     |
| ----- | ---------------------------------------------------------- |
| 1     | Verify Azure connection                                    |
| 2     | Resolve source monitor, read environment details           |
| 3     | Discover subs, exclude source, apply filters               |
| 4a    | Create resource group in target sub                        |
| 4b    | Register `Dynatrace.Observability` provider                |
| 4c    | PUT new `monitors` resource linked to existing environment |
| 4d    | PUT `tagRules/default` (with provisioning retry)           |

**Note:** In Distributed mode, the source subscription is automatically excluded from onboarding since it already has the original monitor resource.

## Scale Guidance

| Subscription Count  | Recommended Settings                                               |
| ------------------- | ------------------------------------------------------------------ |
| 1-20                | `-Mode Centralized`                                                |
| 20-300              | `-Mode HybridCentralized`                                          |
| 300-1000+           | `-Mode HybridCentralized`, run from an Azure VM in the same region |
| Any (max isolation) | `-Mode Distributed -ThrottleLimit 10`                              |

For 300+ subscriptions, consider running from a VM or Cloud Shell in the same Azure region as your Dynatrace environment to minimize ARM API latency. HybridCentralized runs sequentially (batch-by-batch) but the state file ensures you can interrupt and resume without re-processing.

**Why HybridCentralized over Distributed?** For 300 subs, HybridCentralized creates 20 RGs and 20 monitors vs. 300 RGs and 300 monitors in Distributed mode. Fewer resources = lower management overhead and easier DAC consolidation later.

## Output

```
SubscriptionName  SubscriptionId  ResourceGroup  MonitorResource  TagRules    Error
----------------  --------------  -------------  ---------------  --------    -----
App-Payments      aaaa-bbbb...    Created        Created          Configured
App-Identity      1111-2222...    AlreadyExists  AlreadyExists    Configured
App-Analytics     6666-7777...    Created        Created          Configured
```

Pipeline-friendly: `$results = .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized`

## Troubleshooting

| Error                               | Fix                                                                                                                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Script not digitally signed         | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` then `Unblock-File`                                                                                                             |
| Parallel requires PS 7+             | Install [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) or use `-ThrottleLimit 1`                                                |
| ARM throttle (429)                  | Automatic backoff. Reduce `-ThrottleLimit` if persistent                                                                                                                              |
| Token expiry during long runs       | Script re-acquires tokens per API call                                                                                                                                                |
| Partial failure                     | Re-run same command — completed subs are skipped via state file                                                                                                                       |
| Dynatrace username cannot be empty  | Add `user_first_name` and `user_last_name` to config, or let the script auto-derive them from your Az login                                                                           |
| 20+ subs in Centralized             | Script warns you. Switch to `-Mode HybridCentralized` or `-Mode Distributed`                                                                                                          |
| Missing ingestion key               | Required for HybridCentralized and Distributed. See [Finding Your Ingestion Key](#finding-your-ingestion-key)                                                                         |
| Monitor stuck at `Accepted`         | Missing plan data. Script now auto-detects via `Get-AzResource` fallback. If needed, add `plan`/`plan_data` to config (see [Marketplace Plan Detection](#marketplace-plan-detection)) |
| No plan block on source monitor     | Dynatrace RP may omit `plan` from ARM REST response even for Marketplace monitors. The 3-layer plan detection handles this automatically                                              |
| Monitor still provisioning          | Tag rules retry up to 5x with 15s delay                                                                                                                                               |
| Diagnostic setting conflict         | Azure auto-created one via tag rules — reported as `ManagedByMonitor`                                                                                                                 |
| All subscriptions already completed | State file shows all done. Use `-ResetState` to re-run from scratch                                                                                                                   |
| Switching Onboard ↔ Offboard        | Must use `-ResetState` when switching between actions, otherwise completed subs from prior action are skipped                                                                         |
| Offboard misses resources           | Offboard mode must match the original onboard mode (e.g., use `-Mode HybridCentralized` to offboard HybridCentralized resources)                                                      |

## Offboarding

Remove Dynatrace linkages from all or filtered subscriptions. The offboard mode **must match** how subs were originally onboarded.

```powershell
# Offboard HybridCentralized (preserves RGs for reuse)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode HybridCentralized -ResetState

# Offboard and delete RGs
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode HybridCentralized -ForceDeleteResourceGroups -ResetState

# Offboard Distributed
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode Distributed -ResetState
```

**Important:** Always use `-ResetState` when switching between Onboard and Offboard actions.
