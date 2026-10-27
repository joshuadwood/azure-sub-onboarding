# Azure Native Dynatrace Service — Subscription Onboarding Agent

## Purpose
This workspace automates onboarding and offboarding 300+ Azure subscriptions to/from a Dynatrace SaaS environment using Azure Native Dynatrace Service (ANDS).

## Key Files
- `Invoke-DynatraceOnboarding.ps1` — Main script (Centralized, HybridCentralized, and Distributed modes; Onboard/Offboard actions)
- `config.json` — Configuration for the target Dynatrace environment, resource group naming, and subscription filters
- `onboarding-state.json` — Auto-generated state file tracking completed/failed subscriptions
- `.github/agents/dynatrace-onboarding.agent.md` — VS Code agent for executing and evaluating runs

## Two Actions

| Action | Purpose |
|--------|---------|
| **Onboard** (default) | Creates monitors, links subscriptions, configures tag rules and diagnostics |
| **Offboard** | Removes monitors, unlinks subscriptions, removes role assignments. Preserves RGs by default. |

## Three Modes

| Mode | Mechanism | RGs created | Sub cap | Best for |
|------|-----------|-------------|---------|----------|
| Centralized | `monitoredSubscriptions` on source monitor | 0 | 20 | Small environments |
| **HybridCentralized** | Auto-batches into groups of 15, creates one linked monitor per batch | **ceil(N/15)** | **None** | **300+ subs with minimal RGs** |
| Distributed | Separate `monitors` resource per sub | N | None | Maximum isolation |

## Hard Constraints
- **Dynatrace cluster location:** `eastus` only (no clusters in `eastus2` or `centralus`)
- **Company policy:** Only `eastus2` and `centralus` allowed for resource creation
- **Resolution:** Azure Policy exemption required for `Dynatrace.Observability/*` resource types in `eastus` (see Policy Exemption section)

## HybridCentralized Mode (Recommended for 300+ Subs)
For each batch of 15 subscriptions:
1. An "anchor" subscription hosts a linked monitor in `target_resource_group_name`
2. The remaining 14 subs are linked as `monitoredSubscriptions` on that batch monitor
3. Tag rules and role assignments are configured per batch

Result: **20 RGs and 20 monitors for 300 subs** (vs. 300 RGs in Distributed mode).

### DAC Consolidation (June/July 2026)
When the Dynatrace Data Acquisition Controller (DAC) lifts the 20-sub cap on Centralized mode:
1. Consolidate all batch monitors into the original source monitor
2. Delete batch monitors and their RGs
3. Switch to pure Centralized mode with a single monitor (1 RG total)

## Offboarding

### Default Behavior (RG Preservation)
When offboarding **without** `-ForceDeleteResourceGroups`:
- Monitors, tag rules, monitored subscription links, and role assignments are removed
- **Resource groups are preserved** for reuse on re-deployment
- On re-onboarding, the script discovers existing RGs and reuses them (no new RGs created)

### Force Delete
When offboarding **with** `-ForceDeleteResourceGroups`:
- All Dynatrace resources **and** their resource groups are deleted
- Re-onboarding will need to create new RGs

### Offboard Discovery
The offboard action discovers Dynatrace resources dynamically:
- **Distributed**: Lists `Dynatrace.Observability/monitors` in the target RG by name or by enumerating
- **HybridCentralized**: Discovers batch monitors in anchor subscription RGs, removes monitored subscription links for member subs
- **Centralized**: Removes `monitoredSubscriptions` links and role assignments from the source monitor

## Policy Exemption for eastus
Create a management-group-level policy exemption allowing `Dynatrace.Observability` resources in `eastus`:

```powershell
New-AzPolicyExemption `
    -Name "dynatrace-ands-eastus-exemption" `
    -Scope "/providers/Microsoft.Management/managementGroups/<mg-id>" `
    -PolicyAssignment "<assignment-id>" `
    -ExemptionCategory "Waiver" `
    -DisplayName "Allow Dynatrace ANDS monitors in eastus" `
    -ResourceSelector @(@{
        Name = "dynatraceResources"
        Selectors = @(@{
            Kind = "resourceType"
            In = @("Dynatrace.Observability/monitors","Dynatrace.Observability/monitors/tagRules")
        })
    })
```

## Known Issue: "Environment is not linkable"
The error `"The environment: {id} is not linkable"` means the Dynatrace environment rejects new linked monitors. Root causes and fixes:

| Cause | Fix |
|-------|-----|
| Missing `planData`/`plan` in monitor PUT body | Script now copies these from the source monitor automatically |
| Source monitor was created as "new environment" (not via Marketplace) | Recreate the source monitor through Azure Marketplace with a proper plan |
| Dynatrace environment not configured for multi-sub linking | Contact Dynatrace support to enable linking for the environment |
| Ingestion key is invalid or expired | Generate a new API token in Dynatrace (Apps > Access tokens > Clone) and update `config.json` |
| Environment has reached its linking limit | Contact Dynatrace support to increase the limit |

## Minimizing Resource Groups
- **HybridCentralized** creates only `ceil(N/15)` RGs (best option pre-DAC)
- Point `target_resource_group_name` at an existing RG in each anchor subscription to create **zero new RGs**
- After DAC launch: consolidate to 1 monitor = 0-1 RGs total

## Resumability
- State file (`onboarding-state.json`) tracks each subscription as `Completed` or `Failed`
- On re-run, completed subs are skipped; failed subs are retried
- HybridCentralized and sequential mode: saves state **after each subscription** (crash-safe)
- Parallel mode: saves state after the full batch; on crash mid-batch, unsaved subs retry on next run
- Use `-ResetState` to clear state and start fresh
- **Important**: Use `-ResetState` when switching between Onboard and Offboard actions

## Running the Script

```powershell
# HybridCentralized onboard (recommended for 300+ subs)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -DryRun
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized

# Distributed onboard (1 monitor per sub)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed -ThrottleLimit 10

# Resume after interruption
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized

# Start fresh
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -ResetState

# Offboard (keep RGs for reuse)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode HybridCentralized -ResetState

# Offboard and delete RGs
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode Distributed -ForceDeleteResourceGroups -ResetState
```

## Troubleshooting Interruptions
When the script is interrupted, check:
1. `onboarding-state.json` — how many subs completed vs failed
2. Azure Activity Log — filter by `Dynatrace.Observability/monitors/write` for provisioning failures
3. Re-run the same command — completed subs are automatically skipped
