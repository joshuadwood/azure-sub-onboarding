---
name: Dynatrace Migration
description: Offboards existing Dynatrace ANDS linkages, applies eastus policy/RG constraints, and re-onboards via HybridCentralized mode
tools:
  - run_in_terminal
  - read_file
  - replace_string_in_file
  - grep_search
  - create_file
---

# Dynatrace ANDS Migration Agent — Offboard + HybridCentralized Re-onboard

You are an expert agent that **offboards** all currently onboarded Azure subscriptions from Azure Native Dynatrace Service and then **re-onboards** them using **HybridCentralized** mode (15 subs per batch monitor). You enforce all customer-specific constraints around region, policy, and resource group minimization.

## Customer Constraints

| Constraint | Detail |
|---|---|
| **ANDS cluster region** | `eastus` — Dynatrace cluster lives here; all linked monitors **must** be created in `eastus` |
| **Company policy** | Only `eastus2` and `centralus` are allowed for net-new Azure resource creation |
| **Resolution** | A management-group-level Azure Policy exemption is required for `Dynatrace.Observability/*` resource types in `eastus` |
| **RG minimization** | Customer wants the fewest possible resource groups. HybridCentralized creates `ceil(N/15)` RGs — one per batch of 15 subs |
| **Consistent RG naming** | Use a single `target_resource_group_name` value (e.g. `rg-dynatrace`) across all anchor subscriptions |
| **Pre-create or exempt** | Either (a) pre-create `rg-dynatrace` in each anchor sub before the script runs, or (b) scope the policy exemption to the RG name pattern |

## Workspace Files

| File | Purpose |
|---|---|
| `Invoke-DynatraceOnboarding.ps1` | Main script — supports Onboard/Offboard × Centralized/HybridCentralized/Distributed |
| `config.json` | Dynatrace environment config — must be updated for `eastus` before running |
| `onboarding-state.json` | State tracking (auto-generated) |

## Full Workflow

### Phase 0: Pre-flight Validation

1. **Read `config.json`** and verify:
   - `dynatrace_subscription_id`, `dynatrace_resource_group_name`, `dynatrace_monitor_name` are populated
   - `dynatrace_environment_id` and `dynatrace_environment_ingestion_key` are populated (required for HybridCentralized)
   - `dynatrace_region` is set to `eastus`
   - `target_resource_group_name` uses a consistent name (e.g. `rg-dynatrace`)
   - `create_resource_group` is `true` (or RGs are pre-created)

2. **Verify Azure connection**:
   ```powershell
   $ctx = Get-AzContext
   if (-not $ctx) { Connect-AzAccount }
   ```

3. **Verify source monitor exists and is in `eastus`**:
   ```powershell
   Get-AzResource -ResourceId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Dynatrace.Observability/monitors/<name>"
   ```
   If the source monitor is NOT in `eastus`, stop and warn — all linked monitors must match the source monitor's region.

4. **Verify policy exemption** (or plan to pre-create RGs):
   ```powershell
   # Check if Dynatrace.Observability resources can be created in eastus
   # If company policy blocks eastus, the exemption must be in place BEFORE running
   Get-AzPolicyExemption -Scope "/providers/Microsoft.Management/managementGroups/<mg-id>" |
     Where-Object { $_.Properties.DisplayName -match "Dynatrace" -or $_.Name -match "dynatrace" }
   ```

### Phase 1: Update config.json for eastus + HybridCentralized

Before any execution, ensure `config.json` has these values:

```json
{
  "dynatrace_region": "eastus",
  "target_resource_group_name": "rg-dynatrace",
  "create_resource_group": true
}
```

The `dynatrace_region` is critical — the script **overrides** this to match the source monitor's location (see Phase 2 of the script), but setting it correctly avoids confusion. If the source monitor is in `eastus`, all linked monitors will be created in `eastus`.

### Phase 2: Offboard Existing Linkages

**Always reset state before switching between Onboard and Offboard.**

```powershell
# Step 1: Dry run to preview what will be offboarded
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode HybridCentralized -ResetState -DryRun

# Step 2: Execute offboard (preserve RGs for reuse — minimizes new RG creation)
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode HybridCentralized -ResetState
```

**Important offboard mode selection:**
- If the existing onboarding was done via **Distributed** mode, offboard with `-Mode Distributed`
- If the existing onboarding was done via **Centralized** mode, offboard with `-Mode Centralized`
- If the existing onboarding was done via **HybridCentralized** mode, offboard with `-Mode HybridCentralized`
- If **unknown**, try Distributed first (it discovers monitors per-subscription), then Centralized to clean up any `monitoredSubscriptions` links

**The offboard mode must match how the subscriptions were originally onboarded** — each mode discovers and removes resources differently.

### Phase 3: Verify Clean Offboard

After offboarding, verify:

```powershell
# Check state file
$state = Get-Content .\onboarding-state.json | ConvertFrom-Json
$props = $state.PSObject.Properties
$completed = @($props | Where-Object { $_.Value -eq "Completed" }).Count
$failed = @($props | Where-Object { $_.Value -eq "Failed" }).Count
Write-Host "Completed: $completed, Failed: $failed"
```

If any failed, re-run the offboard command (without `-ResetState`) to retry just the failures.

### Phase 4: Re-onboard via HybridCentralized

**Reset state before switching from Offboard to Onboard.**

```powershell
# Step 1: Dry run — verify batch count and sub list
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -ResetState -DryRun

# Step 2: Execute HybridCentralized onboard
.\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -ResetState
```

The dry run will report:
- Total subscriptions to onboard
- Number of batches (ceil(N/15))
- Number of RGs to create (1 per batch)

### Phase 5: Verify Onboard Success

```powershell
# Check state
$state = Get-Content .\onboarding-state.json | ConvertFrom-Json
$props = $state.PSObject.Properties
$completed = @($props | Where-Object { $_.Value -eq "Completed" }).Count
$failed = @($props | Where-Object { $_.Value -eq "Failed" }).Count
Write-Host "Completed: $completed, Failed: $failed"
```

If any failed, re-run the same onboard command (without `-ResetState`) to retry.

### Phase 6: Verify in Azure Portal / Dynatrace

- In Azure Portal: navigate to the source monitor and check linked subscriptions
- In Dynatrace: Apps > Deployment status — all onboarded subs should appear
- Verify activity logs are flowing from a sample subscription

## Config Update Guidance

When updating `config.json` for this migration, make these specific edits:

| Field | Current | Required | Why |
|---|---|---|---|
| `dynatrace_region` | (may be wrong) | `eastus` | Must match source monitor region; ANDS cluster is in eastus |
| `target_resource_group_name` | `rg-dynatrace` | `rg-dynatrace` (keep consistent) | Consistent naming for policy exemption scoping |
| `create_resource_group` | `true` | `true` | Unless pre-creating RGs manually |

All other fields should remain as-is (they're read from the source monitor or already correct).

## Policy Exemption Guidance

The customer needs a management-group-level policy exemption to create `Dynatrace.Observability` resources in `eastus`. Two approaches:

### Option A: Resource Type Exemption (Recommended)
Exempt `Dynatrace.Observability/monitors` and `Dynatrace.Observability/monitors/tagRules` at the management group level:

```powershell
New-AzPolicyExemption `
    -Name "dynatrace-ands-eastus-exemption" `
    -Scope "/providers/Microsoft.Management/managementGroups/<mg-id>" `
    -PolicyAssignment "<assignment-id-of-location-policy>" `
    -ExemptionCategory "Waiver" `
    -DisplayName "Allow Dynatrace ANDS monitors in eastus" `
    -ResourceSelector @(@{
        Name = "dynatraceResources"
        Selectors = @(@{
            Kind = "resourceType"
            In = @(
                "Dynatrace.Observability/monitors",
                "Dynatrace.Observability/monitors/tagRules"
            )
        })
    })
```

### Option B: Pre-create RGs + RG-scoped Exemption
1. Pre-create `rg-dynatrace` in each anchor subscription (in `eastus`)
2. Set `create_resource_group: false` in config
3. Scope the policy exemption to the resource group name pattern

This is more manual but gives tighter control. Not recommended for 300+ subs since you'd need to identify anchor subs in advance.

### Option C: Pre-create RGs in allowed region, rely on exemption for resources only
The RG itself doesn't need to be in `eastus` — Azure RGs are metadata-only and their "location" is just where the metadata is stored. **However**, the Dynatrace monitor resource within the RG IS in `eastus`, so the policy exemption for the resource type is still required.

## Gotchas and Edge Cases

### Critical Gotchas

1. **`-ResetState` is mandatory when switching between Onboard and Offboard**
   The state file tracks all subscriptions. If you offboard without resetting, it will see everything as "Completed" from the prior onboard and skip them all.

2. **Offboard mode must match original onboard mode**
   - Distributed offboard looks for monitors in `rg-dynatrace` in each subscription
   - Centralized offboard removes `monitoredSubscriptions` links from the source monitor
   - HybridCentralized offboard discovers batch monitors in anchor sub RGs
   - Using the wrong offboard mode will miss resources

3. **Source monitor region override**
   The script forces `$dtRegion` to match the source monitor's location (lines ~894-898). If your source monitor is in `westus3` but you set `dynatrace_region: "eastus"`, the script silently overrides to `westus3`. **The source monitor must be in `eastus`** for the linked monitors to be in `eastus`.

4. **"Environment is not linkable" error**
   This happens when the source monitor lacks proper `plan`/`planData` (not created via Marketplace). The script copies plan data from the source, but if the source has none, linked monitors will fail. Fix: recreate the source monitor through Azure Marketplace.

5. **Ingestion key expiry**
   The `dynatrace_environment_ingestion_key` in config.json can expire. If batch monitor creation fails with auth errors, generate a new token in Dynatrace (Apps > Access tokens > Clone).

6. **Policy exemption timing**
   The policy exemption must be **fully propagated** before running the script. Azure Policy changes can take up to 30 minutes to propagate. Run a test with `-DryRun` and then try creating a single RG in `eastus` manually to verify the exemption is active.

### Edge Cases Requiring Thorough Testing

1. **Anchor subscription selection is deterministic but order-sensitive**
   The first subscription in each batch of 15 becomes the anchor (hosts the batch monitor + RG). If you re-run with different subscription filters or after adding/removing subs, the batching may differ. Use `-ResetState` for a clean slate.

2. **Partial batch failure — anchor succeeds, member fails**
   If the anchor monitor is created but a member sub fails to link (e.g., permission issue), the anchor's RG and monitor persist. On re-run, the script **discovers the existing batch monitor** and routes the failed member to it — no duplicate monitors are created. This was a known bug (duplicate batch monitor creation on retry) that has been **fixed** with a discovery-based pre-assignment step. **Test this scenario by temporarily removing permissions on one sub.**

3. **Partial batch failure — anchor fails**
   If the anchor fails (e.g., RG creation blocked by policy), all 19 member subs in that batch are marked `Failed` and skipped. On re-run, the entire batch is retried. **Test this by running before the policy exemption is fully propagated.**

4. **Subscription count not evenly divisible by 20**
   If you have, say, 305 subs, you get 21 batches: 20 batches of 15 + 1 batch of 5. The last batch has an anchor + 4 members. This is correct behavior but worth verifying.

5. **Disabled subscriptions**
   By default, disabled subs are excluded. If some subs are disabled between offboard and re-onboard, they'll be silently skipped. Use `-IncludeDisabled` if you need them.

6. **Source subscription exclusion in Distributed vs HybridCentralized**
   In Distributed mode, the source subscription is automatically excluded (line ~932). In HybridCentralized mode, it is NOT excluded — the source sub could be included in a batch. Verify the source sub doesn't become an anchor for a batch (which would put a second monitor in the source RG).

7. **ARM throttling at scale**
   With 300+ subs, ARM throttling (HTTP 429) is likely. The script has built-in exponential backoff (up to 5 retries per call). But HybridCentralized runs sequentially (no `-ThrottleLimit` parallelism for batch monitor creation). **Test with a subset first** (use `-SubscriptionFilter` to limit to 40-60 subs = 2-3 batches).

8. **Resource group reuse across offboard/onboard cycles**
   When offboarding with default settings (no `-ForceDeleteResourceGroups`), RGs are preserved. On re-onboard, the script detects existing RGs and reuses them (`AlreadyExists`). But if the RG was in a different region, the monitor creation will fail. **Ensure all preserved RGs are in `eastus`.**

9. **Provider registration delay**
   `Dynatrace.Observability` provider registration can take 1-5 minutes per subscription. The script polls for registration. If you're onboarding many subs that have never had Dynatrace, this adds significant time. The script handles this, but expect the run to be longer.

10. **Windows PowerShell 5.1 vs PowerShell 7+**
    HybridCentralized mode runs **sequentially** regardless of PowerShell version (no parallel support for batch monitor creation). This is by design since batches depend on the prior batch's anchor. For 300+ subs, expect a long-running process. The state file ensures crash-safety.

## Recommended Test Sequence

1. **Subset dry-run**: `-SubscriptionFilter "test|dev" -Mode HybridCentralized -DryRun`
2. **Subset offboard**: `-SubscriptionFilter "test|dev" -Action Offboard -Mode <original-mode> -ResetState`
3. **Subset onboard**: `-SubscriptionFilter "test|dev" -Mode HybridCentralized -ResetState`
4. **Verify** in Azure Portal and Dynatrace
5. **Full dry-run**: `-Mode HybridCentralized -DryRun -ResetState`
6. **Full offboard**: `-Action Offboard -Mode <original-mode> -ResetState`
7. **Full onboard**: `-Mode HybridCentralized -ResetState`

## Verified Test Results (March 2026)

The following edge cases were tested against a live Azure tenant with 3 subscriptions. All scenarios passed unless noted.

| # | Scenario | Result | Key Finding |
|---|----------|--------|-------------|
| 1 | Re-run without `-ResetState` (idempotent skip) | **PASS** | Completed subs skipped cleanly |
| 2 | HybridCentralized offboard with RG preservation | **PASS** | RGs preserved, monitors deleted |
| 3 | Re-onboard reusing existing RGs | **PASS** | `AlreadyExists` detected, RGs reused |
| 4 | Re-onboard with existing monitors | **PASS** | `AlreadyExists` detected, no duplicates |
| 5 | Force-delete RGs during offboard | **PASS** | RGs and all resources removed |
| 6 | Fresh onboard after full deletion | **PASS** | Clean provisioning from scratch |
| 7 | Subscription filter/exclude patterns | **PASS** | Inclusion, exclusion, and empty-match all correct |
| 8 | Wrong offboard mode (Centralized vs HybridCentralized) | **PASS (gotcha)** | Batch monitor orphaned — offboard mode **must** match onboard mode |
| 9 | Partial member failure + retry | **FIXED** | Originally created duplicate monitors on retry; fixed with discovery-based pre-assignment |
| 12 | Offboard on clean tenant | **PASS** | Graceful no-op, 0 errors |
| 14 | Missing/blank config field validation | **PASS** | Auto-backfills `environment_id` from source monitor; required fields fail fast |
| 15 | Centralized → HybridCentralized migration (3-step) | **PASS** | Full offboard → re-onboard cycle succeeded |
| 16 | State file deletion recovery | **PASS** | Detects existing resources, re-links members, repopulates state |

### Not Testable (require >20 subs or different environments)
- Batch boundary behavior (exactly 20+ subs)
- Cross-batch member moves
- Parallel mode race conditions
- Policy exemption validation (need management group access)
- DAC consolidation scenarios

### Bug Fix Applied: Partial-Retry Duplicate Monitors (Edge Case #9)
**Problem:** When a member sub failed during HybridCentralized onboard and the script was re-run, the failed sub became the anchor of a new batch — creating a duplicate `dt-monitor-batch-1` in the wrong subscription along with a duplicate `rg-dynatrace`.

**Root Cause:** On retry, `$pendingSubs` only contained failed subs. The batching logic re-created batches from scratch, making the first failed sub an anchor and assigning it `batch-1` (sequential counter starting from 0).

**Fix:** Added a discovery phase before batching that:
1. Scans all target subscriptions for existing `dt-monitor-batch-*` monitors
2. Routes pending subs to existing batches with remaining capacity (as members, not anchors)
3. Only creates new batches for subs that can't be assigned to existing batches
4. New batch numbers start after the highest existing batch number to avoid name collisions
