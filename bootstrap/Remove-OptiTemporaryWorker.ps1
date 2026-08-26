[CmdletBinding()]
param(
    [switch]$Automatic,
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [switch]$NoFinalRestart
)

$ErrorActionPreference = 'Stop'
$InstallRoot = 'C:\ProgramData\OptiTemporaryWorker'
$StatePath = Join-Path $InstallRoot 'install-state.json'
$Marker = Join-Path $InstallRoot '.opti-temporary-worker-install'
$SetupTask = 'Opti Temporary Worker Setup'
$RuntimeTask = 'Opti Temporary Worker Runtime'
$CleanupTask = 'Opti Temporary Worker Expiration'

function Write-RemovalLog([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    if (-not $Automatic) { Write-Host $line -ForegroundColor Cyan }
    try {
        $log = Join-Path $InstallRoot 'logs\removal.log'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    } catch { }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'),
                   '-InstanceId', $InstanceId)
    if ($Automatic) { $arguments += '-Automatic' }
    if ($NoFinalRestart) { $arguments += '-NoFinalRestart' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments | Out-Null
    exit 0
}

try {
    $resolvedRoot = [IO.Path]::GetFullPath($InstallRoot)
    if ($resolvedRoot -ne 'C:\ProgramData\OptiTemporaryWorker') {
        throw "Refusing unexpected installation root: $resolvedRoot"
    }
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf) -or
        (Get-Content -LiteralPath $Marker -Raw).Trim() -ne $InstanceId) {
        throw 'The exact Opti temporary-worker installation marker was not found.'
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ([string]$state.format -ne 'opti-temporary-worker-install-v1' -or
        [string]$state.instance_id -ne $InstanceId) {
        throw 'The requested instance does not match the durable installation state.'
    }
    $distro = [string]$state.distro_name
    if ($distro -notmatch '^OptiTemp-[a-f0-9]{12}$') { throw "Unsafe WSL distribution name: $distro" }
    $expectedDistroRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot "instances\$InstanceId\distro"))
    if (-not $expectedDistroRoot.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe WSL distribution storage path: $expectedDistroRoot"
    }
    if (-not $Automatic) {
        $answer = Read-Host "Remove temporary worker $distro and all of its data? Type REMOVE"
        if ($answer -ne 'REMOVE') { Write-Host 'Cancelled.'; exit 0 }
    }

    Write-RemovalLog 'Stopping new assignments and allowing current rollout uploads to finish'
    & wsl.exe -d $distro -u root -- /usr/local/sbin/opti-temporary-worker drain 2>$null
    $drainDeadline = (Get-Date).AddMinutes(3)
    do {
        $active = & wsl.exe -d $distro -u root -- /bin/bash -lc `
            "pgrep -f '[m]ulti_worker.worker_main' >/dev/null && echo active || echo done" 2>$null
        if (([string]$active).Trim() -eq 'done') { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $drainDeadline)

    Write-RemovalLog 'Retiring every CPU slot from the Opti host and logging out of Tailscale'
    Stop-ScheduledTask -TaskName $RuntimeTask -ErrorAction SilentlyContinue
    & wsl.exe -d $distro -u root -- /usr/local/sbin/opti-temporary-worker retire 2>$null
    & wsl.exe -d $distro -u root -- systemctl stop opti-temporary-worker.service 2>$null
    & wsl.exe --terminate $distro 2>$null

    Write-RemovalLog "Unregistering isolated WSL distribution $distro"
    & wsl.exe --unregister $distro
    if ($LASTEXITCODE -ne 0) { throw "Could not unregister $distro (code $LASTEXITCODE)." }
    $remaining = @(& wsl.exe --list --quiet 2>$null | ForEach-Object {
        ([string]$_).Replace(([char]0).ToString(), '').Trim()
    })
    if ($remaining -contains $distro) { throw "$distro is still registered; cleanup stopped safely." }

    $wslConfig = Join-Path ([string]$state.user_profile) '.wslconfig'
    $wslBackup = Join-Path $InstallRoot 'original-wslconfig'
    if ([bool]$state.wslconfig_recorded) {
        if ([bool]$state.wslconfig_existed) {
            if (-not (Test-Path -LiteralPath $wslBackup -PathType Leaf)) {
                throw 'The original .wslconfig backup is missing; cleanup stopped before overwriting user configuration.'
            }
            Copy-Item -LiteralPath $wslBackup -Destination $wslConfig -Force
        } elseif (Test-Path -LiteralPath $wslConfig -PathType Leaf) {
            $currentConfig = Get-Content -LiteralPath $wslConfig -Raw
            if ($currentConfig -notmatch [regex]::Escape("OptiTemporaryWorker instance=$InstanceId")) {
                throw 'The current .wslconfig was changed by someone else; cleanup left it untouched.'
            }
            Remove-Item -LiteralPath $wslConfig -Force
        }
    }
    & wsl.exe --shutdown 2>$null

    if ([bool]$state.wsl_app_installed_by_opti -and -not [bool]$state.wsl_app_preexisting) {
        Write-RemovalLog 'Removing the WSL application package installed by this temporary worker'
        foreach ($package in @(Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' `
                -ErrorAction SilentlyContinue)) {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        }
    }

    $restartNeeded = $false
    if (-not [bool]$state.wsl_feature_preexisting) {
        Write-RemovalLog 'Restoring the Windows Subsystem for Linux feature to its original disabled state'
        Disable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -NoRestart | Out-Null
        $restartNeeded = $true
    }
    if (-not [bool]$state.vmp_feature_preexisting) {
        Write-RemovalLog 'Restoring Virtual Machine Platform to its original disabled state'
        Disable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -NoRestart | Out-Null
        $restartNeeded = $true
    }

    foreach ($task in @($SetupTask, $RuntimeTask, $CleanupTask)) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }

    $downloadedBootstrap = Join-Path ([string]$state.user_profile) `
        'AppData\Local\Temp\Install-OptiTemporaryWorker.ps1'
    $installedBootstrap = Join-Path $InstallRoot 'Install-OptiTemporaryWorker.ps1'
    if ((Test-Path -LiteralPath $downloadedBootstrap -PathType Leaf) -and
        (Test-Path -LiteralPath $installedBootstrap -PathType Leaf) -and
        (Get-FileHash -LiteralPath $downloadedBootstrap -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $installedBootstrap -Algorithm SHA256).Hash) {
        Remove-Item -LiteralPath $downloadedBootstrap -Force -ErrorAction SilentlyContinue
    }

    $cleanupScript = Join-Path $env:TEMP ("remove-opti-temporary-worker-" + [guid]::NewGuid().ToString('N') + '.ps1')
    @"
Start-Sleep -Seconds 3
`$target = 'C:\ProgramData\OptiTemporaryWorker'
`$marker = Join-Path `$target '.opti-temporary-worker-install'
if ([IO.Path]::GetFullPath(`$target) -eq 'C:\ProgramData\OptiTemporaryWorker' -and
    (Test-Path -LiteralPath `$marker -PathType Leaf) -and
    (Get-Content -LiteralPath `$marker -Raw).Trim() -eq '$InstanceId') {
    Remove-Item -LiteralPath `$target -Recurse -Force
}
Remove-Item -LiteralPath `$PSCommandPath -Force
"@ | Set-Content -LiteralPath $cleanupScript -Encoding UTF8
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $cleanupScript + '"')
    ) | Out-Null
    Write-RemovalLog 'Temporary worker removal completed'
    if ($restartNeeded -and -not $NoFinalRestart) {
        Write-RemovalLog 'Windows will restart to finish restoring its original optional-feature state'
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
} catch {
    Write-RemovalLog "REMOVAL FAILED SAFELY: $($_.Exception.Message)"
    if (-not $Automatic) { Write-Error $_ }
    exit 1
}
