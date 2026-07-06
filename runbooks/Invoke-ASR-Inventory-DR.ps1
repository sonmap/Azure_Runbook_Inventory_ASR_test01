<#
.SYNOPSIS
  Inventory 기반 ASR DR 후처리 Runbook 예제

.DESCRIPTION
  - ASR Recovery Plan Post Action으로 실행
  - Inventory CSV를 읽어서 Priority 순서대로 처리
  - AP VM 내부 Tomcat 기동 스크립트 실행
  - URL Health Check 수행
  - Application Gateway Backend Pool 업데이트 예시 포함

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

function Invoke-UrlHealthCheck {
    param(
        [string]$Url,
        [int]$RetryCount = 10,
        [int]$RetryIntervalSec = 30
    )

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

function Update-AppGatewayBackendExample {
    param(
        [string]$ResourceGroupName,
        [string]$AppGatewayName,
        [string]$CustomParam
    )

    # CustomParam 예: BACKEND_POOL=dr-ap-pool;BACKEND_IP=10.20.10.10
    $kv = @{}
    $CustomParam -split ';' | ForEach-Object {
        $pair = $_ -split '=', 2
        if ($pair.Count -eq 2) { $kv[$pair[0]] = $pair[1] }
    }

    $backendPoolName = $kv["BACKEND_POOL"]
    $backendIp       = $kv["BACKEND_IP"]

    if (-not $backendPoolName -or -not $backendIp) {
        throw "CustomParam must include BACKEND_POOL and BACKEND_IP"
    }

    Write-Log "Update Application Gateway backend. AGW=$AppGatewayName Pool=$backendPoolName IP=$backendIp"

    $agw = Get-AzApplicationGateway `
        -Name $AppGatewayName `
        -ResourceGroupName $ResourceGroupName

    $pool = Get-AzApplicationGatewayBackendAddressPool `
        -ApplicationGateway $agw `
        -Name $backendPoolName

    Set-AzApplicationGatewayBackendAddressPool `
        -ApplicationGateway $agw `
        -Name $backendPoolName `
        -BackendIPAddresses $backendIp | Out-Null

    Set-AzApplicationGateway -ApplicationGateway $agw | Out-Null

    Write-Log "Application Gateway backend update completed"
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
        elseif ($server.StartMode -eq "custom" -and $server.StartScript -eq "Update-AppGateway-Backend") {
            Update-AppGatewayBackendExample `
                -ResourceGroupName $server.ResourceGroup `
                -AppGatewayName $server.VMName `
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
