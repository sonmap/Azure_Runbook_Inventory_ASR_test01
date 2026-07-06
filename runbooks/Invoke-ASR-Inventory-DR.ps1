<#
.SYNOPSIS
  Inventory 기반 ASR DR 후처리 Runbook 예제

.DESCRIPTION
  - ASR Recovery Plan Post Action으로 실행
  - Inventory CSV를 읽어서 Priority 순서대로 처리
  - AP VM 내부 Tomcat 기동 스크립트 실행
  - URL Health Check 수행
  - Traffic Manager DR Endpoint 활성화 예시 포함

.PARAMETER InventoryUrl
  Storage Blob 또는 Git Raw URL 형태의 CSV 경로

.EXAMPLE
  .\Invoke-ASR-Inventory-DR.ps1 -InventoryUrl "https://raw.githubusercontent.com/sonmap/Azure_Runbook_Inventory_ASR_test01/main/inventory/dr-inventory.csv" -Environment "DR"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InventoryUrl,

    [string]$Environment = "DR"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Convert-CustomParamToHash {
    param([string]$CustomParam)

    $kv = @{}
    if ([string]::IsNullOrWhiteSpace($CustomParam)) {
        return $kv
    }

    $CustomParam -split ';' | ForEach-Object {
        $pair = $_ -split '=', 2
        if ($pair.Count -eq 2) { $kv[$pair[0]] = $pair[1] }
    }

    return $kv
}

function Invoke-UrlHealthCheck {
    param(
        [string]$Url,
        [int]$RetryCount = 10,
        [int]$RetryIntervalSec = 30
    )

    # Inventory placeholder가 남아 있으면 실수 방지용으로 실패 처리
    if ($Url -like "*<*>") {
        throw "HealthTarget contains placeholder. Update inventory first: $Url"
    }

    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            Write-Log "Health check try $i/$RetryCount : $Url"
            $res = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10

            if ($res.StatusCode -eq 200 -or $res.StatusCode -eq 302) {
                Write-Log "Health check success: HTTP $($res.StatusCode)"
                return $true
            }
        }
        catch {
            Write-Log "Health check failed: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds $RetryIntervalSec
    }

    return $false
}

function Invoke-LinuxScriptOnVm {
    param(
        [string]$ResourceGroupName,
        [string]$VmName,
        [string]$ScriptPath,
        [string]$CustomParam
    )

    $script = @"
sudo bash $ScriptPath '$CustomParam'
"@

    Write-Log "Invoke VM RunCommand: $VmName / $ScriptPath"

    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName $VmName `
        -CommandId "RunShellScript" `
        -ScriptString $script

    $result.Value.Message
}

function Enable-TrafficManagerDrEndpoint {
    param(
        [string]$ResourceGroupName,
        [string]$ProfileName,
        [string]$CustomParam
    )

    # CustomParam 예: PROFILE=tm-asrtest01-tomcat-dr;DR_ENDPOINT=dr-japan-tomcat
    $kv = Convert-CustomParamToHash -CustomParam $CustomParam
    $endpointName = $kv["DR_ENDPOINT"]

    if (-not $endpointName) {
        throw "CustomParam must include DR_ENDPOINT"
    }

    Write-Log "Enable Traffic Manager DR endpoint. Profile=$ProfileName Endpoint=$endpointName"

    $profile = Get-AzTrafficManagerProfile `
        -Name $ProfileName `
        -ResourceGroupName $ResourceGroupName

    $endpoint = Get-AzTrafficManagerEndpoint `
        -Name $endpointName `
        -Type ExternalEndpoints `
        -ProfileName $ProfileName `
        -ResourceGroupName $ResourceGroupName

    $endpoint.EndpointStatus = "Enabled"
    Set-AzTrafficManagerEndpoint -TrafficManagerEndpoint $endpoint | Out-Null

    Write-Log "Traffic Manager DR endpoint enabled. FQDN=$($profile.RelativeDnsName).trafficmanager.net"
}

Write-Log "Runbook start"
Write-Log "InventoryUrl=$InventoryUrl Environment=$Environment"

Connect-AzAccount -Identity | Out-Null

$csvText = Invoke-RestMethod -Uri $InventoryUrl
$inventory = $csvText | ConvertFrom-Csv

$targets = $inventory | Where-Object {
    $_.Enabled -eq "true" -and $_.Environment -eq $Environment
}

if (-not $targets) {
    throw "No enabled targets found for Environment=$Environment"
}

$priorities = $targets |
    Select-Object -ExpandProperty Priority -Unique |
    Sort-Object { [int]$_ }

foreach ($priority in $priorities) {
    Write-Log "===== Priority $priority start ====="

    $group = $targets | Where-Object { [int]$_.Priority -eq [int]$priority }

    foreach ($server in $group) {
        Write-Log "Target: $($server.ServiceGroup) / $($server.VMName) / StartMode=$($server.StartMode)"

        if ($server.StartMode -eq "script") {
            Invoke-LinuxScriptOnVm `
                -ResourceGroupName $server.ResourceGroup `
                -VmName $server.VMName `
                -ScriptPath $server.StartScript `
                -CustomParam $server.CustomParam
        }
        elseif ($server.StartMode -eq "custom" -and $server.StartScript -eq "Enable-TrafficManager-DR") {
            Enable-TrafficManagerDrEndpoint `
                -ResourceGroupName $server.ResourceGroup `
                -ProfileName $server.VMName `
                -CustomParam $server.CustomParam
        }
        elseif ($server.StartMode -eq "vm_only") {
            Write-Log "VM only target. No internal script executed."
        }
        else {
            throw "Unsupported StartMode or StartScript: $($server.StartMode) / $($server.StartScript)"
        }

        if ($server.HealthType -eq "url") {
            $ok = Invoke-UrlHealthCheck `
                -Url $server.HealthTarget `
                -RetryCount ([int]$server.RetryCount) `
                -RetryIntervalSec ([int]$server.RetryIntervalSec)

            if (-not $ok) {
                throw "Health check failed: $($server.VMName) / $($server.HealthTarget)"
            }
        }
        else {
            Write-Log "HealthType $($server.HealthType) is not implemented in this sample."
        }
    }

    Write-Log "===== Priority $priority complete ====="
}

Write-Log "Runbook complete"
