<#
.SYNOPSIS
    Manages ANDS tag rules to exclude/include resources from Dynatrace log shipment.

.DESCRIPTION
    Updates Azure Native Dynatrace Service (ANDS) monitor tag rules to add or remove
    filtering tags (Exclude/Include) for log and metric shipment. Supports:

    1. Resource-level LOG exclusion via filtering tags (match Azure resource tags)
    2. Resource-level METRIC exclusion via filtering tags (match Azure resource tags)
    3. Subscription-level log disable (sendActivityLogs/sendSubscriptionLogs off)
    4. Metric shipment disable/enable at the monitor level (sendingMetrics off/on)

    Discovers monitors based on Mode (Centralized, HybridCentralized, Distributed),
    reads existing tag rules, merges changes (additive for exclusions, preserves
    existing rules), and PUTs the updated tag rules back.

.PARAMETER ConfigFile
    Path to a JSON config file (same format as Invoke-DynatraceOnboarding.ps1).

.PARAMETER Mode
    "Centralized", "HybridCentralized", or "Distributed" — determines how monitors are discovered.

.PARAMETER RemoveLogs
    Switch to add an Exclude filtering tag to prevent log shipment for matching resources.

.PARAMETER RestoreLogs
    Switch to remove a previously added Exclude filtering tag (re-enables log shipment).

.PARAMETER DisableSubscriptionLogs
    Switch to disable sendActivityLogs and sendSubscriptionLogs at the subscription level.

.PARAMETER EnableSubscriptionLogs
    Switch to re-enable sendActivityLogs and sendSubscriptionLogs at the subscription level.

.PARAMETER RemoveMetrics
    Switch to add an Exclude filtering tag to prevent metric shipment for matching resources.

.PARAMETER RestoreMetrics
    Switch to remove a previously added Exclude metric filtering tag (re-enables metric shipment).

.PARAMETER DisableMetrics
    Switch to disable sendingMetrics on the monitor (stops all metric shipment).

.PARAMETER EnableMetrics
    Switch to re-enable sendingMetrics on the monitor.

.PARAMETER TagName
    The Azure resource tag key to match for filtering (used with -RemoveLogs/-RestoreLogs/-RemoveMetrics/-RestoreMetrics).

.PARAMETER TagValue
    The Azure resource tag value to match. Use "*" for any value. Default: "*".

.PARAMETER SubscriptionFilter
    Regex filter to target specific subscriptions by name.

.PARAMETER DryRun
    Preview changes without applying them.

.EXAMPLE
    # Exclude resources tagged env=dev from log shipment (all subs, Distributed)
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -RemoveLogs -TagName "env" -TagValue "dev"

.EXAMPLE
    # Re-include resources tagged env=dev (remove the exclusion)
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -RestoreLogs -TagName "env" -TagValue "dev"

.EXAMPLE
    # Disable subscription-level logs for a specific sub
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -DisableSubscriptionLogs -SubscriptionFilter "Subscription 1"

.EXAMPLE
    # Dry run — preview what would change
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -RemoveLogs -TagName "team" -TagValue "infra" -DryRun

.EXAMPLE
    # Exclude resources tagged env=dev from METRIC shipment
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -RemoveMetrics -TagName "env" -TagValue "dev"

.EXAMPLE
    # Exclude a tag from BOTH logs and metrics in one run
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -RemoveLogs -RemoveMetrics -TagName "env" -TagValue "dev"

.EXAMPLE
    # Disable all metric shipment for sandbox subscriptions
    .\Invoke-DynatraceOnboarding-LoggingRules.ps1 -ConfigFile .\config.json -Mode Distributed -DisableMetrics -SubscriptionFilter "sandbox"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [ValidateSet("Centralized", "HybridCentralized", "Distributed")]
    [string]$Mode = "Distributed",

    [switch]$RemoveLogs,
    [switch]$RestoreLogs,
    [switch]$DisableSubscriptionLogs,
    [switch]$EnableSubscriptionLogs,

    [switch]$RemoveMetrics,
    [switch]$RestoreMetrics,
    [switch]$DisableMetrics,
    [switch]$EnableMetrics,

    [string]$TagName = "",
    [string]$TagValue = "*",

    [string]$SubscriptionFilter = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ScriptVersion = "2026-08-26.1"

###############################################################################
# Validation
###############################################################################

if ($RemoveLogs -and $RestoreLogs) {
    throw "Cannot use both -RemoveLogs and -RestoreLogs at the same time."
}
if ($RemoveMetrics -and $RestoreMetrics) {
    throw "Cannot use both -RemoveMetrics and -RestoreMetrics at the same time."
}
if ($DisableSubscriptionLogs -and $EnableSubscriptionLogs) {
    throw "Cannot use both -DisableSubscriptionLogs and -EnableSubscriptionLogs at the same time."
}
if ($DisableMetrics -and $EnableMetrics) {
    throw "Cannot use both -DisableMetrics and -EnableMetrics at the same time."
}
if (($RemoveLogs -or $RestoreLogs -or $RemoveMetrics -or $RestoreMetrics) -and -not $TagName) {
    throw "-TagName is required when using -RemoveLogs, -RestoreLogs, -RemoveMetrics, or -RestoreMetrics."
}
if (-not ($RemoveLogs -or $RestoreLogs -or $DisableSubscriptionLogs -or $EnableSubscriptionLogs -or $RemoveMetrics -or $RestoreMetrics -or $DisableMetrics -or $EnableMetrics)) {
    throw "Must specify at least one action: -RemoveLogs, -RestoreLogs, -RemoveMetrics, -RestoreMetrics, -DisableSubscriptionLogs, -EnableSubscriptionLogs, -DisableMetrics, or -EnableMetrics."
}

###############################################################################
# Helpers
###############################################################################

$script:scriptTimer = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Phase([string]$Message) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Write-Step([string]$Sub, [string]$Msg)  { Write-Host "  [$Sub] $Msg" -ForegroundColor White }
function Write-OK([string]$Sub, [string]$Msg)    { Write-Host "  [$Sub] + $Msg" -ForegroundColor Green }
function Write-Skip([string]$Sub, [string]$Msg)  { Write-Host "  [$Sub] - $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Sub, [string]$Msg)   { Write-Host "  [$Sub] X $Msg" -ForegroundColor Red }

function Get-AzBearerToken {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    else {
        $token = $tokenResponse.Token
    }
    return $token
}

function Invoke-ArmApi {
    param([string]$Method, [string]$Url, [object]$Body = $null, [int]$MaxRetries = 5)

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $token   = Get-AzBearerToken
            $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
            $params  = @{ Method = $Method; Uri = $Url; Headers = $headers }
            if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 20 -Compress) }
            return (Invoke-RestMethod @params)
        }
        catch {
            $errMsg = $_.ToString()
            $statusCode = $null
            $resp = $null
            try { $resp = $_.Exception.Response } catch {}
            if ($resp) {
                try { $statusCode = [int]$resp.StatusCode } catch {}
            }

            $retryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600) -or ($errMsg -match "throttl|Too Many Requests|RetryAfter|ServiceUnavailable|GatewayTimeout")

            if ($retryable -and $attempt -le $MaxRetries) {
                $waitSeconds = [math]::Min(10 * [math]::Pow(2, $attempt - 1), 300)
                try {
                    if ($resp.Headers -and $resp.Headers["Retry-After"]) {
                        $retryAfter = [int]$resp.Headers["Retry-After"]
                        $waitSeconds = [math]::Max($waitSeconds, $retryAfter)
                    }
                } catch {}
                Write-Host "    ARM throttle/transient (attempt $attempt/$MaxRetries), waiting ${waitSeconds}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $waitSeconds
                continue
            }
            throw
        }
    }
}

###############################################################################
# Phase 1: Load config + verify connection
###############################################################################

Write-Host "Loading config: $ConfigFile" -ForegroundColor Gray
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$sourceSubId   = $config.dynatrace_subscription_id
$sourceRg      = $config.dynatrace_resource_group_name
$sourceMonitor = $config.dynatrace_monitor_name
$targetRg      = $config.target_resource_group_name
$resourcePrefix = $config.resource_name_prefix

Write-Phase "Phase 1: Verify Azure Connection"

$ctx = Get-AzContext
if (-not $ctx) { throw "Not logged in. Run Connect-AzAccount first." }
Write-Host "  Connected as: $($ctx.Account.Id)" -ForegroundColor White
Write-Host "  Tenant:       $($ctx.Tenant.Id)" -ForegroundColor White
$activeActions = @()
if ($RemoveLogs)               { $activeActions += "RemoveLogs (Exclude tag on logs)" }
if ($RestoreLogs)              { $activeActions += "RestoreLogs (Remove Exclude tag on logs)" }
if ($RemoveMetrics)            { $activeActions += "RemoveMetrics (Exclude tag on metrics)" }
if ($RestoreMetrics)           { $activeActions += "RestoreMetrics (Remove Exclude tag on metrics)" }
if ($DisableSubscriptionLogs)  { $activeActions += "DisableSubscriptionLogs" }
if ($EnableSubscriptionLogs)   { $activeActions += "EnableSubscriptionLogs" }
if ($DisableMetrics)           { $activeActions += "DisableMetrics (sendingMetrics=Disabled)" }
if ($EnableMetrics)            { $activeActions += "EnableMetrics (sendingMetrics=Enabled)" }
Write-Host "  Action:       $($activeActions -join ', ')" -ForegroundColor White
if ($TagName) {
    $tagAction = if ($RemoveLogs -or $RemoveMetrics) { 'Exclude' } else { 'Remove Exclude' }
    Write-Host "  Tag filter:   $TagName = $TagValue (action: $tagAction)" -ForegroundColor White
}
Write-Host "  Mode:         $Mode" -ForegroundColor White
Write-Host "  Script ver:   $script:ScriptVersion" -ForegroundColor White
if ($DryRun) { Write-Host "  ** DRY RUN — no changes will be made **" -ForegroundColor Yellow }

###############################################################################
# Phase 2: Discover subscriptions and their monitors
###############################################################################

Write-Phase "Phase 2: Discover Subscriptions & Monitors"

# Get all subs in tenant
$allSubs = Get-AzSubscription -TenantId $ctx.Tenant.Id | Where-Object { $_.State -eq "Enabled" }
Write-Host "  Found $($allSubs.Count) enabled subscription(s)" -ForegroundColor White

# Exclude source subscription
$targetSubs = @($allSubs | Where-Object { $_.Id -ne $sourceSubId })
Write-Host "  Excluding source subscription: $($targetSubs.Count) remaining" -ForegroundColor White

# Apply subscription filter
if ($SubscriptionFilter) {
    $targetSubs = @($targetSubs | Where-Object { $_.Name -match $SubscriptionFilter })
    Write-Host "  After filter '$SubscriptionFilter': $($targetSubs.Count) subscription(s)" -ForegroundColor White
}

# Also apply config-level filter
$cfgFilter = if ($config.subscription_filter) { $config.subscription_filter } else { "" }
if ($cfgFilter) {
    $targetSubs = @($targetSubs | Where-Object { $_.Name -match $cfgFilter })
    Write-Host "  After config filter '$cfgFilter': $($targetSubs.Count) subscription(s)" -ForegroundColor White
}

if ($targetSubs.Count -eq 0) {
    Write-Host "  No subscriptions match filters. Nothing to do." -ForegroundColor Yellow
    exit 0
}

###############################################################################
# Phase 3: Build monitor-to-subscription map
###############################################################################

Write-Phase "Phase 3: Resolve Tag Rules Endpoints"

$monitorTargets = @()  # Array of @{ SubscriptionName; SubscriptionId; TagRulesUrl }

switch ($Mode) {
    "Distributed" {
        foreach ($sub in $targetSubs) {
            $sName = $sub.Name
            $sId   = $sub.Id
            # Sanitize name same way as the onboarding script
            $safeName = ($sName -replace '[^a-zA-Z0-9\-]', '-').TrimEnd('-')
            $resName  = "$resourcePrefix-$safeName"
            $trUrl    = "https://management.azure.com/subscriptions/$sId/resourceGroups/$targetRg/providers/Dynatrace.Observability/monitors/${resName}/tagRules/default?api-version=2024-04-24"
            $monitorTargets += @{
                SubscriptionName = $sName
                SubscriptionId   = $sId
                TagRulesUrl      = $trUrl
                MonitorName      = $resName
            }
        }
    }
    "Centralized" {
        # Single source monitor covers all subs
        $trUrl = "https://management.azure.com/subscriptions/$sourceSubId/resourceGroups/$sourceRg/providers/Dynatrace.Observability/monitors/$sourceMonitor/tagRules/default?api-version=2024-04-24"
        $monitorTargets += @{
            SubscriptionName = "(All — source monitor)"
            SubscriptionId   = $sourceSubId
            TagRulesUrl      = $trUrl
            MonitorName      = $sourceMonitor
        }
    }
    "HybridCentralized" {
        # Discover batch monitors in target subscriptions
        foreach ($sub in $targetSubs) {
            $sId = $sub.Id
            $sName = $sub.Name
            # Try to find monitors in the target RG
            $listUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$targetRg/providers/Dynatrace.Observability/monitors?api-version=2024-04-24"
            try {
                $monitors = Invoke-ArmApi -Method "GET" -Url $listUrl
                if ($monitors.value -and $monitors.value.Count -gt 0) {
                    foreach ($mon in $monitors.value) {
                        $monName = $mon.name
                        $trUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$targetRg/providers/Dynatrace.Observability/monitors/$monName/tagRules/default?api-version=2024-04-24"
                        $monitorTargets += @{
                            SubscriptionName = $sName
                            SubscriptionId   = $sId
                            TagRulesUrl      = $trUrl
                            MonitorName      = $monName
                        }
                    }
                }
            }
            catch {
                # RG or provider not found in this sub — skip
            }
        }
        # Also check source monitor for any centralized-linked subs
        $trUrl = "https://management.azure.com/subscriptions/$sourceSubId/resourceGroups/$sourceRg/providers/Dynatrace.Observability/monitors/$sourceMonitor/tagRules/default?api-version=2024-04-24"
        $monitorTargets += @{
            SubscriptionName = "(Source monitor)"
            SubscriptionId   = $sourceSubId
            TagRulesUrl      = $trUrl
            MonitorName      = $sourceMonitor
        }
    }
}

# Deduplicate by TagRulesUrl
$monitorTargets = $monitorTargets | Sort-Object { $_.TagRulesUrl } -Unique

Write-Host "  Discovered $($monitorTargets.Count) monitor tag rule endpoint(s)" -ForegroundColor White
foreach ($m in $monitorTargets) {
    Write-Host "    - $($m.MonitorName) ($($m.SubscriptionName))" -ForegroundColor Gray
}

###############################################################################
# Phase 4: Apply tag rule changes
###############################################################################

Write-Phase "Phase 4: Apply Tag Rule Changes"

$results = @()

foreach ($target in $monitorTargets) {
    $label = "$($target.MonitorName) ($($target.SubscriptionName))"
    $trUrl = $target.TagRulesUrl

    $result = [PSCustomObject]@{
        MonitorName      = $target.MonitorName
        SubscriptionName = $target.SubscriptionName
        SubscriptionId   = $target.SubscriptionId
        Action           = ""
        Status           = "Skipped"
        Error            = $null
    }

    try {
        # Read current tag rules
        Write-Step $label "Reading current tag rules..."
        $currentTR = $null
        try { $currentTR = Invoke-ArmApi -Method "GET" -Url $trUrl }
        catch {
            if ($_.ToString() -match "NotFound|ResourceNotFound") {
                Write-Skip $label "Tag rules not found (monitor may not exist)"
                $result.Status = "NotFound"
                $results += $result
                continue
            }
            throw
        }

        $logRules    = $currentTR.properties.logRules
        $metricRules = $currentTR.properties.metricRules
        $needsUpdate = $false

        # Get current log filtering tags (handle null/missing)
        $currentLogFilterTags = @()
        if ($logRules -and $logRules.filteringTags) {
            $currentLogFilterTags = @($logRules.filteringTags)
        }

        # Get current metric filtering tags and sendingMetrics state (handle null/missing)
        $currentMetricFilterTags = @()
        if ($metricRules -and $metricRules.filteringTags) {
            $currentMetricFilterTags = @($metricRules.filteringTags)
        }
        $currentSendingMetrics = if ($metricRules -and $metricRules.sendingMetrics) { $metricRules.sendingMetrics } else { "Enabled" }

        # --- Resource-level: Add/Remove Exclude filtering tag ---
        if ($RemoveLogs) {
            $result.Action = "Exclude tag: $TagName=$TagValue"

            # Check if tag already exists
            $existing = $currentLogFilterTags | Where-Object { $_.name -eq $TagName -and $_.value -eq $TagValue -and $_.action -eq "Exclude" }
            if ($existing) {
                Write-Skip $label "Exclude tag '$TagName=$TagValue' already present"
                $result.Status = "AlreadyExists"
            }
            else {
                $newTag = @{ name = $TagName; value = $TagValue; action = "Exclude" }
                $currentLogFilterTags += $newTag
                $needsUpdate = $true
                Write-Step $label "Adding Exclude tag: $TagName=$TagValue"
            }
        }
        elseif ($RestoreLogs) {
            $result.Action = "Remove Exclude tag: $TagName=$TagValue"

            $before = $currentLogFilterTags.Count
            $currentLogFilterTags = @($currentLogFilterTags | Where-Object {
                -not ($_.name -eq $TagName -and $_.value -eq $TagValue -and $_.action -eq "Exclude")
            })
            if ($currentLogFilterTags.Count -lt $before) {
                $needsUpdate = $true
                Write-Step $label "Removing Exclude tag: $TagName=$TagValue"
            }
            else {
                Write-Skip $label "Exclude tag '$TagName=$TagValue' not found — nothing to remove"
                $result.Status = "NotFound"
            }
        }

        # --- Resource-level (Metrics): Add/Remove Exclude filtering tag ---
        if ($RemoveMetrics) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Exclude metric tag: $TagName=$TagValue"

            $existingMetric = $currentMetricFilterTags | Where-Object { $_.name -eq $TagName -and $_.value -eq $TagValue -and $_.action -eq "Exclude" }
            if ($existingMetric) {
                Write-Skip $label "Metric Exclude tag '$TagName=$TagValue' already present"
                if (-not $needsUpdate) { $result.Status = "AlreadyExists" }
            }
            else {
                $currentMetricFilterTags += @{ name = $TagName; value = $TagValue; action = "Exclude" }
                $needsUpdate = $true
                Write-Step $label "Adding metric Exclude tag: $TagName=$TagValue"
            }
        }
        elseif ($RestoreMetrics) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Remove metric Exclude tag: $TagName=$TagValue"

            $beforeMetric = $currentMetricFilterTags.Count
            $currentMetricFilterTags = @($currentMetricFilterTags | Where-Object {
                -not ($_.name -eq $TagName -and $_.value -eq $TagValue -and $_.action -eq "Exclude")
            })
            if ($currentMetricFilterTags.Count -lt $beforeMetric) {
                $needsUpdate = $true
                Write-Step $label "Removing metric Exclude tag: $TagName=$TagValue"
            }
            else {
                Write-Skip $label "Metric Exclude tag '$TagName=$TagValue' not found — nothing to remove"
                if (-not $needsUpdate) { $result.Status = "NotFound" }
            }
        }

        # --- Subscription-level: Disable/Enable activity + subscription logs ---
        if ($DisableSubscriptionLogs) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Disable sub logs"
            if ($logRules.sendActivityLogs -eq "Disabled" -and $logRules.sendSubscriptionLogs -eq "Disabled") {
                Write-Skip $label "Subscription logs already disabled"
                if (-not $needsUpdate) { $result.Status = "AlreadyDisabled" }
            }
            else {
                $logRules.sendActivityLogs = "Disabled"
                $logRules.sendSubscriptionLogs = "Disabled"
                $needsUpdate = $true
                Write-Step $label "Disabling sendActivityLogs + sendSubscriptionLogs"
            }
        }
        elseif ($EnableSubscriptionLogs) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Enable sub logs"
            if ($logRules.sendActivityLogs -eq "Enabled" -and $logRules.sendSubscriptionLogs -eq "Enabled") {
                Write-Skip $label "Subscription logs already enabled"
                if (-not $needsUpdate) { $result.Status = "AlreadyEnabled" }
            }
            else {
                $logRules.sendActivityLogs = "Enabled"
                $logRules.sendSubscriptionLogs = "Enabled"
                $needsUpdate = $true
                Write-Step $label "Enabling sendActivityLogs + sendSubscriptionLogs"
            }
        }

        # --- Metric-level: Disable/Enable sendingMetrics globally ---
        if ($DisableMetrics) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Disable metrics"
            if ($currentSendingMetrics -eq "Disabled") {
                Write-Skip $label "Metrics already disabled"
                if (-not $needsUpdate) { $result.Status = "AlreadyDisabled" }
            }
            else {
                $currentSendingMetrics = "Disabled"
                $needsUpdate = $true
                Write-Step $label "Disabling sendingMetrics"
            }
        }
        elseif ($EnableMetrics) {
            $result.Action += $(if ($result.Action) { " + " } else { "" }) + "Enable metrics"
            if ($currentSendingMetrics -eq "Enabled") {
                Write-Skip $label "Metrics already enabled"
                if (-not $needsUpdate) { $result.Status = "AlreadyEnabled" }
            }
            else {
                $currentSendingMetrics = "Enabled"
                $needsUpdate = $true
                Write-Step $label "Enabling sendingMetrics"
            }
        }

        # --- PUT updated tag rules ---
        if ($needsUpdate) {
            $trBody = @{
                properties = @{
                    logRules = @{
                        sendActivityLogs     = $logRules.sendActivityLogs
                        sendSubscriptionLogs = $logRules.sendSubscriptionLogs
                        filteringTags        = if (@($currentLogFilterTags).Count -gt 0) { @($currentLogFilterTags) } else { ,@() }
                    }
                    metricRules = @{
                        sendingMetrics = $currentSendingMetrics
                        filteringTags  = if (@($currentMetricFilterTags).Count -gt 0) { @($currentMetricFilterTags) } else { ,@() }
                    }
                }
            }

            if ($DryRun) {
                Write-Host "    [DRY RUN] Would PUT:" -ForegroundColor Yellow
                Write-Host "    $($trBody | ConvertTo-Json -Depth 10 -Compress)" -ForegroundColor DarkGray
                $result.Status = "DryRun"
            }
            else {
                Invoke-ArmApi -Method "PUT" -Url $trUrl -Body $trBody | Out-Null
                Write-OK $label "Tag rules updated"
                $result.Status = "Updated"
            }
        }
    }
    catch {
        Write-Err $label "Error: $_"
        $result.Error = $_.ToString()
        $result.Status = "Failed"
    }

    $results += $result
}

###############################################################################
# Phase 5: Summary
###############################################################################

Write-Phase "Phase 5: Summary"

$results | Format-Table MonitorName, SubscriptionName, Action, Status, Error -AutoSize

$updated = @($results | Where-Object { $_.Status -eq "Updated" }).Count
$skipped = @($results | Where-Object { $_.Status -match "Already|NotFound|Skipped" }).Count
$failed  = @($results | Where-Object { $_.Status -eq "Failed" }).Count
$dryRuns = @($results | Where-Object { $_.Status -eq "DryRun" }).Count

Write-Host ""
Write-Host "  Script version:   $script:ScriptVersion" -ForegroundColor White
Write-Host "  Total monitors:   $($results.Count)" -ForegroundColor White
Write-Host "  Updated:          $updated" -ForegroundColor Green
Write-Host "  Already correct:  $skipped" -ForegroundColor Yellow
Write-Host "  Failed:           $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "White" })
if ($dryRuns -gt 0) { Write-Host "  Dry run:          $dryRuns" -ForegroundColor Yellow }
Write-Host "  Total elapsed:    $($script:scriptTimer.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor DarkGray
Write-Host ""

# Return results for pipeline usage
$results
