<#
.SYNOPSIS
    Audits all Distributed Dynatrace monitors for a null system-assigned managed identity.

.DESCRIPTION
    Read-only sweep. For every subscription in the tenant (optionally filtered), finds
    Dynatrace.Observability monitors in the target resource group and reports whether the
    monitor's system-assigned identity has a principalId and whether that identity has a
    Monitoring Reader role assignment.

    A null principalId is the root cause of the "Waiting for data..." / GatewayTimeout on
    "Gets Metric Status" issue. This script only REPORTS — it makes no changes. Use
    Invoke-DynatraceOnboarding.ps1 (v2026-07-10.1+) to remediate flagged monitors.

.PARAMETER ConfigFile
    Path to the same config.json used for onboarding.

.PARAMETER SubscriptionFilter
    Optional regex to limit the audit to specific subscription names.

.PARAMETER FlaggedOnly
    Only output monitors that are missing an identity or role assignment.

.EXAMPLE
    .\Audit-DynatraceMonitorIdentity.ps1 -ConfigFile .\config.json

.EXAMPLE
    .\Audit-DynatraceMonitorIdentity.ps1 -ConfigFile .\config.json -FlaggedOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [string]$SubscriptionFilter = "",
    [switch]$FlaggedOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Arm {
    param([string]$Method, [string]$Path)
    $r = Invoke-AzRestMethod -Method $Method -Path $Path
    return [PSCustomObject]@{ Status = $r.StatusCode; Content = $r.Content }
}

Write-Host "Loading config: $ConfigFile" -ForegroundColor Gray
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$sourceSubId    = $config.dynatrace_subscription_id
$targetRg       = $config.target_resource_group_name
$resourcePrefix = $config.resource_name_prefix
$cfgFilter      = if ($config.subscription_filter) { $config.subscription_filter } else { "" }

$ctx = Get-AzContext
if (-not $ctx) { throw "Not logged in. Run Connect-AzAccount first." }
Write-Host "Connected as: $($ctx.Account.Id)" -ForegroundColor White
Write-Host "Tenant:       $($ctx.Tenant.Id)" -ForegroundColor White

$allSubs = @(Get-AzSubscription -TenantId $ctx.Tenant.Id | Where-Object { $_.State -eq "Enabled" })
$targetSubs = @($allSubs | Where-Object { $_.Id -ne $sourceSubId })
if ($SubscriptionFilter) { $targetSubs = @($targetSubs | Where-Object { $_.Name -match $SubscriptionFilter }) }
if ($cfgFilter)          { $targetSubs = @($targetSubs | Where-Object { $_.Name -match $cfgFilter }) }

Write-Host "Auditing $($targetSubs.Count) subscription(s) for monitors in RG '$targetRg'..." -ForegroundColor White
Write-Host ""

$results = New-Object System.Collections.ArrayList

foreach ($sub in $targetSubs) {
    $sId   = $sub.Id
    $sName = $sub.Name

    # Enumerate Dynatrace monitors in the target RG for this sub
    $listPath = "/subscriptions/$sId/resourceGroups/$targetRg/providers/Dynatrace.Observability/monitors?api-version=2024-04-24"
    $list = $null
    try { $list = Invoke-Arm -Method GET -Path $listPath } catch { }

    if (-not $list -or $list.Status -ne 200) {
        [void]$results.Add([PSCustomObject]@{
            Subscription = $sName; Monitor = "(none)"; PrincipalId = ""; MonitoringReader = ""; ProvisioningState = ""; Flag = "NO MONITOR"
        })
        continue
    }

    $monitors = @()
    try { $monitors = @(($list.Content | ConvertFrom-Json).value) } catch {}
    if ($monitors.Count -eq 0) {
        [void]$results.Add([PSCustomObject]@{
            Subscription = $sName; Monitor = "(none)"; PrincipalId = ""; MonitoringReader = ""; ProvisioningState = ""; Flag = "NO MONITOR"
        })
        continue
    }

    foreach ($mon in $monitors) {
        $monName = $mon.name
        $monPid  = $null
        try { $monPid = $mon.identity.principalId } catch {}
        $provState = ""
        try { $provState = $mon.properties.provisioningState } catch {}

        # Check role assignment (only meaningful if an identity exists)
        $roleState = "N/A"
        if ($monPid) {
            try {
                Set-AzContext -SubscriptionId $sId -ErrorAction SilentlyContinue | Out-Null
                $ra = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $monPid -RoleDefinitionName "Monitoring Reader" -ErrorAction SilentlyContinue)
                $roleState = if ($ra.Count -gt 0) { "Yes" } else { "MISSING" }
            } catch { $roleState = "CHECK-FAILED" }
        }

        $flag = "OK"
        if (-not $monPid)            { $flag = "NULL IDENTITY" }
        elseif ($roleState -eq "MISSING") { $flag = "NO ROLE" }

        [void]$results.Add([PSCustomObject]@{
            Subscription      = $sName
            Monitor           = $monName
            PrincipalId       = if ($monPid) { $monPid } else { "(null)" }
            MonitoringReader  = $roleState
            ProvisioningState = $provState
            Flag              = $flag
        })
    }
}

$output = if ($FlaggedOnly) { $results | Where-Object { $_.Flag -ne "OK" } } else { $results }

Write-Host ""
$output | Format-Table -AutoSize -Property Subscription, Monitor, ProvisioningState, PrincipalId, MonitoringReader, Flag

$flagged = @($results | Where-Object { $_.Flag -eq "NULL IDENTITY" -or $_.Flag -eq "NO ROLE" })
$noMon   = @($results | Where-Object { $_.Flag -eq "NO MONITOR" })

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Total monitors checked: $(@($results | Where-Object { $_.Flag -ne 'NO MONITOR' }).Count)" -ForegroundColor White
Write-Host "  Null identity:          $(@($results | Where-Object { $_.Flag -eq 'NULL IDENTITY' }).Count)" -ForegroundColor $(if (@($results | Where-Object { $_.Flag -eq 'NULL IDENTITY' }).Count -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Missing Monitoring Reader: $(@($results | Where-Object { $_.Flag -eq 'NO ROLE' }).Count)" -ForegroundColor $(if (@($results | Where-Object { $_.Flag -eq 'NO ROLE' }).Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  Subs with no monitor:   $($noMon.Count)" -ForegroundColor Gray

if ($flagged.Count -gt 0) {
    Write-Host ""
    Write-Host "  Remediate flagged subs by re-running the onboarding script (v2026-07-10.1+):" -ForegroundColor Yellow
    Write-Host "    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile $ConfigFile -Action Onboard -Mode Distributed" -ForegroundColor Gray
    Write-Host "  (completed subs are skipped; force a retry for a specific sub with -SubscriptionFilter)" -ForegroundColor Gray
}

# Return objects for pipeline usage
$results
