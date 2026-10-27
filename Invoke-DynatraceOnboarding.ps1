<#
.SYNOPSIS
    Onboards or offboards Azure subscriptions to/from an Azure Native Dynatrace Service environment.

.DESCRIPTION
    Auto-discovers Azure subscriptions and onboards or offboards each to/from
    a Dynatrace SaaS environment. Supports three modes:

    -Mode Centralized       (monitoredSubscriptions, max 20 subs per monitor)
    -Mode HybridCentralized (auto-batches into groups of 15, one monitor per batch)
    -Mode Distributed       (link-to-existing, no cap)

    Designed for enterprise scale (100s-1000s of subscriptions):
      - Parallel execution (-ThrottleLimit controls concurrency)
      - Resumable via state file (-StateFile, skips already-completed subs)
      - ARM throttle handling with exponential backoff
      - Compatible with Windows PowerShell 5.1 and PowerShell 7+

    Offboard action removes Dynatrace monitors, monitored subscription links,
    role assignments, and diagnostic settings. Resource groups created during
    onboarding are preserved by default for reuse on re-deployment. Use
    -ForceDeleteResourceGroups to remove them during offboarding.

.PARAMETER ConfigFile
    Path to a JSON config file.

.PARAMETER Action
    "Onboard" (default) or "Offboard". Offboard removes Dynatrace resources.

.PARAMETER Mode
    "Centralized" (max 20), "HybridCentralized" (auto-batch 15/monitor), or "Distributed" (no cap).

.PARAMETER ThrottleLimit
    Max parallel subscriptions. Default: 5. Set to 1 for sequential.

.PARAMETER StateFile
    Path to a JSON state file for resumability. Default: ./onboarding-state.json.
    Completed subscriptions are recorded here and skipped on re-run.

.PARAMETER ResetState
    Clear the state file and start fresh.

.PARAMETER SubscriptionFilter
    Regex inclusion filter on subscription name.

.PARAMETER SubscriptionExcludePattern
    Regex exclusion filter on subscription name.

.PARAMETER IncludeDisabled
    Include disabled subscriptions.

.PARAMETER DryRun
    Preview only.

.PARAMETER ForceDeleteResourceGroups
    When used with -Action Offboard, also deletes the resource groups created
    during onboarding. Without this switch, RGs are preserved for reuse.

.EXAMPLE
    # Centralized, sequential
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -ThrottleLimit 1

.EXAMPLE
    # Hybrid Centralized, auto-batches 300+ subs into groups of 15
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode HybridCentralized -ThrottleLimit 5

.EXAMPLE
    # Distributed, 10 parallel
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed -ThrottleLimit 10

.EXAMPLE
    # Resume a failed run
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed

.EXAMPLE
    # Start fresh (clear state)
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Mode Distributed -ResetState

.EXAMPLE
    # Offboard all subscriptions (keep RGs for reuse)
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode Distributed

.EXAMPLE
    # Offboard and delete resource groups
    .\Invoke-DynatraceOnboarding.ps1 -ConfigFile .\config.json -Action Offboard -Mode Distributed -ForceDeleteResourceGroups
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [ValidateSet("Onboard", "Offboard")]
    [string]$Action = "Onboard",

    [ValidateSet("Centralized", "HybridCentralized", "Distributed")]
    [string]$Mode = "Centralized",

    [int]$ThrottleLimit = 5,

    [string]$StateFile = "./onboarding-state.json",

    [switch]$ResetState,

    [string]$SubscriptionFilter = "",
    [string]$SubscriptionExcludePattern = "",
    [switch]$IncludeDisabled,
    [switch]$DryRun,
    [switch]$ForceDeleteResourceGroups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ScriptVersion = "2026-07-10.1"  # Increment on every customer-facing change

###############################################################################
# Helpers
###############################################################################

$script:scriptTimer = [System.Diagnostics.Stopwatch]::StartNew()
$script:phaseTimer = [System.Diagnostics.Stopwatch]::new()

function Write-Phase([string]$Message) {
    if ($script:phaseTimer.IsRunning) {
        Write-Host "  Elapsed: $($script:phaseTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor DarkGray
    }
    $script:phaseTimer.Restart()
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
            # Safe property access — StrictMode + PS7 exceptions may not have .Response
            $resp = $null
            try { $resp = $_.Exception.Response } catch {}
            if ($resp) {
                try { $statusCode = [int]$resp.StatusCode } catch {}
            }

            # Retry on 429 (throttle) or 5xx (transient)
            $retryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600) -or ($errMsg -match "throttl|Too Many Requests|RetryAfter|ServiceUnavailable|GatewayTimeout")

            if ($retryable -and $attempt -le $MaxRetries) {
                # Exponential backoff: 10s, 20s, 40s, 80s, 160s
                $waitSeconds = [math]::Min(10 * [math]::Pow(2, $attempt - 1), 300)

                # Respect Retry-After header if present
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

function Wait-ForProviderRegistration {
    param([string]$ProviderNamespace, [string]$Label, [int]$TimeoutSeconds = 120)
    $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction SilentlyContinue
    if ($provider -and $provider[0].RegistrationState -eq "Registered") {
        return "AlreadyRegistered"
    }
    Write-Step $Label "Registering $ProviderNamespace..."
    Register-AzResourceProvider -ProviderNamespace $ProviderNamespace | Out-Null
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 10; $elapsed += 10
        $check = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace
        if ($check[0].RegistrationState -eq "Registered") {
            Write-OK $Label "$ProviderNamespace registered"
            return "Registered"
        }
        Write-Step $Label "Waiting for $ProviderNamespace... ($elapsed s)"
    }
    throw "$ProviderNamespace registration timed out after $TimeoutSeconds s"
}

###############################################################################
# State management (resumability)
###############################################################################

function Load-State {
    param([string]$Path)
    if ((Test-Path $Path) -and -not $ResetState) {
        $raw = Get-Content $Path -Raw | ConvertFrom-Json
        $state = @{}
        if ($raw) {
            foreach ($prop in $raw.PSObject.Properties) {
                $state[$prop.Name] = $prop.Value
            }
        }
        return $state
    }
    return @{}
}

function Save-State {
    param([string]$Path, [hashtable]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content $Path -Force
}

###############################################################################
# Per-subscription worker: Centralized mode
###############################################################################

function Invoke-CentralizedOnboarding {
    param(
        [PSCustomObject]$Sub,
        [string]$MonitorId,
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$DiagSettingName
    )

    $sName = $Sub.SubscriptionName
    $sId   = $Sub.SubscriptionId

    $result = [PSCustomObject]@{
        SubscriptionId    = $sId
        SubscriptionName  = $sName
        Mode              = "Centralized"
        RoleAssignment    = "Skipped"
        MonitoredSub      = "Skipped"
        DiagnosticSetting = "Skipped"
        Error             = $null
    }

    try {
        # ?? Role assignment ??????????????????????????????????????????
        Write-Step $sName "Checking role assignment..."
        $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $PrincipalId -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue)

        if ($existing.Count -gt 0) {
            Write-Skip $sName "$RoleName already assigned"
            $result.RoleAssignment = "AlreadyExists"
        }
        else {
            Write-Step $sName "Assigning $RoleName..."
            New-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $PrincipalId -RoleDefinitionName $RoleName | Out-Null
            Write-OK $sName "$RoleName assigned"
            $result.RoleAssignment = "Created"
        }

        # ?? Monitored subscription ???????????????????????????????????
        Write-Step $sName "Creating monitored subscription link..."
        $monSubUrl = "https://management.azure.com${MonitorId}/monitoredSubscriptions/default?api-version=2024-04-24"
        $monSubBody = @{
            properties = @{
                operation = "AddComplete"
                monitoredSubscriptionList = @(@{
                    subscriptionId = "/subscriptions/$sId"
                    status         = "Active"
                })
            }
        }
        Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
        Write-OK $sName "Monitored subscription linked"
        $result.MonitoredSub = "Created"

        # ?? Diagnostic setting ???????????????????????????????????????
        if ($Sub.CreateDiagSetting) {
            Set-AzContext -SubscriptionId $sId -ErrorAction SilentlyContinue | Out-Null
            Wait-ForProviderRegistration -ProviderNamespace "Microsoft.Insights" -Label $sName | Out-Null

            Write-Step $sName "Checking diagnostic setting..."
            $diagUrl = "https://management.azure.com/subscriptions/${sId}/providers/Microsoft.Insights/diagnosticSettings/${DiagSettingName}?api-version=2021-05-01-preview"

            $diagExists = $false
            try { Invoke-ArmApi -Method "GET" -Url $diagUrl | Out-Null; $diagExists = $true } catch {}

            if ($diagExists) {
                Write-Skip $sName "Diagnostic setting already exists"
                $result.DiagnosticSetting = "AlreadyExists"
            }
            else {
                $categories = @("Administrative","Security","Alert","Policy","Autoscale","Recommendation","ServiceHealth","ResourceHealth")
                $diagBody = @{
                    properties = @{
                        marketplacePartnerId = $MonitorId
                        logs = @(foreach ($cat in $categories) { @{ category = $cat; enabled = $true } })
                    }
                }
                try {
                    Invoke-ArmApi -Method "PUT" -Url $diagUrl -Body $diagBody | Out-Null
                    Write-OK $sName "Diagnostic setting created"
                    $result.DiagnosticSetting = "Created"
                }
                catch {
                    if ($_.ToString() -match "Conflict|already used") {
                        Write-Skip $sName "Diagnostic setting managed by monitor tag rules"
                        $result.DiagnosticSetting = "ManagedByMonitor"
                    }
                    else { throw }
                }
            }
        }
        else {
            Write-Skip $sName "Diagnostic setting disabled"
            $result.DiagnosticSetting = "Disabled"
        }
    }
    catch {
        Write-Err $sName "Error: $_"
        $result.Error = $_.ToString()
    }

    return $result
}

###############################################################################
# Per-subscription worker: Distributed mode
###############################################################################

function Invoke-DistributedOnboarding {
    param(
        [PSCustomObject]$Sub,
        [string]$DtRegion,
        [string]$DtEnvironmentId,
        [string]$DtIngestionKey,
        [string]$DtLandingUrl,
        [string]$DtLogsEndpoint,
        [string]$DtAccountId,
        [string]$DtRegionId,
        [string]$TargetRgName,
        [bool]$CreateRg,
        [string]$UserEmail,
        [string]$UserFirstName,
        [string]$UserLastName,
        [object]$SourcePlan = $null,
        [object]$PlanData = $null
    )

    $sName   = $Sub.SubscriptionName
    $sId     = $Sub.SubscriptionId
    $resName = $Sub.ResourceName

    $result = [PSCustomObject]@{
        SubscriptionId   = $sId
        SubscriptionName = $sName
        Mode             = "Distributed"
        ResourceGroup    = "Skipped"
        MonitorResource  = "Skipped"
        ManagedIdentity  = "Skipped"
        TagRules         = "Skipped"
        Error            = $null
    }

    try {
        Set-AzContext -SubscriptionId $sId -ErrorAction Stop | Out-Null

        # Resource group
        Write-Step $sName "Checking resource group $TargetRgName ..."
        $rgExists = Get-AzResourceGroup -Name $TargetRgName -ErrorAction SilentlyContinue
        if ($rgExists) {
            Write-Skip $sName "Resource group already exists"
            $result.ResourceGroup = "AlreadyExists"
        }
        elseif ($CreateRg) {
            New-AzResourceGroup -Name $TargetRgName -Location $DtRegion -Force | Out-Null
            Write-OK $sName "Resource group created"
            $result.ResourceGroup = "Created"
        }
        else {
            throw "Resource group $TargetRgName missing and create_resource_group is false"
        }

        # Provider registration
        Wait-ForProviderRegistration -ProviderNamespace "Dynatrace.Observability" -Label $sName | Out-Null

        # Monitor resource
        $monUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors/${resName}?api-version=2024-04-24"

        $monExists = $false
        try { Invoke-ArmApi -Method "GET" -Url $monUrl | Out-Null; $monExists = $true } catch {}

        if ($monExists) {
            Write-Skip $sName "Monitor '$resName' already exists"
            $result.MonitorResource = "AlreadyExists"
        }
        else {
            Write-Step $sName "Creating monitor '$resName' linked to $DtEnvironmentId..."
            $monBody = @{
                location   = $DtRegion
                identity   = @{ type = "SystemAssigned" }
                properties = @{
                    monitoringStatus = "Enabled"
                    marketplaceSubscriptionStatus = "Active"
                    dynatraceEnvironmentProperties = @{
                        environmentInfo = @{
                            environmentId        = $DtEnvironmentId
                            ingestionKey         = $DtIngestionKey
                            landingURL           = $DtLandingUrl
                            logsIngestionEndpoint = $DtLogsEndpoint
                        }
                        accountInfo = @{
                            accountId = $DtAccountId
                            regionId  = $DtRegionId
                        }
                    }
                    userInfo = @{
                        firstName    = $UserFirstName
                        lastName     = $UserLastName
                        emailAddress = $UserEmail
                        country      = $DtRegion
                    }
                }
            }
            # Include planData from source monitor (required for link-to-existing).
            # NEVER include top-level 'plan' block — linked monitors are not Marketplace
            # purchases, so ARM always rejects it with CannotSetPlan.
            if ($PlanData) { $monBody.properties["planData"] = $PlanData }

            try {
                $jsonBody = $monBody | ConvertTo-Json -Depth 20 -Compress
                Write-Host "    [$sName] PUT body top-level keys: $($monBody.Keys -join ', ')" -ForegroundColor DarkGray
                Write-Host "    [$sName] Has top-level 'plan' key: $($monBody.ContainsKey('plan'))" -ForegroundColor DarkGray
                Write-Host "    [$sName] PUT body planData: $($monBody.properties.planData | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor DarkGray
                Invoke-ArmApi -Method "PUT" -Url $monUrl -Body $monBody | Out-Null

                # Poll provisioning state — ARM PUT returns immediately but provisioning is async
                $pollAttempts = 0; $maxPoll = 20   # 20 * 15s = 5 min
                while ($pollAttempts -lt $maxPoll) {
                    Start-Sleep -Seconds 15
                    $pollAttempts++
                    $monCheck = Invoke-ArmApi -Method "GET" -Url $monUrl
                    $provState = $monCheck.properties.provisioningState
                    if ($provState -eq "Succeeded") {
                        Write-OK $sName "Monitor provisioning succeeded"
                        $result.MonitorResource = "Created"
                        break
                    }
                    elseif ($provState -eq "Failed") {
                        $failMsg = "Monitor provisioning failed (state: Failed)."
                        # Dump full monitor state for diagnostics
                        try {
                            $errBody = $monCheck | ConvertTo-Json -Depth 10 -Compress
                            Write-Host "    [$sName] Full monitor state on failure: $errBody" -ForegroundColor DarkGray
                            $innerError = $null
                            try { $innerError = $monCheck.properties.error } catch {}
                            if ($innerError) {
                                $failMsg = "Provisioning failed: $($innerError | ConvertTo-Json -Depth 5 -Compress)"
                            }
                            if ($errBody -match 'CannotSetPlan') {
                                $failMsg = "CannotSetPlan (async) — ARM auto-associated plan despite script not sending one. Try removing plan_data from config.json."
                            } elseif ($errBody -match 'not linkable') {
                                $failMsg = "Environment '$DtEnvironmentId' is not linkable. Causes: (1) ingestion key expired, (2) Dynatrace env not configured for multi-sub linking, (3) environment linking limit reached, (4) planData mismatch."
                            }
                        } catch {}
                        throw $failMsg
                    }
                    Write-Step $sName "Provisioning state: $provState ($pollAttempts/$maxPoll)..."
                }
                if ($pollAttempts -ge $maxPoll) {
                    throw "Monitor provisioning timed out after $($maxPoll * 15)s. Check Azure Activity Log for details."
                }
            }
            catch {
                if ($_.ToString() -match "already linked|already exists") {
                    Write-Skip $sName "Monitor already linked"
                    $result.MonitorResource = "AlreadyLinked"
                }
                elseif ($_.ToString() -match "not linkable") {
                    Write-Err $sName "Environment '$DtEnvironmentId' is not linkable. Ensure the source monitor plan supports linking and the environment is configured for multi-subscription linking in Dynatrace."
                    throw
                }
                else { throw }
            }
        }

        # Verify managed identity — ARM occasionally reports provisioningState=Succeeded
        # while leaving the monitor's system-assigned identity null. Without an identity,
        # Dynatrace's "Gets Metric Status" callback times out (GatewayTimeout) and the
        # subscription sits in "Waiting for data..." indefinitely. Force-PATCH to mint one,
        # then grant Monitoring Reader so Dynatrace can read metrics.
        Write-Step $sName "Verifying managed identity..."
        $monData = Invoke-ArmApi -Method "GET" -Url $monUrl
        $monPid = $null
        try { $monPid = $monData.identity.principalId } catch {}
        if (-not $monPid) {
            Write-Step $sName "Managed identity missing — forcing SystemAssigned (PATCH)..."
            $idBody = @{ identity = @{ type = "SystemAssigned" } }
            Invoke-ArmApi -Method "PATCH" -Url $monUrl -Body $idBody | Out-Null
            $idAttempts = 0
            while ($idAttempts -lt 8 -and -not $monPid) {
                Start-Sleep -Seconds 10
                $idAttempts++
                $monData = Invoke-ArmApi -Method "GET" -Url $monUrl
                try { $monPid = $monData.identity.principalId } catch {}
            }
        }
        if ($monPid) {
            Write-OK $sName "Managed identity present ($monPid)"
            $existRole = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $monPid -RoleDefinitionName "Monitoring Reader" -ErrorAction SilentlyContinue)
            if ($existRole.Count -eq 0) {
                try {
                    New-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $monPid -RoleDefinitionName "Monitoring Reader" | Out-Null
                    Write-OK $sName "Monitoring Reader assigned to monitor identity"
                    $result.ManagedIdentity = "Verified"
                }
                catch {
                    Write-Skip $sName "Monitoring Reader assignment skipped: $_"
                    $result.ManagedIdentity = "Verified (role assign failed)"
                }
            }
            else {
                Write-Skip $sName "Monitoring Reader already assigned"
                $result.ManagedIdentity = "Verified"
            }
        }
        else {
            Write-Err $sName "Managed identity still missing after PATCH — metrics may not flow"
            $result.ManagedIdentity = "Missing"
        }

        # Tag rules
        Write-Step $sName "Configuring tag rules..."
        $trUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors/${resName}/tagRules/default?api-version=2024-04-24"
        $trBody = @{
            properties = @{
                logRules = @{
                    sendActivityLogs     = if ($Sub.SendActivityLogs) { "Enabled" } else { "Disabled" }
                    sendSubscriptionLogs = if ($Sub.SendSubscriptionLogs) { "Enabled" } else { "Disabled" }
                    filteringTags        = @()
                }
                metricRules = @{
                    sendingMetrics = if ($Sub.SendMetrics) { "Enabled" } else { "Disabled" }
                    filteringTags  = @()
                }
            }
        }

        $retries = 0; $success = $false
        while ($retries -lt 6 -and -not $success) {
            try {
                Invoke-ArmApi -Method "PUT" -Url $trUrl -Body $trBody | Out-Null
                $success = $true
            }
            catch {
                $retries++
                if ($retries -lt 6) {
                    Write-Step $sName "Monitor provisioning, retrying tag rules ($retries/5)..."
                    Start-Sleep -Seconds 15
                }
                else { throw }
            }
        }
        Write-OK $sName "Tag rules configured"
        $result.TagRules = "Configured"
    }
    catch {
        Write-Err $sName "Error: $_"
        $result.Error = $_.ToString()
    }

    return $result
}

###############################################################################
# Per-subscription worker: Centralized offboarding
###############################################################################

function Invoke-CentralizedOffboarding {
    param(
        [PSCustomObject]$Sub,
        [string]$MonitorId,
        [string]$PrincipalId,
        [string]$RoleName,
        [string]$DiagSettingName
    )

    $sName = $Sub.SubscriptionName
    $sId   = $Sub.SubscriptionId

    $result = [PSCustomObject]@{
        SubscriptionId    = $sId
        SubscriptionName  = $sName
        Mode              = "Centralized"
        Action            = "Offboard"
        MonitoredSub      = "Skipped"
        RoleAssignment    = "Skipped"
        DiagnosticSetting = "Skipped"
        Error             = $null
    }

    try {
        # Remove monitored subscription link
        Write-Step $sName "Removing monitored subscription link..."
        $monSubUrl = "https://management.azure.com${MonitorId}/monitoredSubscriptions/default?api-version=2024-04-24"
        $monSubBody = @{
            properties = @{
                operation = "DeleteComplete"
                monitoredSubscriptionList = @(@{
                    subscriptionId = "/subscriptions/$sId"
                })
            }
        }
        try {
            Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
            Write-OK $sName "Monitored subscription link removed"
            $result.MonitoredSub = "Removed"
        }
        catch {
            if ($_.ToString() -match "not found|does not exist|NotFound") {
                Write-Skip $sName "Monitored subscription link not found"
                $result.MonitoredSub = "NotFound"
            }
            else { throw }
        }

        # Remove role assignment
        Write-Step $sName "Removing $RoleName role assignment..."
        $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $PrincipalId -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            foreach ($ra in $existing) {
                Remove-AzRoleAssignment -InputObject $ra -ErrorAction SilentlyContinue | Out-Null
            }
            Write-OK $sName "$RoleName removed"
            $result.RoleAssignment = "Removed"
        }
        else {
            Write-Skip $sName "$RoleName not found"
            $result.RoleAssignment = "NotFound"
        }

        # Remove diagnostic setting
        if ($Sub.CreateDiagSetting) {
            Write-Step $sName "Removing diagnostic setting..."
            Set-AzContext -SubscriptionId $sId -ErrorAction SilentlyContinue | Out-Null
            $diagUrl = "https://management.azure.com/subscriptions/${sId}/providers/Microsoft.Insights/diagnosticSettings/${DiagSettingName}?api-version=2021-05-01-preview"
            try {
                Invoke-ArmApi -Method "DELETE" -Url $diagUrl | Out-Null
                Write-OK $sName "Diagnostic setting removed"
                $result.DiagnosticSetting = "Removed"
            }
            catch {
                if ($_.ToString() -match "not found|NotFound|does not exist") {
                    Write-Skip $sName "Diagnostic setting not found"
                    $result.DiagnosticSetting = "NotFound"
                }
                else { throw }
            }
        }
    }
    catch {
        Write-Err $sName "Error: $_"
        $result.Error = $_.ToString()
    }

    return $result
}

###############################################################################
# Per-subscription worker: Distributed offboarding
###############################################################################

function Invoke-DistributedOffboarding {
    param(
        [PSCustomObject]$Sub,
        [string]$DtRegion,
        [string]$TargetRgName,
        [string]$RoleName,
        [bool]$ForceDeleteRg
    )

    $sName   = $Sub.SubscriptionName
    $sId     = $Sub.SubscriptionId
    $resName = $Sub.ResourceName

    $result = [PSCustomObject]@{
        SubscriptionId   = $sId
        SubscriptionName = $sName
        Mode             = "Distributed"
        Action           = "Offboard"
        TagRules         = "Skipped"
        MonitorResource  = "Skipped"
        RoleAssignment   = "Skipped"
        ResourceGroup    = "Skipped"
        Error            = $null
    }

    try {
        Set-AzContext -SubscriptionId $sId -ErrorAction Stop | Out-Null

        # Discover Dynatrace.Observability/monitors in the target RG
        $monUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors/${resName}?api-version=2024-04-24"

        $monitor = $null
        try { $monitor = Invoke-ArmApi -Method "GET" -Url $monUrl } catch {}

        if (-not $monitor) {
            # Try discovering any Dynatrace monitors in the RG
            Write-Step $sName "Monitor '$resName' not found, discovering Dynatrace resources..."
            $listUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors?api-version=2024-04-24"
            try {
                $monList = Invoke-ArmApi -Method "GET" -Url $listUrl
                if ($monList.value -and $monList.value.Count -gt 0) {
                    $monitor = $monList.value[0]
                    $resName = $monitor.name
                    Write-Step $sName "Found monitor '$resName' in $TargetRgName"
                }
            }
            catch {}
        }

        if ($monitor) {
            $monitorPid = if ($monitor.identity) { $monitor.identity.principalId } else { $null }

            # Delete tag rules first (dependency of monitor)
            Write-Step $sName "Removing tag rules..."
            $trUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors/${resName}/tagRules/default?api-version=2024-04-24"
            try {
                Invoke-ArmApi -Method "DELETE" -Url $trUrl | Out-Null
                Write-OK $sName "Tag rules removed"
                $result.TagRules = "Removed"
            }
            catch {
                if ($_.ToString() -match "not found|NotFound|does not exist") {
                    Write-Skip $sName "Tag rules not found"
                    $result.TagRules = "NotFound"
                }
                else {
                    Write-Err $sName "Warning: tag rules removal failed: $_"
                    $result.TagRules = "Failed"
                }
            }

            # Delete monitor resource
            Write-Step $sName "Deleting monitor '$resName'..."
            $delUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$TargetRgName/providers/Dynatrace.Observability/monitors/${resName}?api-version=2024-04-24"
            try {
                Invoke-ArmApi -Method "DELETE" -Url $delUrl | Out-Null
                # Poll until deleted or timeout
                $pollAttempts = 0; $maxPoll = 20
                while ($pollAttempts -lt $maxPoll) {
                    Start-Sleep -Seconds 15; $pollAttempts++
                    try {
                        Invoke-ArmApi -Method "GET" -Url $delUrl | Out-Null
                        Write-Step $sName "Monitor deletion in progress ($pollAttempts/$maxPoll)..."
                    }
                    catch {
                        # 404 means deleted
                        Write-OK $sName "Monitor '$resName' deleted"
                        $result.MonitorResource = "Deleted"
                        break
                    }
                }
                if ($result.MonitorResource -ne "Deleted") {
                    Write-Err $sName "Monitor deletion timed out"
                    $result.MonitorResource = "DeleteTimeout"
                }
            }
            catch {
                if ($_.ToString() -match "not found|NotFound|does not exist") {
                    Write-Skip $sName "Monitor not found"
                    $result.MonitorResource = "NotFound"
                }
                else { throw }
            }

            # Remove role assignment for the monitor's managed identity
            if ($monitorPid) {
                Write-Step $sName "Removing role assignments..."
                $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $monitorPid -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue)
                if ($existing.Count -gt 0) {
                    foreach ($ra in $existing) {
                        Remove-AzRoleAssignment -InputObject $ra -ErrorAction SilentlyContinue | Out-Null
                    }
                    Write-OK $sName "Role assignments removed"
                    $result.RoleAssignment = "Removed"
                }
                else {
                    Write-Skip $sName "No role assignments found"
                    $result.RoleAssignment = "NotFound"
                }
            }
        }
        else {
            Write-Skip $sName "No Dynatrace monitors found in $TargetRgName"
            $result.MonitorResource = "NotFound"
            $result.TagRules = "NotFound"
        }

        # Delete resource group only with -ForceDeleteResourceGroups
        if ($ForceDeleteRg) {
            $rgExists = Get-AzResourceGroup -Name $TargetRgName -ErrorAction SilentlyContinue
            if ($rgExists) {
                Write-Step $sName "Force deleting resource group $TargetRgName..."
                Remove-AzResourceGroup -Name $TargetRgName -Force | Out-Null
                Write-OK $sName "Resource group deleted"
                $result.ResourceGroup = "Deleted"
            }
            else {
                Write-Skip $sName "Resource group not found"
                $result.ResourceGroup = "NotFound"
            }
        }
        else {
            Write-Skip $sName "Resource group $TargetRgName preserved (use -ForceDeleteResourceGroups to remove)"
            $result.ResourceGroup = "Preserved"
        }
    }
    catch {
        Write-Err $sName "Error: $_"
        $result.Error = $_.ToString()
    }

    return $result
}

###############################################################################
# Load config
###############################################################################

if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }

Write-Host "Loading config: $ConfigFile" -ForegroundColor Gray
$cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

foreach ($field in @("dynatrace_subscription_id", "dynatrace_resource_group_name", "dynatrace_monitor_name")) {
    if (-not $cfg.$field) { throw "Missing required config field: $field" }
}

$dtSubscriptionId  = $cfg.dynatrace_subscription_id
$dtResourceGroup   = $cfg.dynatrace_resource_group_name
$dtMonitorName     = $cfg.dynatrace_monitor_name
$dtRegion          = if ($cfg.PSObject.Properties['dynatrace_region'])                    { $cfg.dynatrace_region } else { "" }

$dtEnvironmentId   = if ($cfg.PSObject.Properties['dynatrace_environment_id'])              { $cfg.dynatrace_environment_id } else { "" }
$dtIngestionKey    = if ($cfg.PSObject.Properties['dynatrace_environment_ingestion_key'])    { $cfg.dynatrace_environment_ingestion_key } else { "" }
$dtLandingUrl      = if ($cfg.PSObject.Properties['dynatrace_landing_url'])                 { $cfg.dynatrace_landing_url } else { "" }
$dtLogsEndpoint    = if ($cfg.PSObject.Properties['dynatrace_logs_ingestion_endpoint'])      { $cfg.dynatrace_logs_ingestion_endpoint } else { "" }
$dtAccountId       = if ($cfg.PSObject.Properties['dynatrace_account_id'])                  { $cfg.dynatrace_account_id } else { "" }
$dtRegionId        = if ($cfg.PSObject.Properties['dynatrace_region_id'])                   { $cfg.dynatrace_region_id } else { "" }
$resourcePrefix    = if ($cfg.PSObject.Properties['resource_name_prefix'] -and -not [string]::IsNullOrWhiteSpace($cfg.resource_name_prefix))  { $cfg.resource_name_prefix } else { "dt-monitor" }
$createRg          = if ($cfg.PSObject.Properties['create_resource_group'])                 { $cfg.create_resource_group } else { $true }
$targetRgName      = if ($cfg.PSObject.Properties['target_resource_group_name'] -and -not [string]::IsNullOrWhiteSpace($cfg.target_resource_group_name)) { $cfg.target_resource_group_name } else { "rg-dynatrace" }

# User info for the monitor resource (required by Azure API)
$userEmail     = if ($cfg.PSObject.Properties['user_email'])      { $cfg.user_email }      else { "" }
$userFirstName = if ($cfg.PSObject.Properties['user_first_name']) { $cfg.user_first_name } else { "" }
$userLastName  = if ($cfg.PSObject.Properties['user_last_name'])  { $cfg.user_last_name }  else { "" }

$cfgDefaults = if ($cfg.PSObject.Properties['defaults']) { $cfg.defaults } else { $null }
$sendActivityLogs     = if ($cfgDefaults -and $cfgDefaults.PSObject.Properties['send_activity_logs'])        { $cfgDefaults.send_activity_logs }        else { $true }
$sendSubscriptionLogs = if ($cfgDefaults -and $cfgDefaults.PSObject.Properties['send_subscription_logs'])    { $cfgDefaults.send_subscription_logs }    else { $true }
$sendMetrics          = if ($cfgDefaults -and $cfgDefaults.PSObject.Properties['send_metrics'])              { $cfgDefaults.send_metrics }              else { $true }
$autoMuting           = if ($cfgDefaults -and $cfgDefaults.PSObject.Properties['auto_muting'])               { $cfgDefaults.auto_muting }               else { $true }
$createDiagSetting    = if ($cfgDefaults -and $cfgDefaults.PSObject.Properties['create_diagnostic_setting']) { $cfgDefaults.create_diagnostic_setting } else { $true }

$diagSettingName      = if ($cfg.PSObject.Properties['diagnostic_setting_name'] -and -not [string]::IsNullOrWhiteSpace($cfg.diagnostic_setting_name)) { $cfg.diagnostic_setting_name } else { "send-activity-logs-to-dynatrace" }
$roleName             = if ($cfg.PSObject.Properties['role_definition_name'] -and -not [string]::IsNullOrWhiteSpace($cfg.role_definition_name))   { $cfg.role_definition_name }   else { "Monitoring Reader" }

if (-not $PSBoundParameters.ContainsKey('SubscriptionFilter') -and $cfg.PSObject.Properties['subscription_filter'] -and $cfg.subscription_filter) { $SubscriptionFilter = $cfg.subscription_filter }
if (-not $PSBoundParameters.ContainsKey('SubscriptionExcludePattern') -and $cfg.PSObject.Properties['subscription_exclude_pattern'] -and $cfg.subscription_exclude_pattern) { $SubscriptionExcludePattern = $cfg.subscription_exclude_pattern }

$overrides = @{}
if ($cfg.PSObject.Properties['subscription_overrides'] -and $cfg.subscription_overrides) {
    foreach ($prop in $cfg.subscription_overrides.PSObject.Properties) { $overrides[$prop.Name] = $prop.Value }
}

###############################################################################
# Validate required config fields
###############################################################################
$requiredFields = @{
    'dynatrace_subscription_id'            = $dtSubscriptionId
    'dynatrace_resource_group_name'        = $dtResourceGroup
    'dynatrace_monitor_name'               = $dtMonitorName
    'dynatrace_environment_id'             = $dtEnvironmentId
    'dynatrace_environment_ingestion_key'  = $dtIngestionKey
}
foreach ($kv in $requiredFields.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($kv.Value)) {
        throw "Config field '$($kv.Key)' is missing or empty. Please update your config file."
    }
}

###############################################################################
# Phase 1: Verify Azure connection
###############################################################################

Write-Phase "Phase 1: Verify Azure Connection"

try {
    $ctx = Get-AzContext
    if (-not $ctx) { throw "No context" }
    Write-Host "  Connected as: $($ctx.Account.Id)" -ForegroundColor Green
    Write-Host "  Tenant:       $($ctx.Tenant.Id)" -ForegroundColor Green
}
catch {
    Write-Host "  Not connected. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
    $ctx = Get-AzContext
    Write-Host "  Connected as: $($ctx.Account.Id)" -ForegroundColor Green
}

Write-Host "  Action:          $Action" -ForegroundColor White
Write-Host "  Mode:           $Mode" -ForegroundColor White
if ($Action -eq "Offboard" -and $ForceDeleteResourceGroups) {
    Write-Host "  FORCE DELETE:   Resource groups will be removed!" -ForegroundColor Red
}
elseif ($Action -eq "Offboard") {
    Write-Host "  RG Preservation: Resource groups will be kept for reuse" -ForegroundColor Yellow
}

# Auto-populate user info from Az context if not in config
if (-not $userEmail)     { $userEmail     = $ctx.Account.Id }
if (-not $userFirstName) { $userFirstName = ($ctx.Account.Id -split '@')[0] }
if (-not $userLastName)  { $userLastName  = "AzureUser" }
Write-Host "  Script version: $script:ScriptVersion" -ForegroundColor White
Write-Host "  Parallelism:    $ThrottleLimit" -ForegroundColor White
Write-Host "  State file:     $StateFile" -ForegroundColor White

###############################################################################
# Phase 2: Resolve source monitor
###############################################################################

Write-Phase "Phase 2: Resolve Source Dynatrace Monitor"

$sourceMonitorUrl = "https://management.azure.com/subscriptions/$dtSubscriptionId/resourceGroups/$dtResourceGroup/providers/Dynatrace.Observability/monitors/${dtMonitorName}?api-version=2024-04-24"

$sourceMonitor = $null
try { $sourceMonitor = Invoke-ArmApi -Method "GET" -Url $sourceMonitorUrl }
catch { throw "Failed to resolve source monitor '$dtMonitorName': $_" }

$monitorId   = $sourceMonitor.id
$principalId = $sourceMonitor.identity.principalId

$envProps = $sourceMonitor.properties.dynatraceEnvironmentProperties
if ($envProps) {
    if ($envProps.environmentInfo) {
        if (-not $dtEnvironmentId)  { $dtEnvironmentId = $envProps.environmentInfo.environmentId }
        if (-not $dtLogsEndpoint)   { $dtLogsEndpoint  = $envProps.environmentInfo.logsIngestionEndpoint }
        if (-not $dtLandingUrl)     { $dtLandingUrl    = $envProps.environmentInfo.landingURL }
    }
    if ($envProps.accountInfo) {
        if (-not $dtAccountId) { $dtAccountId = $envProps.accountInfo.accountId }
        if (-not $dtRegionId)  { $dtRegionId  = $envProps.accountInfo.regionId }
    }
}
if (-not $dtRegion) { $dtRegion = $sourceMonitor.location }
# Linked monitors must be in the same region as the source monitor's Dynatrace cluster
$sourceMonitorLocation = $sourceMonitor.location
if ($dtRegion -ne $sourceMonitorLocation) {
    Write-Host "  NOTE: Config region '$dtRegion' differs from source monitor location '$sourceMonitorLocation'." -ForegroundColor Yellow
    Write-Host "        Using source monitor location '$sourceMonitorLocation' for linked monitors." -ForegroundColor Yellow
    $dtRegion = $sourceMonitorLocation
}
if (-not $dtLandingUrl -and $dtEnvironmentId) { $dtLandingUrl = "https://$dtEnvironmentId.apps.dynatrace.com" }

# Extract plan data from source monitor (required for link-to-existing via Marketplace)
# Layer 1: Try ARM REST API response
$sourcePlan     = if ($sourceMonitor.PSObject.Properties['plan'] -and $sourceMonitor.plan)         { $sourceMonitor.plan }                   else { $null }
$sourcePlanData = if ($sourceMonitor.properties -and $sourceMonitor.properties.PSObject.Properties['planData'] -and $sourceMonitor.properties.planData) { $sourceMonitor.properties.planData } else { $null }

# Layer 2: Fallback to Get-AzResource (more reliable for Marketplace plan data)
if (-not $sourcePlan -or -not $sourcePlanData) {
    Write-Host "  Plan data incomplete in ARM response, trying Get-AzResource fallback..." -ForegroundColor Yellow
    try {
        Set-AzContext -SubscriptionId $dtSubscriptionId -ErrorAction Stop | Out-Null
        $azResource = Get-AzResource -ResourceId $monitorId -ErrorAction Stop
        if (-not $sourcePlan -and $azResource.Plan) {
            $sourcePlan = @{
                name          = $azResource.Plan.Name
                publisher     = $azResource.Plan.Publisher
                product       = $azResource.Plan.Product
                promotionCode = if ($azResource.Plan.PromotionCode) { $azResource.Plan.PromotionCode } else { "" }
            }
            Write-OK "Plan" "Found via Get-AzResource: $($sourcePlan.name) ($($sourcePlan.publisher)/$($sourcePlan.product))"
        }
        if (-not $sourcePlanData) {
            $expanded = Get-AzResource -ResourceId $monitorId -ExpandProperties -ErrorAction Stop
            if ($expanded.Properties -and $expanded.Properties.planData) {
                $sourcePlanData = $expanded.Properties.planData
                Write-OK "Plan" "Found planData via Get-AzResource"
            }
        }
        # Synthesize plan from planData if plan is still missing but planData has planDetails
        if (-not $sourcePlan -and $sourcePlanData) {
            $pd = if ($sourcePlanData -is [hashtable]) { $sourcePlanData } else { $sourcePlanData | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable }
            $planName = if ($pd.planDetails) { ($pd.planDetails -split '@')[0] } else { $null }
            # Only synthesize for Marketplace (paid) plans — trial plans cannot be set on linked monitors
            if ($planName -and $planName -notmatch 'trial') {
                $sourcePlan = @{
                    name          = $planName
                    publisher     = "dynatrace"
                    product       = "dynatrace_portal_integration"
                    promotionCode = ""
                }
                Write-OK "Plan" "Synthesized plan from planData: $planName (dynatrace/dynatrace_portal_integration)"
            }
            elseif ($planName -match 'trial') {
                Write-Host "  Source monitor uses trial plan '$planName' — linked monitors will use planData only (no plan block)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  Get-AzResource plan lookup failed: $_" -ForegroundColor Yellow
    }
}

# Layer 3: Config override (highest priority when present)
if ($cfg.PSObject.Properties['plan'] -and $cfg.plan) {
    $sourcePlan = $cfg.plan
    Write-Host "  Using plan from config.json override" -ForegroundColor Green
}
if ($cfg.PSObject.Properties['plan_data'] -and $cfg.plan_data) {
    $sourcePlanData = $cfg.plan_data
    Write-Host "  Using plan_data from config.json override" -ForegroundColor Green
}

if (-not $sourcePlanData -and $Mode -ne "Centralized") {
    Write-Host ""
    Write-Host "  ERROR: No planData found for source monitor." -ForegroundColor Red
    Write-Host "  Linked monitors require planData to provision." -ForegroundColor Red
    Write-Host "  Add plan_data to your config.json (adjust values to match your Marketplace offer):" -ForegroundColor Yellow
    Write-Host '  "plan_data": {' -ForegroundColor White
    Write-Host '    "usageType": "Committed",' -ForegroundColor White
    Write-Host '    "billingCycle": "Monthly",' -ForegroundColor White
    Write-Host '    "planDetails": "azportalintegration_dynatrace_payg@TIDdynatrace",' -ForegroundColor White
    Write-Host '    "effectiveDate": "2024-10-01T00:00:00Z"' -ForegroundColor White
    Write-Host '  }' -ForegroundColor White
    Write-Host ""
    throw "Cannot create linked monitors without planData. See above for config.json instructions."
}

# Log plan resolution result
# IMPORTANT: Only planData is sent in linked monitor PUT bodies. The top-level 'plan'
# block is NEVER included — ARM rejects it with CannotSetPlan on all linked monitors
# (they're not Marketplace purchases). $sourcePlan is kept for diagnostics only.
if ($sourcePlanData) {
    $pdInfo = if ($sourcePlanData.planDetails) { $sourcePlanData.planDetails } else { "(present)" }
    Write-Host "  PlanData:        $pdInfo (will be included in linked monitor PUT)" -ForegroundColor Green
    if ($sourcePlan) {
        Write-Host "  Plan (source):   $($sourcePlan.name) (diagnostics only — NOT sent to linked monitors)" -ForegroundColor DarkGray
    }
} elseif ($sourcePlan) {
    Write-Host "  WARNING: Source has plan but no planData — linked monitors may fail to provision" -ForegroundColor Yellow
}

if ($Mode -eq "Distributed") {
    if (-not $dtEnvironmentId) { throw "Distributed mode requires dynatrace_environment_id" }
    if (-not $dtIngestionKey)  { throw "Distributed mode requires dynatrace_environment_ingestion_key" }
}

Write-Host "  Source monitor:  $dtMonitorName" -ForegroundColor Green
Write-Host "  Environment:     $dtEnvironmentId" -ForegroundColor Green
Write-Host "  Region:          $dtRegion" -ForegroundColor Green

###############################################################################
# Phase 3: Discover subscriptions
###############################################################################

Write-Phase "Phase 3: Discover Subscriptions"

if ($IncludeDisabled) { $allSubs = @(Get-AzSubscription | Select-Object Id, Name, State) }
else { $allSubs = @(Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | Select-Object Id, Name, State) }

Write-Host "  Found $($allSubs.Count) enabled subscription(s) in tenant"

if ($Mode -eq "Distributed") {
    $allSubs = @($allSubs | Where-Object { $_.Id -ne $dtSubscriptionId })
    Write-Host "  Excluding source subscription: $($allSubs.Count) remaining"
}

if ($SubscriptionFilter.Length -gt 0) {
    $filteredSubs = @($allSubs | Where-Object { $_.Name -match $SubscriptionFilter })
    Write-Host "  Inclusion filter '$SubscriptionFilter': $($filteredSubs.Count) match(es)"
}
else {
    $filteredSubs = @($allSubs)
    Write-Host "  No inclusion filter - using all subscriptions"
}

if ($SubscriptionExcludePattern.Length -gt 0) {
    $filteredSubs = @($filteredSubs | Where-Object { $_.Name -notmatch $SubscriptionExcludePattern })
    Write-Host "  Exclusion filter '$SubscriptionExcludePattern': $($filteredSubs.Count) remaining"
}

if ($filteredSubs.Count -eq 0) { throw "No subscriptions matched." }

if ($Mode -eq "Centralized" -and $filteredSubs.Count -gt 20) {
    Write-Host ""
    Write-Host "  WARNING: $($filteredSubs.Count) subs found but Centralized mode caps at 20." -ForegroundColor Red
    Write-Host "  Consider: -Mode HybridCentralized (auto-batches into groups of 15) or -Mode Distributed" -ForegroundColor Red
    Write-Host ""
}

# Build target list
$targetSubscriptions = @(foreach ($sub in $filteredSubs) {
    $ov = if ($overrides.ContainsKey($sub.Id)) { $overrides[$sub.Id] } else { $null }
    [PSCustomObject]@{
        SubscriptionId       = $sub.Id
        SubscriptionName     = $sub.Name
        SendActivityLogs     = if ($ov -and $null -ne $ov.send_activity_logs)        { $ov.send_activity_logs }        else { $sendActivityLogs }
        SendSubscriptionLogs = if ($ov -and $null -ne $ov.send_subscription_logs)    { $ov.send_subscription_logs }    else { $sendSubscriptionLogs }
        SendMetrics          = if ($ov -and $null -ne $ov.send_metrics)              { $ov.send_metrics }              else { $sendMetrics }
        AutoMuting           = if ($ov -and $null -ne $ov.auto_muting)               { $ov.auto_muting }               else { $autoMuting }
        CreateDiagSetting    = if ($ov -and $null -ne $ov.create_diagnostic_setting) { $ov.create_diagnostic_setting } else { $createDiagSetting }
        ResourceName         = if ($ov -and $ov.resource_name) { $ov.resource_name } else { "$resourcePrefix-$($sub.Name -replace '[^a-zA-Z0-9-]', '-')" }
    }
})

# Load state and filter out completed subs
$state = Load-State -Path $StateFile

$pendingSubs = @($targetSubscriptions | Where-Object {
    -not $state.ContainsKey($_.SubscriptionId) -or $state[$_.SubscriptionId] -ne "Completed"
})
$skippedCount = $targetSubscriptions.Count - $pendingSubs.Count

Write-Host ""
Write-Host "  Total discovered:  $($targetSubscriptions.Count)" -ForegroundColor White
if ($skippedCount -gt 0) {
    Write-Host "  Already completed: $skippedCount (from state file)" -ForegroundColor Yellow
}
Write-Host "  Pending:           $($pendingSubs.Count)" -ForegroundColor White

if ($DryRun) {
    Write-Host ""
    Write-Host "  DRY RUN ($Action) - no changes." -ForegroundColor Yellow
    Write-Host ""
    if ($Action -eq "Offboard" -and $ForceDeleteResourceGroups) {
        Write-Host "  WARNING: -ForceDeleteResourceGroups is set. RGs would be deleted." -ForegroundColor Red
    }
    elseif ($Action -eq "Offboard") {
        Write-Host "  Resource groups will be preserved for reuse." -ForegroundColor Yellow
    }
    if ($Mode -eq "HybridCentralized" -and $Action -eq "Onboard") {
        $batchCount = [math]::Ceiling($pendingSubs.Count / 15)
        Write-Host "  HybridCentralized: $($pendingSubs.Count) subs -> $batchCount batch(es) of up to 15" -ForegroundColor Cyan
        Write-Host "  Resource groups to create: $batchCount" -ForegroundColor Cyan
        Write-Host ""
    }
    Write-Host "  Pending subscriptions:" -ForegroundColor White
    foreach ($ps in $pendingSubs) {
        Write-Host "    - $($ps.SubscriptionName) ($($ps.SubscriptionId))" -ForegroundColor Gray
    }
    return $targetSubscriptions
}

if ($pendingSubs.Count -eq 0) {
    Write-Host ""
    Write-Host "  All subscriptions already completed. Use -ResetState to re-run." -ForegroundColor Yellow
    return @()
}

###############################################################################
# Phase 4 (Offboard): Remove Dynatrace resources
###############################################################################

if ($Action -eq "Offboard") {

    Write-Phase "Phase 4: Offboard Subscriptions ($Mode)"

    $results      = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    $stateSync    = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    foreach ($k in $state.Keys) { $stateSync[$k] = $state[$k] }

    if ($Mode -eq "Centralized") {
        # Centralized offboard: remove monitored sub links, role assignments, diag settings
        foreach ($sub in $pendingSubs) {
            Write-Host ""
            Write-Host "  -- $($sub.SubscriptionName) ($($sub.SubscriptionId)) --" -ForegroundColor White

            $result = Invoke-CentralizedOffboarding -Sub $sub -MonitorId $monitorId -PrincipalId $principalId -RoleName $roleName -DiagSettingName $diagSettingName
            $results.Add($result)

            if (-not $result.Error) { $stateSync[$sub.SubscriptionId] = "Completed" }
            else { $stateSync[$sub.SubscriptionId] = "Failed" }

            $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
            Save-State -Path $StateFile -State $stateHash
        }
    }
    elseif ($Mode -eq "HybridCentralized") {
        # HybridCentralized offboard: discover batch monitors in anchor subs, remove members, delete monitors
        # Discover batch monitors from the source monitor's environment
        Write-Host "  Discovering batch monitors across subscriptions..." -ForegroundColor White

        foreach ($sub in $pendingSubs) {
            $sName = $sub.SubscriptionName
            $sId   = $sub.SubscriptionId

            Write-Host ""
            Write-Host "  -- $sName ($sId) --" -ForegroundColor White

            $result = [PSCustomObject]@{
                SubscriptionId   = $sId
                SubscriptionName = $sName
                Mode             = "HybridCentralized"
                Action           = "Offboard"
                MonitorResource  = "Skipped"
                MonitoredSub     = "Skipped"
                RoleAssignment   = "Skipped"
                ResourceGroup    = "Skipped"
                Error            = $null
            }

            try {
                Set-AzContext -SubscriptionId $sId -ErrorAction Stop | Out-Null

                # Check if this sub has a batch monitor (anchor sub)
                $rgExists = Get-AzResourceGroup -Name $targetRgName -ErrorAction SilentlyContinue
                if ($rgExists) {
                    # Discover Dynatrace monitors in the RG
                    $listUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$targetRgName/providers/Dynatrace.Observability/monitors?api-version=2024-04-24"
                    $monList = $null
                    try { $monList = Invoke-ArmApi -Method "GET" -Url $listUrl } catch {}

                    if ($monList -and $monList.value -and $monList.value.Count -gt 0) {
                        # This is an anchor sub — delete the batch monitor(s)
                        foreach ($batchMon in $monList.value) {
                            $batchMonName = $batchMon.name
                            $batchMonId   = $batchMon.id
                            $batchPid     = if ($batchMon.identity) { $batchMon.identity.principalId } else { $null }

                            Write-Step $sName "Found batch monitor '$batchMonName', removing..."

                            # Remove tag rules
                            $trUrl = "https://management.azure.com${batchMonId}/tagRules/default?api-version=2024-04-24"
                            try { Invoke-ArmApi -Method "DELETE" -Url $trUrl | Out-Null } catch {}

                            # Delete the batch monitor
                            $delUrl = "https://management.azure.com${batchMonId}?api-version=2024-04-24"
                            try {
                                Invoke-ArmApi -Method "DELETE" -Url $delUrl | Out-Null
                                $pollAttempts = 0; $maxPoll = 20
                                while ($pollAttempts -lt $maxPoll) {
                                    Start-Sleep -Seconds 15; $pollAttempts++
                                    try { Invoke-ArmApi -Method "GET" -Url $delUrl | Out-Null }
                                    catch { break }
                                }
                                Write-OK $sName "Batch monitor '$batchMonName' deleted"
                                $result.MonitorResource = "Deleted"
                            }
                            catch {
                                Write-Err $sName "Failed to delete batch monitor: $_"
                                $result.MonitorResource = "Failed"
                            }

                            # Remove role assignments for the batch monitor's identity
                            if ($batchPid) {
                                $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $batchPid -RoleDefinitionName $roleName -ErrorAction SilentlyContinue)
                                foreach ($ra in $existing) {
                                    Remove-AzRoleAssignment -InputObject $ra -ErrorAction SilentlyContinue | Out-Null
                                }
                                if ($existing.Count -gt 0) { $result.RoleAssignment = "Removed" }
                            }
                        }

                        # Delete RG if forced
                        if ($ForceDeleteResourceGroups) {
                            Write-Step $sName "Force deleting resource group $targetRgName..."
                            Remove-AzResourceGroup -Name $targetRgName -Force | Out-Null
                            Write-OK $sName "Resource group deleted"
                            $result.ResourceGroup = "Deleted"
                        }
                        else {
                            Write-Skip $sName "Resource group $targetRgName preserved"
                            $result.ResourceGroup = "Preserved"
                        }
                    }
                    else {
                        # No monitors found — this might be a member sub, try removing monitored sub link from source
                        Write-Step $sName "No monitors found in RG, checking monitored subscription links..."
                        # Try removing from source monitor
                        $monSubUrl = "https://management.azure.com${monitorId}/monitoredSubscriptions/default?api-version=2024-04-24"
                        $monSubBody = @{
                            properties = @{
                                operation = "DeleteComplete"
                                monitoredSubscriptionList = @(@{ subscriptionId = "/subscriptions/$sId" })
                            }
                        }
                        try {
                            Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
                            Write-OK $sName "Monitored subscription link removed"
                            $result.MonitoredSub = "Removed"
                        }
                        catch {
                            Write-Skip $sName "No monitored subscription link found on source"
                            $result.MonitoredSub = "NotFound"
                        }
                    }
                }
                else {
                    # No RG — this is a member sub, remove from any batch monitors
                    # Try to remove monitored sub link from all known batch monitors
                    # For simplicity, try removing from the source monitor
                    $monSubUrl = "https://management.azure.com${monitorId}/monitoredSubscriptions/default?api-version=2024-04-24"
                    $monSubBody = @{
                        properties = @{
                            operation = "DeleteComplete"
                            monitoredSubscriptionList = @(@{ subscriptionId = "/subscriptions/$sId" })
                        }
                    }
                    try {
                        Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
                        Write-OK $sName "Monitored subscription link removed"
                        $result.MonitoredSub = "Removed"
                    }
                    catch {
                        Write-Skip $sName "No monitored subscription link found"
                        $result.MonitoredSub = "NotFound"
                    }
                }

                # Also check for role assignments from any Dynatrace monitor identity on this sub
                Write-Step $sName "Checking for Dynatrace role assignments..."
                $allRoles = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -RoleDefinitionName $roleName -ErrorAction SilentlyContinue)
                # We can't easily distinguish Dynatrace-assigned roles from others, so only remove if principalId is known
                if ($principalId) {
                    $dtRoles = @($allRoles | Where-Object { $_.ObjectId -eq $principalId })
                    foreach ($ra in $dtRoles) {
                        Remove-AzRoleAssignment -InputObject $ra -ErrorAction SilentlyContinue | Out-Null
                    }
                    if ($dtRoles.Count -gt 0 -and $result.RoleAssignment -ne "Removed") {
                        Write-OK $sName "Source monitor role assignment removed"
                        $result.RoleAssignment = "Removed"
                    }
                }
            }
            catch {
                Write-Err $sName "Error: $_"
                $result.Error = $_.ToString()
            }

            $results.Add($result)
            if (-not $result.Error) { $stateSync[$sId] = "Completed" }
            else { $stateSync[$sId] = "Failed" }

            $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
            Save-State -Path $StateFile -State $stateHash
        }
    }
    else {
        # Distributed offboard
        foreach ($sub in $pendingSubs) {
            Write-Host ""
            Write-Host "  -- $($sub.SubscriptionName) ($($sub.SubscriptionId)) --" -ForegroundColor White

            $result = Invoke-DistributedOffboarding -Sub $sub -DtRegion $dtRegion -TargetRgName $targetRgName -RoleName $roleName -ForceDeleteRg $ForceDeleteResourceGroups.IsPresent
            $results.Add($result)

            if (-not $result.Error) { $stateSync[$sub.SubscriptionId] = "Completed" }
            else { $stateSync[$sub.SubscriptionId] = "Failed" }

            $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
            Save-State -Path $StateFile -State $stateHash
        }
    }

    # Final state save
    $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
    Save-State -Path $StateFile -State $stateHash
}

###############################################################################
# Phase 3b: Configure source monitor tag rules (Centralized onboard only)
###############################################################################

if ($Action -eq "Onboard" -and $Mode -eq "Centralized") {
    Write-Phase "Phase 3b: Configure Source Monitor Tag Rules"

    $tagRulesUrl = "https://management.azure.com${monitorId}/tagRules/default?api-version=2024-04-24"
    $currentTR = $null
    try { $currentTR = Invoke-ArmApi -Method "GET" -Url $tagRulesUrl } catch {}

    $needsUpdate = $true
    if ($currentTR) {
        $lr = $currentTR.properties.logRules; $mr = $currentTR.properties.metricRules
        Write-Host "  Current: activity=$($lr.sendActivityLogs) sub=$($lr.sendSubscriptionLogs) metrics=$($mr.sendingMetrics)" -ForegroundColor Gray
        if (($sendActivityLogs -and $lr.sendActivityLogs -eq "Enabled") -and
            ($sendSubscriptionLogs -and $lr.sendSubscriptionLogs -eq "Enabled") -and
            ($sendMetrics -and $mr.sendingMetrics -eq "Enabled")) { $needsUpdate = $false }
    }

    if ($needsUpdate) {
        $trBody = @{
            properties = @{
                logRules    = @{ sendActivityLogs = if ($sendActivityLogs) {"Enabled"} else {"Disabled"}; sendSubscriptionLogs = if ($sendSubscriptionLogs) {"Enabled"} else {"Disabled"}; filteringTags = @() }
                metricRules = @{ sendingMetrics = if ($sendMetrics) {"Enabled"} else {"Disabled"}; filteringTags = @() }
            }
        }
        try { Invoke-ArmApi -Method "PUT" -Url $tagRulesUrl -Body $trBody | Out-Null; Write-Host "  + Tag rules updated" -ForegroundColor Green }
        catch { Write-Host "  X Failed to update tag rules: $_" -ForegroundColor Red }
    }
    else { Write-Host "  - Tag rules already configured" -ForegroundColor Yellow }
}

###############################################################################
# Phase 4 (HybridCentralized Onboard): Batch into groups of 15, one monitor per batch
###############################################################################

if ($Action -eq "Onboard" -and $Mode -eq "HybridCentralized") {
    $batchSize = 15
    Write-Phase "Phase 4: Hybrid Centralized Onboarding ($batchSize subs/monitor)"

    Write-Host "  Pending subs: $($pendingSubs.Count)" -ForegroundColor White

    $results      = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
    $stateSync    = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    foreach ($k in $state.Keys) { $stateSync[$k] = $state[$k] }

    # ---- Discovery: find existing batch monitors to prevent duplicates on retry ----
    $existingBatchMonitors = [ordered]@{}  # batchName -> hashtable with monitor info
    $maxExistingBatchNum = 0

    Write-Step "Discovery" "Scanning for existing batch monitors in '$targetRgName'..."
    foreach ($tSub in $targetSubscriptions) {
        try {
            Set-AzContext -SubscriptionId $tSub.SubscriptionId -ErrorAction Stop | Out-Null
            $rgCheck = Get-AzResourceGroup -Name $targetRgName -ErrorAction SilentlyContinue
            if (-not $rgCheck) { continue }

            $listUrl = "https://management.azure.com/subscriptions/$($tSub.SubscriptionId)/resourceGroups/$targetRgName/providers/Dynatrace.Observability/monitors?api-version=2024-04-24"
            $mons = @()
            try { $mons = @((Invoke-ArmApi -Method "GET" -Url $listUrl).value) } catch { continue }

            foreach ($m in $mons) {
                if ($m.name -match "^$([regex]::Escape($resourcePrefix))-batch-(\d+)$") {
                    $bn = [int]$matches[1]
                    if ($bn -gt $maxExistingBatchNum) { $maxExistingBatchNum = $bn }

                    # Count currently linked member subscriptions
                    $msUrl = "https://management.azure.com$($m.id)/monitoredSubscriptions?api-version=2024-04-24"
                    $memberCount = 0
                    try { $memberCount = @((Invoke-ArmApi -Method "GET" -Url $msUrl).value).Count } catch {}

                    $existingBatchMonitors[$m.name] = @{
                        BatchNum      = $bn
                        AnchorSubId   = $tSub.SubscriptionId
                        AnchorSubName = $tSub.SubscriptionName
                        MonitorName   = $m.name
                        MonitorId     = $m.id
                        PrincipalId   = $m.identity.principalId
                        MemberCount   = $memberCount
                        Capacity      = $batchSize - 1 - $memberCount   # -1 for anchor
                    }
                }
            }
        } catch { <# skip subs that can't be scanned #> }
    }

    if ($existingBatchMonitors.Count -gt 0) {
        Write-Host "  Found $($existingBatchMonitors.Count) existing batch monitor(s)" -ForegroundColor Yellow
    } else {
        Write-Step "Discovery" "No existing batch monitors found"
    }

    # ---- Pre-assign: route pending subs to existing batches with capacity ----
    $remainingPending = [System.Collections.Generic.List[PSCustomObject]]::new()
    $remainingPending.AddRange([PSCustomObject[]]$pendingSubs)

    foreach ($bName in $existingBatchMonitors.Keys) {
        $bi = $existingBatchMonitors[$bName]
        if ($bi.Capacity -le 0 -or $remainingPending.Count -eq 0) { continue }

        # Find pending subs that are NOT the anchor (anchor is already processed)
        $assignable = @($remainingPending | Where-Object { $_.SubscriptionId -ne $bi.AnchorSubId })
        $toTake = [math]::Min($bi.Capacity, $assignable.Count)
        if ($toTake -eq 0) { continue }

        Write-Host ""
        Write-Host "  ===== Existing Batch $($bi.BatchNum): adding $toTake member(s) to $bName (anchor=$($bi.AnchorSubName)) =====" -ForegroundColor Cyan

        $membersToLink = @($assignable | Select-Object -First $toTake)

        # Role assignments for all members
        foreach ($memSub in $membersToLink) {
            try {
                Set-AzContext -SubscriptionId $memSub.SubscriptionId -ErrorAction Stop | Out-Null
                Write-Step $memSub.SubscriptionName "Assigning $roleName..."
                $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$($memSub.SubscriptionId)" -ObjectId $bi.PrincipalId -RoleDefinitionName $roleName -ErrorAction SilentlyContinue)
                if ($existing.Count -eq 0) {
                    New-AzRoleAssignment -Scope "/subscriptions/$($memSub.SubscriptionId)" -ObjectId $bi.PrincipalId -RoleDefinitionName $roleName | Out-Null
                }
            } catch {
                Write-Err $memSub.SubscriptionName "Role assignment error: $_"
            }
        }

        # Bulk link all members in one API call
        Write-Step "Batch $($bi.BatchNum)" "Bulk-linking $($membersToLink.Count) member(s)..."
        $monSubUrl = "https://management.azure.com$($bi.MonitorId)/monitoredSubscriptions/default?api-version=2024-04-24"
        $monSubList = @($membersToLink | ForEach-Object { @{ subscriptionId = "/subscriptions/$($_.SubscriptionId)"; status = "Active" } })
        $monSubBody = @{
            properties = @{
                operation = "AddComplete"
                monitoredSubscriptionList = $monSubList
            }
        }
        $bulkOk = $false
        try {
            Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
            $bulkOk = $true
            Write-OK "Batch $($bi.BatchNum)" "Bulk-linked $($membersToLink.Count) member(s)"
        } catch {
            Write-Err "Batch $($bi.BatchNum)" "Bulk link failed: $_ — falling back to individual links"
        }

        # Record results (individual fallback if bulk failed)
        foreach ($memSub in $membersToLink) {
            $memResult = [PSCustomObject]@{
                SubscriptionId = $memSub.SubscriptionId; SubscriptionName = $memSub.SubscriptionName
                Mode = "HybridCentralized"; Batch = $bi.BatchNum; Role = "Member"
                ResourceGroup = "N/A"; MonitorResource = "N/A"; TagRules = "Inherited"
                MonitoredSub = "Skipped"; Error = $null
            }
            if ($bulkOk) {
                $memResult.MonitoredSub = "Created"
            } else {
                try {
                    $indBody = @{ properties = @{ operation = "AddComplete"; monitoredSubscriptionList = @(@{ subscriptionId = "/subscriptions/$($memSub.SubscriptionId)"; status = "Active" }) } }
                    Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $indBody | Out-Null
                    $memResult.MonitoredSub = "Created"
                    Write-OK $memSub.SubscriptionName "Linked individually"
                } catch {
                    $memResult.Error = $_.ToString()
                    Write-Err $memSub.SubscriptionName "Link failed: $_"
                }
            }
            $results.Add($memResult)
            if (-not $memResult.Error) { $stateSync[$memSub.SubscriptionId] = "Completed" }
            else { $stateSync[$memSub.SubscriptionId] = "Failed" }
            $remainingPending.Remove($memSub) | Out-Null
        }

        # Save state after batch
        $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
        Save-State -Path $StateFile -State $stateHash

        # Also mark anchor as completed if it's still pending (e.g. state file was lost)
        $pendingAnchor = $remainingPending | Where-Object { $_.SubscriptionId -eq $bi.AnchorSubId } | Select-Object -First 1
        if ($pendingAnchor) {
            Write-Skip $bi.AnchorSubName "Batch monitor '$bName' already exists (anchor)"
            $anchorResult = [PSCustomObject]@{
                SubscriptionId = $bi.AnchorSubId; SubscriptionName = $bi.AnchorSubName
                Mode = "HybridCentralized"; Batch = $bi.BatchNum; Role = "Anchor"
                ResourceGroup = "AlreadyExists"; MonitorResource = "AlreadyExists"
                TagRules = "Configured"; MonitoredSub = "N/A (anchor)"; Error = $null
            }
            $results.Add($anchorResult)
            $stateSync[$bi.AnchorSubId] = "Completed"
            $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
            Save-State -Path $StateFile -State $stateHash
            $remainingPending.Remove($pendingAnchor) | Out-Null
        }
    }

    # ---- Build new batches from remaining unassigned subs ----
    $pendingSubs = @($remainingPending)
    $batches = @()
    for ($i = 0; $i -lt $pendingSubs.Count; $i += $batchSize) {
        $end = [math]::Min($i + $batchSize - 1, $pendingSubs.Count - 1)
        $batches += ,@($pendingSubs[$i..$end])
    }

    if ($batches.Count -gt 0) {
        Write-Host ""
        Write-Host "  New batches needed: $($batches.Count) (for $($pendingSubs.Count) remaining subs)" -ForegroundColor White
    } elseif ($remainingPending.Count -eq 0 -and $existingBatchMonitors.Count -gt 0) {
        Write-Host ""
        Write-Host "  All pending subs assigned to existing batches" -ForegroundColor Green
    }

    # Start new batch numbering after existing batches to avoid name collisions
    $batchNum = $maxExistingBatchNum

    # Build batch metadata for phased processing
    $batchMeta = @()
    foreach ($batch in $batches) {
        $batchNum++
        $batchMeta += [PSCustomObject]@{
            BatchNum    = $batchNum
            AnchorSub   = $batch[0]
            MemberSubs  = if ($batch.Count -gt 1) { @($batch[1..($batch.Count - 1)]) } else { @() }
            MonitorName = "$resourcePrefix-batch-$batchNum"
            MonitorUrl  = $null
            MonitorId   = $null
            PrincipalId = $null
            AnchorResult = $null
            Submitted   = $false
            Provisioned = $false
            Failed      = $false
        }
    }

    if ($batchMeta.Count -eq 0) {
        # nothing to do — skip to final state save
    }
    else {

    # ===== Phase A: Submit all anchor monitor creates (fast — ARM PUTs return immediately) =====
    Write-Host ""
    Write-Host "  --- Phase A: Submitting $($batchMeta.Count) anchor monitor(s) ---" -ForegroundColor Yellow

    foreach ($bm in $batchMeta) {
        $anchorId   = $bm.AnchorSub.SubscriptionId
        $anchorName = $bm.AnchorSub.SubscriptionName
        $anchorResult = [PSCustomObject]@{
            SubscriptionId = $anchorId; SubscriptionName = $anchorName
            Mode = "HybridCentralized"; Batch = $bm.BatchNum; Role = "Anchor"
            ResourceGroup = "Skipped"; MonitorResource = "Skipped"; TagRules = "Skipped"
            MonitoredSub = "N/A (anchor)"; Error = $null
        }
        $bm.AnchorResult = $anchorResult

        try {
            Set-AzContext -SubscriptionId $anchorId -ErrorAction Stop | Out-Null

            # Create or verify RG
            Write-Step $anchorName "Checking resource group $targetRgName ..."
            $rgExists = Get-AzResourceGroup -Name $targetRgName -ErrorAction SilentlyContinue
            if ($rgExists) { $anchorResult.ResourceGroup = "AlreadyExists" }
            elseif ($createRg) {
                New-AzResourceGroup -Name $targetRgName -Location $dtRegion -Force | Out-Null
                $anchorResult.ResourceGroup = "Created"
            }
            else { throw "Resource group $targetRgName missing in $anchorName and create_resource_group is false" }

            # Register provider
            Wait-ForProviderRegistration -ProviderNamespace "Dynatrace.Observability" -Label $anchorName | Out-Null

            # Check if monitor already exists
            $bm.MonitorUrl = "https://management.azure.com/subscriptions/$anchorId/resourceGroups/$targetRgName/providers/Dynatrace.Observability/monitors/$($bm.MonitorName)?api-version=2024-04-24"
            $monExists = $false
            try { Invoke-ArmApi -Method "GET" -Url $bm.MonitorUrl | Out-Null; $monExists = $true } catch {}

            if ($monExists) {
                Write-Skip $anchorName "Batch monitor '$($bm.MonitorName)' already exists"
                $anchorResult.MonitorResource = "AlreadyExists"
                $bm.Provisioned = $true
            }
            else {
                Write-Step $anchorName "Submitting batch monitor '$($bm.MonitorName)' linked to $dtEnvironmentId..."
                $monBody = @{
                    location   = $dtRegion
                    identity   = @{ type = "SystemAssigned" }
                    properties = @{
                        monitoringStatus = "Enabled"
                        marketplaceSubscriptionStatus = "Active"
                        dynatraceEnvironmentProperties = @{
                            environmentInfo = @{
                                environmentId        = $dtEnvironmentId
                                ingestionKey         = $dtIngestionKey
                                landingURL           = $dtLandingUrl
                                logsIngestionEndpoint = $dtLogsEndpoint
                            }
                            accountInfo = @{
                                accountId = $dtAccountId
                                regionId  = $dtRegionId
                            }
                        }
                        userInfo = @{
                            firstName    = $userFirstName
                            lastName     = $userLastName
                            emailAddress = $userEmail
                            country      = $dtRegion
                        }
                    }
                }
                # Include planData (required for link-to-existing).
                # NEVER include top-level 'plan' — linked monitors are not Marketplace
                # purchases, ARM always rejects with CannotSetPlan.
                if ($sourcePlanData) { $monBody.properties["planData"] = $sourcePlanData }

                $jsonBody = $monBody | ConvertTo-Json -Depth 20 -Compress
                Write-Host "    [$anchorName] PUT body top-level keys: $($monBody.Keys -join ', ')" -ForegroundColor DarkGray
                Write-Host "    [$anchorName] Has top-level 'plan' key: $($monBody.ContainsKey('plan'))" -ForegroundColor DarkGray
                Write-Host "    [$anchorName] PUT body planData: $($monBody.properties.planData | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor DarkGray
                Invoke-ArmApi -Method "PUT" -Url $bm.MonitorUrl -Body $monBody | Out-Null
                $bm.Submitted = $true
                Write-OK $anchorName "Monitor create submitted"
            }
        }
        catch {
            Write-Err $anchorName "Batch $($bm.BatchNum) anchor error: $_"
            $anchorResult.Error = $_.ToString()
            $bm.Failed = $true
        }
    }

    # ===== Phase B: Poll all submitted monitors concurrently until provisioned =====
    $pendingMonitors = @($batchMeta | Where-Object { $_.Submitted -and -not $_.Provisioned -and -not $_.Failed })
    if ($pendingMonitors.Count -gt 0) {
        Write-Host ""
        Write-Host "  --- Phase B: Polling $($pendingMonitors.Count) monitor(s) for provisioning ---" -ForegroundColor Yellow
        $pollAttempts = 0; $maxPoll = 20
        while ($pendingMonitors.Count -gt 0 -and $pollAttempts -lt $maxPoll) {
            Start-Sleep -Seconds 15; $pollAttempts++
            $stillPending = @()
            foreach ($bm in $pendingMonitors) {
                try {
                    $monCheck = Invoke-ArmApi -Method "GET" -Url $bm.MonitorUrl
                    $provState = $monCheck.properties.provisioningState
                    if ($provState -eq "Succeeded") {
                        Write-OK $bm.AnchorSub.SubscriptionName "Monitor provisioned ($pollAttempts polls)"
                        $bm.AnchorResult.MonitorResource = "Created"
                        $bm.Provisioned = $true
                    }
                    elseif ($provState -eq "Failed") {
                        # Extract error details from the provisioned resource
                        $failDetail = "Monitor provisioning failed."
                        try {
                            $errBody = $monCheck | ConvertTo-Json -Depth 10 -Compress
                            Write-Host ""
                            Write-Host "  ============ PROVISIONING FAILURE DIAGNOSTICS ============" -ForegroundColor Red
                            Write-Host "  Full monitor state on failure:" -ForegroundColor Red
                            Write-Host "  $errBody" -ForegroundColor DarkGray
                            Write-Host ""

                            # Try to extract specific error from properties
                            $innerError = $null
                            try { $innerError = $monCheck.properties.error } catch {}
                            if ($innerError) {
                                $failDetail = "Provisioning failed: $($innerError | ConvertTo-Json -Depth 5 -Compress)"
                                Write-Host "  Error from properties: $failDetail" -ForegroundColor Red
                            }

                            if ($errBody -match 'CannotSetPlan') {
                                Write-Host "  ** CannotSetPlan detected in async failure! **" -ForegroundColor Red
                                Write-Host "  This should NOT happen — script does not send plan block." -ForegroundColor Red
                                Write-Host "  PUT body keys were: location, identity, properties (no plan)." -ForegroundColor Yellow
                                Write-Host "  Possible causes:" -ForegroundColor Yellow
                                Write-Host "    1. ARM is inferring plan from the source monitor's Marketplace subscription" -ForegroundColor White
                                Write-Host "    2. The planData itself is triggering plan association" -ForegroundColor White
                                Write-Host "    3. An Azure Policy or RP-level default is injecting the plan" -ForegroundColor White
                                Write-Host "  Try: Remove plan_data from config.json and re-run" -ForegroundColor Cyan
                                $failDetail = "CannotSetPlan (async) — ARM may be auto-associating plan from planData/Marketplace. See diagnostics above."
                            }
                            elseif ($errBody -match 'not linkable') {
                                $failDetail = "Environment '$dtEnvironmentId' is not linkable."
                                Write-Host ""
                                Write-Host "  ============ NOT LINKABLE DIAGNOSTICS ============" -ForegroundColor Red
                                Write-Host "  The Dynatrace environment rejected the linking request." -ForegroundColor Red
                                Write-Host "  This is a Dynatrace-side error, not an ARM error." -ForegroundColor Yellow
                                Write-Host ""
                                Write-Host "  Troubleshooting steps (in order of likelihood):" -ForegroundColor Yellow
                                Write-Host "  1. INGESTION KEY: Generate a fresh API token in Dynatrace" -ForegroundColor White
                                Write-Host "     (Apps > Access tokens > Create new token with 'Ingest metrics/logs')" -ForegroundColor Gray
                                Write-Host "     Then update ingestion_key in config.json and re-run." -ForegroundColor Gray
                                Write-Host "  2. ENVIRONMENT LINKING: Contact Dynatrace support to confirm" -ForegroundColor White
                                Write-Host "     environment '$dtEnvironmentId' is enabled for multi-subscription linking." -ForegroundColor Gray
                                Write-Host "  3. LINKING LIMIT: Ask Dynatrace support if the environment" -ForegroundColor White
                                Write-Host "     has reached its maximum number of linked monitors." -ForegroundColor Gray
                                Write-Host "  4. PLAN DATA: Verify plan_data in config.json matches" -ForegroundColor White
                                Write-Host "     the Marketplace offer (usageType, billingCycle, planDetails)." -ForegroundColor Gray
                                Write-Host "  ====================================================" -ForegroundColor Red
                                Write-Host ""
                            }
                        } catch {}

                        # Query Activity Log for the actual ARM/RP error details
                        try {
                            Write-Host "  Querying Activity Log for provisioning failure details..." -ForegroundColor Yellow
                            $monitorResourceId = $bm.MonitorUrl -replace '\?api-version=.*$', ''
                            $monitorResourceId = $monitorResourceId -replace '^https://management\.azure\.com', ''
                            # Use REST API to query Activity Log (avoids Az.Monitor module version inconsistencies)
                            $anchorSubId = $bm.AnchorSub.SubscriptionId
                            $startTimeUtc = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                            $filter = "eventTimestamp ge '$startTimeUtc' and resourceUri eq '$monitorResourceId'"
                            $alUrl = "https://management.azure.com/subscriptions/$anchorSubId/providers/microsoft.insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$filter"
                            $alResp = Invoke-ArmApi -Method GET -Url $alUrl -RetryCount 2
                            $alEntries = @()
                            if ($alResp -and $alResp.value) { $alEntries = @($alResp.value | Where-Object { $_.status.value -eq 'Failed' }) }
                            if ($alEntries.Count -gt 0) {
                                foreach ($log in $alEntries | Select-Object -First 5) {
                                    Write-Host "  Activity Log entry:" -ForegroundColor Red
                                    Write-Host "    Operation:  $($log.operationName.value)" -ForegroundColor White
                                    Write-Host "    Status:     $($log.status.value)" -ForegroundColor White
                                    Write-Host "    SubStatus:  $($log.subStatus.value)" -ForegroundColor White
                                    $statusMsg = $null
                                    try { $statusMsg = $log.properties.statusMessage } catch {}
                                    if ($statusMsg) {
                                        Write-Host "    StatusMsg:  $statusMsg" -ForegroundColor DarkGray
                                        if ($statusMsg -match 'not linkable') {
                                            Write-Host "  ** CONFIRMED: 'not linkable' in Activity Log **" -ForegroundColor Red
                                            Write-Host "  The Dynatrace environment rejected the linking request." -ForegroundColor Red
                                            Write-Host "  Root cause: API token (ingestion key) is invalid, expired," -ForegroundColor Yellow
                                            Write-Host "  from a different environment, or lacks required permissions." -ForegroundColor Yellow
                                            Write-Host "  FIX: In Dynatrace console (Apps > Access tokens), create a" -ForegroundColor Cyan
                                            Write-Host "  new token with 'Ingest metrics' + 'Ingest logs' scopes for" -ForegroundColor Cyan
                                            Write-Host "  environment '$dtEnvironmentId'. Update ingestion_key in config.json." -ForegroundColor Cyan
                                            $failDetail = "Environment not linkable — verify ingestion_key is a valid token from environment '$dtEnvironmentId' with Ingest scopes."
                                        }
                                        elseif ($statusMsg -match 'CannotSetPlan') {
                                            Write-Host "  ** CONFIRMED: CannotSetPlan in Activity Log! **" -ForegroundColor Red
                                            Write-Host "  The Dynatrace RP is internally trying to set a Marketplace plan." -ForegroundColor Red
                                            Write-Host "  This is caused by planData referencing a paid Marketplace offer." -ForegroundColor Yellow
                                            Write-Host "  FIX: Remove plan_data from config.json and re-run." -ForegroundColor Cyan
                                            $failDetail = "CannotSetPlan (Activity Log) — Dynatrace RP auto-sets plan from planData. Remove plan_data from config.json."
                                        }
                                    }
                                }
                            }
                            else {
                                Write-Host "  No failed Activity Log entries found in last 10 min." -ForegroundColor Yellow
                                Write-Host "  Check manually: Azure Portal > Subscription > Activity Log > filter by 'Dynatrace'" -ForegroundColor Gray
                            }
                        } catch {
                            Write-Host "  Activity Log query failed: $_" -ForegroundColor Yellow
                        }
                        Write-Host "  ====================================================" -ForegroundColor Red
                        Write-Host ""

                        $bm.AnchorResult.Error = $failDetail
                        $bm.Failed = $true
                        Write-Err $bm.AnchorSub.SubscriptionName $failDetail
                    }
                    else {
                        Write-Host "    [$($bm.AnchorSub.SubscriptionName)] Provisioning: $provState ($pollAttempts/$maxPoll)" -ForegroundColor Gray
                        $stillPending += $bm
                    }
                }
                catch {
                    Write-Host "    [$($bm.AnchorSub.SubscriptionName)] Poll error (retrying): $_" -ForegroundColor Yellow
                    $stillPending += $bm
                }
            }
            $pendingMonitors = $stillPending
            if ($pendingMonitors.Count -gt 0) {
                Write-Host "    Waiting... $($pendingMonitors.Count) still provisioning" -ForegroundColor Gray
            }
        }
        # Timeout any still pending
        foreach ($bm in $pendingMonitors) {
            $bm.AnchorResult.Error = "Monitor provisioning timed out after $($maxPoll * 15)s"
            $bm.Failed = $true
            Write-Err $bm.AnchorSub.SubscriptionName "Monitor provisioning timed out"
        }
    }

    # ===== Phase C: Configure tag rules, role assignments, and bulk-link members =====
    Write-Host ""
    Write-Host "  --- Phase C: Configuring $($batchMeta.Count) batch(es) ---" -ForegroundColor Yellow

    foreach ($bm in $batchMeta) {
        $anchorId     = $bm.AnchorSub.SubscriptionId
        $anchorName   = $bm.AnchorSub.SubscriptionName
        $anchorResult = $bm.AnchorResult

        Write-Host ""
        Write-Host "  ===== Batch $($bm.BatchNum)/$($batchMeta.Count): $($bm.MemberSubs.Count + 1) subs, anchor=$anchorName =====" -ForegroundColor Cyan

        # Record anchor result
        $results.Add($anchorResult)
        if (-not $anchorResult.Error) { $stateSync[$anchorId] = "Completed" }
        else { $stateSync[$anchorId] = "Failed" }
        $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
        Save-State -Path $StateFile -State $stateHash

        # Skip if anchor failed
        if ($bm.Failed) {
            Write-Err "Batch$($bm.BatchNum)" "Skipping $($bm.MemberSubs.Count) member subs due to anchor failure"
            foreach ($mem in $bm.MemberSubs) {
                $memResult = [PSCustomObject]@{
                    SubscriptionId = $mem.SubscriptionId; SubscriptionName = $mem.SubscriptionName
                    Mode = "HybridCentralized"; Batch = $bm.BatchNum; Role = "Member"
                    ResourceGroup = "Skipped"; MonitorResource = "N/A"; TagRules = "N/A"
                    MonitoredSub = "Skipped"; Error = "Skipped: batch anchor failed"
                }
                $results.Add($memResult)
                $stateSync[$mem.SubscriptionId] = "Failed"
            }
            $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
            Save-State -Path $StateFile -State $stateHash
            continue
        }

        # Get monitor identity
        try {
            $batchMon = Invoke-ArmApi -Method "GET" -Url $bm.MonitorUrl
            $bm.MonitorId   = $batchMon.id
            $bm.PrincipalId = $batchMon.identity.principalId
        } catch {
            Write-Err $anchorName "Failed to read batch monitor: $_"
            continue
        }

        # Configure tag rules on the batch monitor (with retry)
        Set-AzContext -SubscriptionId $anchorId -ErrorAction SilentlyContinue | Out-Null
        Write-Step $anchorName "Configuring tag rules on batch monitor..."
        $trUrl = "https://management.azure.com$($bm.MonitorId)/tagRules/default?api-version=2024-04-24"
        $trBody = @{
            properties = @{
                logRules    = @{ sendActivityLogs = if ($sendActivityLogs) {"Enabled"} else {"Disabled"}; sendSubscriptionLogs = if ($sendSubscriptionLogs) {"Enabled"} else {"Disabled"}; filteringTags = @() }
                metricRules = @{ sendingMetrics = if ($sendMetrics) {"Enabled"} else {"Disabled"}; filteringTags = @() }
            }
        }
        $retries = 0; $trOk = $false
        while ($retries -lt 6 -and -not $trOk) {
            try { Invoke-ArmApi -Method "PUT" -Url $trUrl -Body $trBody | Out-Null; $trOk = $true }
            catch { $retries++; if ($retries -lt 6) { Start-Sleep 15 } else { throw } }
        }
        Write-OK $anchorName "Tag rules configured"
        $anchorResult.TagRules = "Configured"

        # Assign Monitoring Reader for anchor sub
        if ($bm.PrincipalId) {
            $existRole = @(Get-AzRoleAssignment -Scope "/subscriptions/$anchorId" -ObjectId $bm.PrincipalId -RoleDefinitionName $roleName -ErrorAction SilentlyContinue)
            if ($existRole.Count -eq 0) {
                New-AzRoleAssignment -Scope "/subscriptions/$anchorId" -ObjectId $bm.PrincipalId -RoleDefinitionName $roleName | Out-Null
                Write-OK $anchorName "$roleName assigned to batch monitor identity"
            }
        }

        # Skip if no members
        if ($bm.MemberSubs.Count -eq 0) { continue }

        # Role assignments for all members
        foreach ($mem in $bm.MemberSubs) {
            try {
                Set-AzContext -SubscriptionId $mem.SubscriptionId -ErrorAction Stop | Out-Null
                Write-Step $mem.SubscriptionName "Assigning $roleName..."
                $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$($mem.SubscriptionId)" -ObjectId $bm.PrincipalId -RoleDefinitionName $roleName -ErrorAction SilentlyContinue)
                if ($existing.Count -eq 0) {
                    New-AzRoleAssignment -Scope "/subscriptions/$($mem.SubscriptionId)" -ObjectId $bm.PrincipalId -RoleDefinitionName $roleName | Out-Null
                }
            } catch {
                Write-Err $mem.SubscriptionName "Role assignment error: $_"
            }
        }

        # Bulk link all members in one API call
        Write-Step "Batch $($bm.BatchNum)" "Bulk-linking $($bm.MemberSubs.Count) member(s)..."
        $monSubUrl = "https://management.azure.com$($bm.MonitorId)/monitoredSubscriptions/default?api-version=2024-04-24"
        $monSubList = @($bm.MemberSubs | ForEach-Object { @{ subscriptionId = "/subscriptions/$($_.SubscriptionId)"; status = "Active" } })
        $monSubBody = @{
            properties = @{
                operation = "AddComplete"
                monitoredSubscriptionList = $monSubList
            }
        }
        $bulkOk = $false
        try {
            Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $monSubBody | Out-Null
            $bulkOk = $true
            Write-OK "Batch $($bm.BatchNum)" "Bulk-linked $($bm.MemberSubs.Count) member(s)"
        } catch {
            Write-Err "Batch $($bm.BatchNum)" "Bulk link failed: $_ — falling back to individual links"
        }

        # Record member results (individual fallback if bulk failed)
        foreach ($mem in $bm.MemberSubs) {
            $memResult = [PSCustomObject]@{
                SubscriptionId = $mem.SubscriptionId; SubscriptionName = $mem.SubscriptionName
                Mode = "HybridCentralized"; Batch = $bm.BatchNum; Role = "Member"
                ResourceGroup = "N/A"; MonitorResource = "N/A"; TagRules = "Inherited"
                MonitoredSub = "Skipped"; Error = $null
            }
            if ($bulkOk) {
                $memResult.MonitoredSub = "Created"
            } else {
                try {
                    $indBody = @{ properties = @{ operation = "AddComplete"; monitoredSubscriptionList = @(@{ subscriptionId = "/subscriptions/$($mem.SubscriptionId)"; status = "Active" }) } }
                    Invoke-ArmApi -Method "PUT" -Url $monSubUrl -Body $indBody | Out-Null
                    $memResult.MonitoredSub = "Created"
                    Write-OK $mem.SubscriptionName "Linked individually"
                } catch {
                    $memResult.Error = $_.ToString()
                    Write-Err $mem.SubscriptionName "Link failed: $_"
                }
            }
            $results.Add($memResult)
            if (-not $memResult.Error) { $stateSync[$mem.SubscriptionId] = "Completed" }
            else { $stateSync[$mem.SubscriptionId] = "Failed" }
        }

        # Save state after each batch
        $stateHash = @{}; foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
        Save-State -Path $StateFile -State $stateHash
    }

    } # end if ($batchMeta.Count -gt 0)

    # Final state save and jump to summary
    $stateHash = @{}
    foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
    Save-State -Path $StateFile -State $stateHash
}

###############################################################################
# Phase 4: Onboard subscriptions — Centralized / Distributed (with parallelism)
###############################################################################

if ($Action -eq "Onboard" -and $Mode -ne "HybridCentralized") {

if ($Mode -eq "Centralized") {
    $phaseMsg = "Phase 4: Onboard Subscriptions (Centralized - " + $ThrottleLimit + " parallel)"
    Write-Phase $phaseMsg
}
else {
    $phaseMsg = "Phase 4: Link Subscriptions (Distributed - " + $ThrottleLimit + " parallel)"
    Write-Phase $phaseMsg
}
$results      = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$stateSync    = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
foreach ($k in $state.Keys) { $stateSync[$k] = $state[$k] }

# Determine if we can use ForEach-Object -Parallel (PS 7+)
$canParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($ThrottleLimit -gt 1)

if ($canParallel) {
    # ------ PowerShell 7+: native parallelism ------------------------------------------------------------------------
    # Wrapped in Invoke-Expression so PS 5.1 never parses the -Parallel syntax
    $parallelScript = @'
$pendingSubs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $sub             = $_
    $localMode       = $using:Mode
    $localMonitorId  = $using:monitorId
    $localPrincipalId = $using:principalId
    $localRoleName   = $using:roleName
    $localDiagName   = $using:diagSettingName
    $localDtRegion   = $using:dtRegion
    $localDtEnvId    = $using:dtEnvironmentId
    $localDtKey      = $using:dtIngestionKey
    $localDtUrl      = $using:dtLandingUrl
    $localDtLogs     = $using:dtLogsEndpoint
    $localDtAcctId   = $using:dtAccountId
    $localDtRegionId = $using:dtRegionId
    $localTargetRg   = $using:targetRgName
    $localCreateRg   = $using:createRg
    $localCtx        = $using:ctx
    $localUserFirst  = $using:userFirstName
    $localUserLast   = $using:userLastName
    $localSourcePlan = $using:sourcePlan
    $localPlanData   = $using:sourcePlanData
    $resultsBag      = $using:results
    $stateBag        = $using:stateSync

    # Each parallel runspace needs its own Az context
    $azToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -ErrorAction SilentlyContinue)
    if (-not $azToken) { Connect-AzAccount -ErrorAction Stop | Out-Null }

    $sName = $sub.SubscriptionName
    $sId   = $sub.SubscriptionId

    Write-Host "  -- $sName ($sId) --" -ForegroundColor White

    $result = $null

    if ($localMode -eq "Centralized") {
        $result = [PSCustomObject]@{
            SubscriptionId = $sId; SubscriptionName = $sName; Mode = "Centralized"
            RoleAssignment = "Skipped"; MonitoredSub = "Skipped"; DiagnosticSetting = "Skipped"; Error = $null
        }
        try {
            $existing = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $localPrincipalId -RoleDefinitionName $localRoleName -ErrorAction SilentlyContinue)
            if ($existing.Count -gt 0) { $result.RoleAssignment = "AlreadyExists" }
            else {
                New-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $localPrincipalId -RoleDefinitionName $localRoleName | Out-Null
                $result.RoleAssignment = "Created"
            }

            $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
            $tkn = if ($token.Token -is [System.Security.SecureString]) {
                $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token.Token)
                $t = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b); $t
            } else { $token.Token }
            $hdrs = @{ "Authorization" = "Bearer $tkn"; "Content-Type" = "application/json" }

            $monSubBody = @{ properties = @{ operation = "AddComplete"; monitoredSubscriptionList = @(@{ subscriptionId = "/subscriptions/$sId"; status = "Active" }) } }
            Invoke-RestMethod -Method PUT -Uri "https://management.azure.com${localMonitorId}/monitoredSubscriptions/default?api-version=2024-04-24" -Headers $hdrs -Body ($monSubBody | ConvertTo-Json -Depth 20 -Compress) | Out-Null
            $result.MonitoredSub = "Created"
            Write-Host "  [$sName] + Onboarded (Centralized)" -ForegroundColor Green
        }
        catch {
            $result.Error = $_.ToString()
            Write-Host "  [$sName] X Error: $_" -ForegroundColor Red
        }
    }
    else {
        $resName = $sub.ResourceName
        $result = [PSCustomObject]@{
            SubscriptionId = $sId; SubscriptionName = $sName; Mode = "Distributed"
            ResourceGroup = "Skipped"; MonitorResource = "Skipped"; ManagedIdentity = "Skipped"; TagRules = "Skipped"; Error = $null
        }
        try {
            Set-AzContext -SubscriptionId $sId -ErrorAction Stop | Out-Null

            # Get token FIRST so we can use REST API for RG ops (avoids parallel context race)
            $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
            $tkn = if ($token.Token -is [System.Security.SecureString]) {
                $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token.Token)
                $t = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b); $t
            } else { $token.Token }
            $hdrs = @{ "Authorization" = "Bearer $tkn"; "Content-Type" = "application/json" }

            # Check/create RG via REST API with explicit subscription in URL (parallel-safe)
            $rgUrl = "https://management.azure.com/subscriptions/$sId/resourcegroups/${localTargetRg}?api-version=2021-04-01"
            $rgFound = $false
            try { Invoke-RestMethod -Method GET -Uri $rgUrl -Headers $hdrs | Out-Null; $rgFound = $true } catch {}
            if ($rgFound) { $result.ResourceGroup = "AlreadyExists" }
            elseif ($localCreateRg) {
                $rgBody = @{ location = $localDtRegion } | ConvertTo-Json -Compress
                Invoke-RestMethod -Method PUT -Uri $rgUrl -Headers $hdrs -Body $rgBody | Out-Null
                $result.ResourceGroup = "Created"
            }

            # Check/register Dynatrace.Observability provider via REST API (parallel-safe)
            $provUrl = "https://management.azure.com/subscriptions/$sId/providers/Dynatrace.Observability?api-version=2021-04-01"
            $provRegistered = $false
            try { $provResp = Invoke-RestMethod -Method GET -Uri $provUrl -Headers $hdrs; if ($provResp.registrationState -eq "Registered") { $provRegistered = $true } } catch {}
            if (-not $provRegistered) {
                $regUrl = "https://management.azure.com/subscriptions/$sId/providers/Dynatrace.Observability/register?api-version=2021-04-01"
                try { Invoke-RestMethod -Method POST -Uri $regUrl -Headers $hdrs | Out-Null } catch {}
                $elapsed = 0
                while ($elapsed -lt 120) {
                    Start-Sleep 10; $elapsed += 10
                    try { $c = Invoke-RestMethod -Method GET -Uri $provUrl -Headers $hdrs; if ($c.registrationState -eq "Registered") { break } } catch {}
                }
            }

            $monUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$localTargetRg/providers/Dynatrace.Observability/monitors/${resName}?api-version=2024-04-24"
            $monExists = $false
            try { Invoke-RestMethod -Method GET -Uri $monUrl -Headers $hdrs | Out-Null; $monExists = $true } catch {}

            if ($monExists) { $result.MonitorResource = "AlreadyExists" }
            else {
                $monBody = @{
                    location = $localDtRegion; identity = @{ type = "SystemAssigned" }
                    properties = @{
                        monitoringStatus = "Enabled"
                        marketplaceSubscriptionStatus = "Active"
                        dynatraceEnvironmentProperties = @{
                            environmentInfo = @{ environmentId = $localDtEnvId; ingestionKey = $localDtKey; landingURL = $localDtUrl; logsIngestionEndpoint = $localDtLogs }
                            accountInfo = @{ accountId = $localDtAcctId; regionId = $localDtRegionId }
                        }
                        userInfo = @{ firstName = $localUserFirst; lastName = $localUserLast; emailAddress = $localCtx.Account.Id; country = $localDtRegion }
                    }
                }
                # Include planData (required for link-to-existing).
                # NEVER include top-level 'plan' — CannotSetPlan on all linked monitors.
                if ($localPlanData) { $monBody.properties["planData"] = $localPlanData }

                Write-Host "    [$sName] PUT body top-level keys: $($monBody.Keys -join ', ')" -ForegroundColor DarkGray
                Write-Host "    [$sName] Has top-level 'plan' key: $($monBody.ContainsKey('plan'))" -ForegroundColor DarkGray
                Write-Host "    [$sName] PUT body planData: $($monBody.properties.planData | ConvertTo-Json -Depth 5 -Compress)" -ForegroundColor DarkGray
                Invoke-RestMethod -Method PUT -Uri $monUrl -Headers $hdrs -Body ($monBody | ConvertTo-Json -Depth 20 -Compress) | Out-Null

                # Poll provisioning state — ARM PUT returns immediately but provisioning is async
                $pollAttempts = 0; $maxPoll = 20
                while ($pollAttempts -lt $maxPoll) {
                    Start-Sleep -Seconds 15
                    $pollAttempts++
                    $token3 = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
                    $tkn3 = if ($token3.Token -is [System.Security.SecureString]) {
                        $b3 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token3.Token)
                        $t3 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b3)
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b3); $t3
                    } else { $token3.Token }
                    $hdrs3 = @{ "Authorization" = "Bearer $tkn3"; "Content-Type" = "application/json" }
                    $monCheck = Invoke-RestMethod -Method GET -Uri $monUrl -Headers $hdrs3
                    $provState = $monCheck.properties.provisioningState
                    if ($provState -eq "Succeeded") {
                        $result.MonitorResource = "Created"
                        break
                    }
                    elseif ($provState -eq "Failed") {
                        throw "Monitor provisioning failed (state: Failed). Check Azure Activity Log for sub $sName."
                    }
                    Write-Host "    [$sName] Provisioning: $provState ($pollAttempts/$maxPoll)..." -ForegroundColor Gray
                }
                if ($pollAttempts -ge $maxPoll) {
                    throw "Monitor provisioning timed out after $($maxPoll * 15)s for $sName."
                }
            }

            # Verify managed identity — ARM sometimes returns provisioningState=Succeeded
            # with a null system-assigned identity. Without it, Dynatrace's metric-status
            # callback times out (GatewayTimeout) and the sub sits in "Waiting for data...".
            # Force-PATCH to mint one, then grant Monitoring Reader for metric reads.
            $newMon = Invoke-RestMethod -Method GET -Uri $monUrl -Headers $hdrs
            $newPid = $null
            try { $newPid = $newMon.identity.principalId } catch {}
            if (-not $newPid) {
                Write-Host "    [$sName] Managed identity missing — forcing SystemAssigned (PATCH)..." -ForegroundColor Yellow
                $idBody = @{ identity = @{ type = "SystemAssigned" } } | ConvertTo-Json -Compress
                try { Invoke-RestMethod -Method PATCH -Uri $monUrl -Headers $hdrs -Body $idBody | Out-Null } catch {}
                $idAttempts = 0
                while ($idAttempts -lt 8 -and -not $newPid) {
                    Start-Sleep -Seconds 10; $idAttempts++
                    try { $newMon = Invoke-RestMethod -Method GET -Uri $monUrl -Headers $hdrs; $newPid = $newMon.identity.principalId } catch {}
                }
            }
            if ($newPid) {
                $result.ManagedIdentity = "Verified"
                $existRole = @(Get-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $newPid -RoleDefinitionName "Monitoring Reader" -ErrorAction SilentlyContinue)
                if ($existRole.Count -eq 0) {
                    New-AzRoleAssignment -Scope "/subscriptions/$sId" -ObjectId $newPid -RoleDefinitionName "Monitoring Reader" | Out-Null
                }
            }
            else {
                $result.ManagedIdentity = "Missing"
                Write-Host "    [$sName] Managed identity still missing after PATCH — metrics may not flow" -ForegroundColor Red
            }

            $trUrl = "https://management.azure.com/subscriptions/$sId/resourceGroups/$localTargetRg/providers/Dynatrace.Observability/monitors/${resName}/tagRules/default?api-version=2024-04-24"
            $trBody = @{
                properties = @{
                    logRules = @{ sendActivityLogs = if ($sub.SendActivityLogs) {"Enabled"} else {"Disabled"}; sendSubscriptionLogs = if ($sub.SendSubscriptionLogs) {"Enabled"} else {"Disabled"}; filteringTags = @() }
                    metricRules = @{ sendingMetrics = if ($sub.SendMetrics) {"Enabled"} else {"Disabled"}; filteringTags = @() }
                }
            }
            $retries = 0; $ok = $false
            while ($retries -lt 6 -and -not $ok) {
                try {
                    $token2 = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
                    $tkn2 = if ($token2.Token -is [System.Security.SecureString]) {
                        $b2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token2.Token)
                        $t2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($b2)
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2); $t2
                    } else { $token2.Token }
                    $hdrs2 = @{ "Authorization" = "Bearer $tkn2"; "Content-Type" = "application/json" }
                    Invoke-RestMethod -Method PUT -Uri $trUrl -Headers $hdrs2 -Body ($trBody | ConvertTo-Json -Depth 20 -Compress) | Out-Null
                    $ok = $true
                }
                catch { $retries++; if ($retries -lt 6) { Start-Sleep 15 } else { throw } }
            }
            $result.TagRules = "Configured"
            Write-Host "  [$sName] + Linked (Distributed)" -ForegroundColor Green
        }
        catch {
            $result.Error = $_.ToString()
            Write-Host "  [$sName] X Error: $_" -ForegroundColor Red
        }
    }

    $resultsBag.Add($result)
    if (-not $result.Error) { $stateBag[$sub.SubscriptionId] = "Completed" }
    else { $stateBag[$sub.SubscriptionId] = "Failed" }
}
'@
    Invoke-Expression $parallelScript
}
else {
    # ------ PowerShell 5.1 or sequential: simple loop ------------------------------------------------
    if ($ThrottleLimit -gt 1 -and $PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "  NOTE: Parallel execution requires PowerShell 7+. Running sequentially." -ForegroundColor Yellow
    }

    foreach ($sub in $pendingSubs) {
        Write-Host ""
        Write-Host "  -- $($sub.SubscriptionName) ($($sub.SubscriptionId)) --" -ForegroundColor White

        $result = $null
        if ($Mode -eq "Centralized") {
            $result = Invoke-CentralizedOnboarding -Sub $sub -MonitorId $monitorId -PrincipalId $principalId -RoleName $roleName -DiagSettingName $diagSettingName
        }
        else {
            $result = Invoke-DistributedOnboarding -Sub $sub -DtRegion $dtRegion -DtEnvironmentId $dtEnvironmentId -DtIngestionKey $dtIngestionKey -DtLandingUrl $dtLandingUrl -DtLogsEndpoint $dtLogsEndpoint -DtAccountId $dtAccountId -DtRegionId $dtRegionId -TargetRgName $targetRgName -CreateRg $createRg -UserEmail $userEmail -UserFirstName $userFirstName -UserLastName $userLastName -SourcePlan $sourcePlan -PlanData $sourcePlanData
        }

        $results.Add($result)

        if (-not $result.Error) {
            $stateSync[$sub.SubscriptionId] = "Completed"
        }
        else {
            $stateSync[$sub.SubscriptionId] = "Failed"
        }

        # Save state after each sub (crash-safe)
        $stateHash = @{}
        foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
        Save-State -Path $StateFile -State $stateHash
    }
}

# Final state save
$stateHash = @{}
foreach ($k in $stateSync.Keys) { $stateHash[$k] = $stateSync[$k] }
Save-State -Path $StateFile -State $stateHash

} # end if ($Action -eq "Onboard" -and $Mode -ne "HybridCentralized")

###############################################################################
# Phase 5: Summary
###############################################################################

Write-Phase "Phase 5: Summary"

Set-AzContext -SubscriptionId $dtSubscriptionId -ErrorAction SilentlyContinue | Out-Null

$allResults = @($results.ToArray())

if ($Action -eq "Offboard") {
    # Offboard summary
    if ($Mode -eq "Centralized") {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, SubscriptionId, MonitoredSub, RoleAssignment, DiagnosticSetting, Error
    }
    elseif ($Mode -eq "HybridCentralized") {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, SubscriptionId, MonitorResource, MonitoredSub, RoleAssignment, ResourceGroup, Error
    }
    else {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, SubscriptionId, TagRules, MonitorResource, RoleAssignment, ResourceGroup, Error
    }

    $removed = @($allResults | Where-Object {
        ($_.PSObject.Properties['MonitorResource'] -and $_.MonitorResource -eq "Deleted") -or
        ($_.PSObject.Properties['MonitoredSub'] -and $_.MonitoredSub -eq "Removed")
    }).Count
    $notFound = @($allResults | Where-Object {
        ($_.PSObject.Properties['MonitorResource'] -and $_.MonitorResource -eq "NotFound") -and
        ($_.PSObject.Properties['MonitoredSub'] -and $_.MonitoredSub -eq "NotFound")
    }).Count
    $rgDeleted   = @($allResults | Where-Object { $_.PSObject.Properties['ResourceGroup'] -and $_.ResourceGroup -eq "Deleted" }).Count
    $rgPreserved = @($allResults | Where-Object { $_.PSObject.Properties['ResourceGroup'] -and $_.ResourceGroup -eq "Preserved" }).Count
    $errors  = @($allResults | Where-Object { $null -ne $_.Error }).Count

    Write-Host "  Action:            Offboard"
    Write-Host "  Mode:              $Mode"
    Write-Host "  Environment:       $dtEnvironmentId"
    Write-Host "  Total processed:   $($allResults.Count) (this run)"
    Write-Host "  Previously done:   $skippedCount (from state file)"
    Write-Host "  Removed:           $removed" -ForegroundColor Green
    Write-Host "  Not found:         $notFound" -ForegroundColor Yellow
    if ($rgDeleted -gt 0)   { Write-Host "  RGs deleted:       $rgDeleted" -ForegroundColor Red }
    if ($rgPreserved -gt 0) { Write-Host "  RGs preserved:     $rgPreserved (reusable)" -ForegroundColor Yellow }
    if ($errors -gt 0) {
        Write-Host "  Errors:            $errors (re-run to retry)" -ForegroundColor Red
    }
    else {
        Write-Host "  Errors:            0" -ForegroundColor Green
    }
}
else {
    # Onboard summary
    if ($Mode -eq "Centralized") {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, SubscriptionId, RoleAssignment, MonitoredSub, DiagnosticSetting, Error
    }
    elseif ($Mode -eq "HybridCentralized") {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, Batch, Role, ResourceGroup, MonitorResource, MonitoredSub, TagRules, Error
    }
    else {
        $allResults | Format-Table -AutoSize -Property SubscriptionName, SubscriptionId, ResourceGroup, MonitorResource, ManagedIdentity, TagRules, Error
    }

    $createdField = if ($Mode -eq "Centralized") { "MonitoredSub" } elseif ($Mode -eq "HybridCentralized") { "MonitoredSub" } else { "MonitorResource" }
    $created  = @($allResults | Where-Object { $_.$createdField -eq "Created" }).Count
    $existed  = @($allResults | Where-Object { $_.$createdField -match "Already" }).Count
    $errors   = @($allResults | Where-Object { $null -ne $_.Error }).Count

    Write-Host "  Action:            Onboard"
    Write-Host "  Mode:              $Mode"
    Write-Host "  Environment:       $dtEnvironmentId"
    if ($Mode -eq "HybridCentralized") {
        $batchMonitors = @($allResults | Where-Object { $_.Role -eq "Anchor" -and -not $_.Error }).Count
        $totalBatches  = @($allResults | Where-Object { $_.Role -eq "Anchor" }).Count
        Write-Host "  Batch monitors:    $batchMonitors/$totalBatches created" -ForegroundColor Cyan
        Write-Host "  Resource groups:   $batchMonitors (1 per batch)" -ForegroundColor Cyan
    }
    Write-Host "  Total processed:   $($allResults.Count) (this run)"
    Write-Host "  Previously done:   $skippedCount (from state file)"
    Write-Host "  Newly onboarded:   $created" -ForegroundColor Green
    Write-Host "  Already existed:   $existed" -ForegroundColor Yellow
    if ($errors -gt 0) {
        Write-Host "  Errors:            $errors (re-run to retry failed subs)" -ForegroundColor Red
    }
    else {
        Write-Host "  Errors:            0" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "  State saved to:    $StateFile" -ForegroundColor Gray
Write-Host "  Total elapsed:     $($script:scriptTimer.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
if ($errors -gt 0) {
    Write-Host "  To retry failures: re-run the same command (completed subs are skipped)." -ForegroundColor Gray
}

return $allResults