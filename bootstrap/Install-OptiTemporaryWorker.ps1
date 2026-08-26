[CmdletBinding()]
param(
    [string]$JoinBundle = '',
    [switch]$Resume,
    [switch]$NoAutomaticRestart,
    [string]$RuntimeAction = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InstallRoot = 'C:\ProgramData\OptiTemporaryWorker'
$StatePath = Join-Path $InstallRoot 'install-state.json'
$ProtectedJoinPath = Join-Path $InstallRoot 'join.protected'
$InstalledBootstrap = Join-Path $InstallRoot 'Install-OptiTemporaryWorker.ps1'
$SetupTask = 'Opti Temporary Worker Setup'
$RuntimeTask = 'Opti Temporary Worker Runtime'
$ScheduleTask = 'Opti Temporary Worker Schedule'
$CleanupTask = 'Opti Temporary Worker Expiration'

function Write-Step([string]$Message) {
    $line = "$(Get-Date -Format o) $Message"
    Write-Host $line -ForegroundColor Cyan
    if (Test-Path -LiteralPath $InstallRoot) {
        $log = Join-Path $InstallRoot 'logs\setup.log'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
        Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-Elevated {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($JoinBundle) { $arguments += @('-JoinBundle', $JoinBundle) }
    if ($Resume) { $arguments += '-Resume' }
    if ($NoAutomaticRestart) { $arguments += '-NoAutomaticRestart' }
    if ($RuntimeAction) { $arguments += @('-RuntimeAction', $RuntimeAction) }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments | Out-Null
}

function ConvertFrom-JoinBundle([string]$EncodedBundle) {
    $encoded = $EncodedBundle.Replace('-', '+').Replace('_', '/')
    while (($encoded.Length % 4) -ne 0) { $encoded += '=' }
    try {
        $bytes = [Convert]::FromBase64String($encoded)
        $bundle = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    } catch {
        throw 'The temporary worker join bundle is invalid.'
    }
    if ([string]$bundle.format -ne 'opti-temporary-wsl-join-v1') { throw 'The join bundle format is not supported.' }
    if ([string]$bundle.github_repository -notmatch '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$') {
        throw 'The join bundle GitHub repository is invalid.'
    }
    if ([string]$bundle.host_url -notmatch '^https?://') { throw 'The join bundle host URL is invalid.' }
    if ([string]$bundle.claim_token -notlike 'owtm_*') { throw 'The temporary machine claim is invalid.' }
    if ([string]$bundle.tailscale_auth_key -notlike 'tskey-*') { throw 'The Tailscale auth key is invalid.' }
    if ([string]$bundle.release_manifest_sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'The pinned release manifest checksum is invalid.'
    }
    return $bundle
}

function Initialize-DataProtection {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        throw 'Windows DPAPI is unavailable in this PowerShell installation.'
    }
}

function Protect-JoinBundle([string]$Value, [string]$Destination) {
    Initialize-DataProtection
    $plain = [Text.Encoding]::UTF8.GetBytes($Value)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $plain, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [IO.File]::WriteAllBytes($Destination, $protected)
}

function Unprotect-JoinBundle([string]$Source) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'The protected join bundle is missing.' }
    Initialize-DataProtection
    $protected = [IO.File]::ReadAllBytes($Source)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [Text.Encoding]::UTF8.GetString($plain)
}

function Set-StateValue($State, [string]$Name, $Value) {
    if ($State.PSObject.Properties.Name -contains $Name) {
        $State.$Name = $Value
    } else {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Save-State($State) {
    $temporary = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
    Set-StateValue $State 'updated_at' ([DateTime]::UtcNow.ToString('o'))
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    # Windows PowerShell 5.1's `-Encoding UTF8` writes a BOM.  Python's strict
    # UTF-8 JSON reader inside the WSL appliance deliberately rejects that
    # prefix, so write the cross-OS handoff as explicit BOM-free UTF-8.
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'Opti temporary worker installation state is missing.' }
    return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}

function Set-PrivateAcl([string]$Path, [string]$UserSid) {
    & icacls.exe $Path /inheritance:r /grant:r "*${UserSid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not secure $Path" }
}

function Register-InteractiveTask([string]$Name, $Action, $Trigger, [string]$UserName) {
    $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
    $parameters = @{
        TaskName = $Name; Action = $Action; Principal = $principal
        Settings = $settings; Force = $true
    }
    if ($null -ne $Trigger) { $parameters.Trigger = $Trigger }
    Register-ScheduledTask @parameters | Out-Null
}

function Register-ResumeTask($State) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $InstalledBootstrap + '" -Resume'
    )
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([string]$State.user_name)
    Register-InteractiveTask -Name $SetupTask -Action $action -Trigger $trigger -UserName ([string]$State.user_name)
}

function Resolve-ScheduleTimeZone([string]$Value) {
    $aliases = @{
        'America/Chicago' = 'Central Standard Time'
        'America/New_York' = 'Eastern Standard Time'
        'America/Denver' = 'Mountain Standard Time'
        'America/Los_Angeles' = 'Pacific Standard Time'
        'America/Anchorage' = 'Alaskan Standard Time'
        'Pacific/Honolulu' = 'Hawaiian Standard Time'
        'Etc/UTC' = 'UTC'
    }
    $candidate = $Value.Trim()
    if ($aliases.ContainsKey($candidate)) { $candidate = $aliases[$candidate] }
    try { [void][TimeZoneInfo]::FindSystemTimeZoneById($candidate) }
    catch { throw "Windows does not recognize schedule time zone '$Value'." }
    return $candidate
}

function Test-ScheduleWindow($State) {
    if (-not [bool]$State.schedule_enabled) { return $true }
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById([string]$State.schedule_timezone)
    $local = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $zone)
    $startParts = ([string]$State.schedule_start).Split(':')
    $stopParts = ([string]$State.schedule_stop).Split(':')
    $minute = $local.Hour * 60 + $local.Minute
    $start = [int]$startParts[0] * 60 + [int]$startParts[1]
    $stop = [int]$stopParts[0] * 60 + [int]$stopParts[1]
    if ($start -lt $stop) { return $minute -ge $start -and $minute -lt $stop }
    return $minute -ge $start -or $minute -lt $stop
}

function Start-WorkerRuntime($State) {
    $distro = [string]$State.distro_name
    if ((Get-Distros) -notcontains $distro) { return }
    & wsl.exe -d $distro -u root -- /usr/local/sbin/opti-temporary-worker resume 2>$null
    $task = Get-ScheduledTask -TaskName $RuntimeTask -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne 'Running') { Start-ScheduledTask -TaskName $RuntimeTask }
}

function Stop-WorkerRuntime($State) {
    $distro = [string]$State.distro_name
    $runtime = Get-ScheduledTask -TaskName $RuntimeTask -ErrorAction SilentlyContinue
    if ((-not $runtime -or $runtime.State -ne 'Running') -and
        (Get-RunningDistros) -notcontains $distro) { return }
    Stop-ScheduledTask -TaskName $RuntimeTask -ErrorAction SilentlyContinue
    if ((Get-Distros) -notcontains $distro) { return }
    & wsl.exe -d $distro -u root -- /usr/local/sbin/opti-temporary-worker drain 2>$null
    $deadline = (Get-Date).AddMinutes(3)
    do {
        $active = & wsl.exe -d $distro -u root -- /bin/bash -lc `
            "pgrep -f '[m]ulti_worker.worker_main' >/dev/null && echo active || echo done" 2>$null
        if (([string]$active).Trim() -eq 'done') { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    & wsl.exe -d $distro -u root -- systemctl stop opti-temporary-worker.service 2>$null
    & wsl.exe --terminate $distro 2>$null
}

function Invoke-ScheduleReconcile($State) {
    $expires = [string]$State.expires_at
    if ($expires -and [DateTimeOffset]::Parse($expires) -le [DateTimeOffset]::UtcNow) {
        $cleanup = Get-ScheduledTask -TaskName $CleanupTask -ErrorAction SilentlyContinue
        if ($cleanup -and $cleanup.State -ne 'Running') { Start-ScheduledTask -TaskName $CleanupTask }
        return $false
    }
    if (Test-ScheduleWindow $State) { Start-WorkerRuntime $State }
    else { Stop-WorkerRuntime $State }
    return $true
}

function Hold-SystemAwake([bool]$Enabled) {
    if (-not $Enabled) { return }
    if (-not ('OptiTemporaryWorker.Power' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace OptiTemporaryWorker {
  public static class Power {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
  }
}
'@
    }
    [void][OptiTemporaryWorker.Power]::SetThreadExecutionState([uint32]2147483649)
}

function Release-SystemAwake {
    if ('OptiTemporaryWorker.Power' -as [type]) {
        [void][OptiTemporaryWorker.Power]::SetThreadExecutionState([uint32]2147483648)
    }
}

function Get-Distros {
    $lines = @(& wsl.exe --list --quiet 2>$null)
    return @($lines | ForEach-Object {
        ([string]$_).Replace(([char]0).ToString(), '').Trim()
    } | Where-Object { $_ })
}

function Get-RunningDistros {
    $lines = @(& wsl.exe --list --running --quiet 2>$null)
    return @($lines | ForEach-Object {
        ([string]$_).Replace(([char]0).ToString(), '').Trim()
    } | Where-Object { $_ })
}

function Download-Verified([string]$Url, [string]$Destination, [string]$ExpectedSha256) {
    if ($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SHA-256 for $Url" }
    $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).download"
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $temporary
            $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "SHA-256 failed for $Url" }
            Move-Item -LiteralPath $temporary -Destination $Destination -Force
            return
        } catch {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            if ($attempt -eq 4) { throw }
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Enable-WslFeatures {
    $changed = $false
    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
        if ($feature.State -ne 'Enabled') {
            Write-Step "Enabling Windows feature $featureName"
            Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart | Out-Null
            $changed = $true
        }
    }
    return $changed
}

function Configure-MaximumWslResources($State) {
    $computer = Get-CimInstance Win32_ComputerSystem
    $totalMb = [Math]::Floor([double]$computer.TotalPhysicalMemory / 1MB)
    $logical = [Math]::Max(1, [Environment]::ProcessorCount)
    if ($totalMb -lt 4096) { throw 'Opti temporary workers require at least 4 GB of physical RAM.' }
    # WSL receives every logical processor. Its memory ceiling is all physical
    # RAM except the smallest reserve Windows needs to keep networking,
    # Task Scheduler, and the final uninstaller alive.
    $windowsReserveMb = [Math]::Max(2048, [Math]::Ceiling($totalMb * 0.08))
    $workerMb = [Math]::Max(2048, $totalMb - $windowsReserveMb)
    $swapMb = [Math]::Min(8192, [Math]::Max(2048, [Math]::Floor($totalMb / 4)))
    $wslConfig = Join-Path ([string]$State.user_profile) '.wslconfig'
    $backup = Join-Path $InstallRoot 'original-wslconfig'
    if (-not [bool]$State.wslconfig_recorded) {
        if (Test-Path -LiteralPath $wslConfig -PathType Leaf) {
            Copy-Item -LiteralPath $wslConfig -Destination $backup -Force
            $State.wslconfig_existed = $true
        } else {
            $State.wslconfig_existed = $false
        }
        $State.wslconfig_recorded = $true; Save-State $State
    }
    @"
# OptiTemporaryWorker instance=$($State.instance_id)
[wsl2]
memory=${workerMb}MB
processors=$logical
swap=${swapMb}MB
localhostForwarding=true
"@ | Set-Content -LiteralPath $wslConfig -Encoding ASCII
    & wsl.exe --shutdown 2>$null
    Write-Step "WSL configured for all $logical logical CPUs and $workerMb MB maximum worker RAM"
}

function Convert-ToWslProgramDataPath([string]$WindowsPath) {
    $resolved = [IO.Path]::GetFullPath($WindowsPath)
    if (-not $resolved.StartsWith('C:\ProgramData\OptiTemporaryWorker\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe WSL handoff path: $resolved"
    }
    return '/mnt/c/' + $resolved.Substring(3).Replace('\', '/')
}

function Register-RuntimeAndCleanup($State, $ExpiresAt) {
    $windowStyle = if ([bool]$State.run_in_background) { 'Hidden' } else { 'Normal' }
    $runtimeAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -WindowStyle ' + $windowStyle + ' -ExecutionPolicy Bypass -File "' +
        $InstalledBootstrap + '" -RuntimeAction run'
    )
    $runtimeTrigger = if ([bool]$State.schedule_enabled) {
        $null
    } else {
        New-ScheduledTaskTrigger -AtLogOn -User ([string]$State.user_name)
    }
    Register-InteractiveTask -Name $RuntimeTask -Action $runtimeAction -Trigger $runtimeTrigger `
        -UserName ([string]$State.user_name)

    if ([bool]$State.schedule_enabled) {
        $scheduleAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
            '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
            $InstalledBootstrap + '" -RuntimeAction monitor'
        )
        $scheduleTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([string]$State.user_name)
        Register-InteractiveTask -Name $ScheduleTask -Action $scheduleAction -Trigger $scheduleTrigger `
            -UserName ([string]$State.user_name)
    } else {
        Unregister-ScheduledTask -TaskName $ScheduleTask -Confirm:$false -ErrorAction SilentlyContinue
    }

    if ($null -ne $ExpiresAt) {
        $uninstaller = Join-Path $InstallRoot 'Remove-OptiTemporaryWorker.ps1'
        $cleanupAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
            '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $uninstaller +
            '" -Automatic -InstanceId "' + [string]$State.instance_id + '"'
        )
        $at = $ExpiresAt.LocalDateTime
        if ($at -lt (Get-Date).AddMinutes(1)) { $at = (Get-Date).AddMinutes(1) }
        $cleanupTrigger = New-ScheduledTaskTrigger -Once -At $at
        Register-InteractiveTask -Name $CleanupTask -Action $cleanupAction -Trigger $cleanupTrigger `
            -UserName ([string]$State.user_name)
    } else {
        Unregister-ScheduledTask -TaskName $CleanupTask -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Administrator)) {
    Start-Elevated
    exit 0
}

if ($RuntimeAction) {
    if ($RuntimeAction -notin @('run', 'start', 'stop', 'reconcile', 'monitor')) {
        throw "Unknown Opti runtime action: $RuntimeAction"
    }
    $runtimeState = Read-State
    switch ($RuntimeAction) {
        'run' {
            $runtimeLog = Join-Path $InstallRoot 'logs\runtime.log'
            Hold-SystemAwake ([bool]$runtimeState.prevent_sleep)
            try {
                & wsl.exe -d ([string]$runtimeState.distro_name) -u root -- `
                    /usr/local/sbin/opti-wsl-keepalive *>> $runtimeLog
                exit $LASTEXITCODE
            } finally {
                Release-SystemAwake
            }
        }
        'start' { Start-WorkerRuntime $runtimeState; exit 0 }
        'stop' { Stop-WorkerRuntime $runtimeState; exit 0 }
        'reconcile' { [void](Invoke-ScheduleReconcile $runtimeState); exit 0 }
        'monitor' {
            while (Test-Path -LiteralPath $StatePath -PathType Leaf) {
                $runtimeState = Read-State
                if (-not (Invoke-ScheduleReconcile $runtimeState)) { break }
                Start-Sleep -Seconds 30
            }
            exit 0
        }
    }
}

try {
    if (-not $Resume) {
        if (-not $JoinBundle) { throw 'A host-issued -JoinBundle is required.' }
        $join = ConvertFrom-JoinBundle $JoinBundle
        New-Item -ItemType Directory -Force -Path $InstallRoot, (Join-Path $InstallRoot 'logs'), `
            (Join-Path $InstallRoot 'instances'), (Join-Path $InstallRoot 'downloads') | Out-Null
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        Set-PrivateAcl -Path $InstallRoot -UserSid $identity.User.Value
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledBootstrap -Force
        Protect-JoinBundle -Value $JoinBundle -Destination $ProtectedJoinPath
        $instanceId = [guid]::NewGuid().ToString('N')
        $wslFeatureBefore = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux'
        $vmpFeatureBefore = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
        $wslAppBefore = @(Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' `
            -ErrorAction SilentlyContinue)
        $runInBackground = if ($null -eq $join.runtime -or $null -eq $join.runtime.background) {
            $true
        } else { [bool]$join.runtime.background }
        $preventSleep = if ($null -eq $join.runtime -or $null -eq $join.runtime.prevent_sleep) {
            $true
        } else { [bool]$join.runtime.prevent_sleep }
        $scheduleEnabled = $null -ne $join.schedule -and [bool]$join.schedule.enabled
        $scheduleTimezone = if ($null -ne $join.schedule -and [string]$join.schedule.time_zone) {
            Resolve-ScheduleTimeZone ([string]$join.schedule.time_zone)
        } else { Resolve-ScheduleTimeZone 'Central Standard Time' }
        $scheduleStart = if ($null -ne $join.schedule -and [string]$join.schedule.start_time) {
            [string]$join.schedule.start_time
        } else { '19:00' }
        $scheduleStop = if ($null -ne $join.schedule -and [string]$join.schedule.stop_time) {
            [string]$join.schedule.stop_time
        } else { '07:00' }
        if ($scheduleStart -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' -or
            $scheduleStop -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$' -or
            ($scheduleEnabled -and $scheduleStart -eq $scheduleStop)) {
            throw 'The daily WSL schedule is invalid.'
        }
        $state = [pscustomobject]@{
            format = 'opti-temporary-worker-install-v1'
            phase = 'created'
            instance_id = $instanceId
            distro_name = "OptiTemp-$($instanceId.Substring(0,12))"
            user_name = $identity.Name
            user_sid = $identity.User.Value
            user_profile = $env:USERPROFILE
            repository = [string]$join.github_repository
            wsl_feature_preexisting = ($wslFeatureBefore.State -eq 'Enabled')
            vmp_feature_preexisting = ($vmpFeatureBefore.State -eq 'Enabled')
            wsl_app_preexisting = ($wslAppBefore.Count -gt 0)
            wsl_app_installed_by_opti = $false
            wslconfig_recorded = $false
            wslconfig_existed = $false
            machine_id = ''
            machine_name = ''
            slot_count = 0
            expires_at = ''
            run_in_background = $runInBackground
            prevent_sleep = $preventSleep
            schedule_enabled = $scheduleEnabled
            schedule_timezone = $scheduleTimezone
            schedule_start = $scheduleStart
            schedule_stop = $scheduleStop
            created_at = [DateTime]::UtcNow.ToString('o')
            updated_at = [DateTime]::UtcNow.ToString('o')
        }
        Save-State $state
        Set-Content -LiteralPath (Join-Path $InstallRoot '.opti-temporary-worker-install') `
            -Value $instanceId -Encoding ASCII
        Register-ResumeTask $state
    } else {
        $state = Read-State
        $JoinBundle = Unprotect-JoinBundle $ProtectedJoinPath
        $join = ConvertFrom-JoinBundle $JoinBundle
    }

    # State files from an interrupted older bootstrap remain resumable. Add
    # every newer field explicitly instead of assigning a missing PSCustomObject
    # property, which caused the previous machine_id setup failure.
    $stateDefaults = @{
        machine_id = ''; machine_name = ''; slot_count = 0; expires_at = ''
        run_in_background = $true; prevent_sleep = $true; schedule_enabled = $false
        schedule_timezone = 'Central Standard Time'; schedule_start = '19:00'; schedule_stop = '07:00'
    }
    foreach ($name in $stateDefaults.Keys) {
        if ($state.PSObject.Properties.Name -notcontains $name) {
            Set-StateValue $state $name $stateDefaults[$name]
        }
    }
    Set-StateValue $state 'schedule_timezone' (Resolve-ScheduleTimeZone ([string]$state.schedule_timezone))
    Save-State $state

    Write-Step "Continuing Opti temporary worker setup at phase $($state.phase)"
    $featuresChanged = Enable-WslFeatures
    if ($featuresChanged) {
        $state.phase = 'awaiting-reboot'; Save-State $state
        Write-Step 'WSL features are enabled. Windows will restart now and setup will resume after login.'
        if ($NoAutomaticRestart) {
            Write-Step 'Automatic restart was suppressed for validation.'
            exit 3010
        }
        Restart-Computer -Force
        exit 0
    }

    $state.phase = 'updating-wsl'; Save-State $state
    Write-Step 'Updating the WSL runtime'
    & wsl.exe --update --web-download
    if ($LASTEXITCODE -ne 0) {
        Write-Step 'The direct WSL download was unavailable; retrying through the standard Windows source'
        & wsl.exe --update
    }
    if ($LASTEXITCODE -ne 0) { throw "wsl --update failed with code $LASTEXITCODE" }
    $wslAppAfter = @(Get-AppxPackage -AllUsers -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' `
        -ErrorAction SilentlyContinue)
    $state.wsl_app_installed_by_opti = (-not [bool]$state.wsl_app_preexisting -and $wslAppAfter.Count -gt 0)
    Save-State $state
    & wsl.exe --set-default-version 2
    if ($LASTEXITCODE -ne 0) { throw "WSL 2 could not be selected (code $LASTEXITCODE). Check firmware virtualization." }
    Configure-MaximumWslResources $state

    $state.phase = 'downloading'; Save-State $state
    $releaseBase = "https://github.com/$($state.repository)/releases/latest/download"
    $manifestPath = Join-Path $InstallRoot 'downloads\release-manifest.json'
    Download-Verified -Url "$releaseBase/release-manifest.json" -Destination $manifestPath `
        -ExpectedSha256 ([string]$join.release_manifest_sha256)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.format -ne 'opti-temporary-worker-release-v1') { throw 'Release manifest format is invalid.' }
    $rootfsName = [string]$manifest.assets.rootfs.name
    $rootfsHash = [string]$manifest.assets.rootfs.sha256
    $removeName = [string]$manifest.assets.uninstaller.name
    $removeHash = [string]$manifest.assets.uninstaller.sha256
    if ($rootfsName -ne 'opti-temporary-worker-rootfs.tar.gz' -or $removeName -ne 'Remove-OptiTemporaryWorker.ps1') {
        throw 'Release manifest contains unexpected asset names.'
    }
    $rootfs = Join-Path $InstallRoot "downloads\$rootfsName"
    Download-Verified -Url "$releaseBase/$rootfsName" -Destination $rootfs -ExpectedSha256 $rootfsHash
    Download-Verified -Url "$releaseBase/$removeName" -Destination (Join-Path $InstallRoot $removeName) `
        -ExpectedSha256 $removeHash

    $state.phase = 'importing'; Save-State $state
    $instanceRoot = Join-Path $InstallRoot "instances\$($state.instance_id)"
    $distroRoot = Join-Path $instanceRoot 'distro'
    New-Item -ItemType Directory -Force -Path $instanceRoot | Out-Null
    if ((Get-Distros) -notcontains [string]$state.distro_name) {
        Write-Step "Importing isolated WSL distribution $($state.distro_name)"
        New-Item -ItemType Directory -Force -Path $distroRoot | Out-Null
        & wsl.exe --import ([string]$state.distro_name) $distroRoot $rootfs --version 2
        if ($LASTEXITCODE -ne 0) { throw "WSL distribution import failed with code $LASTEXITCODE" }
    }

    $state.phase = 'provisioning'; Save-State $state
    $leasePath = Join-Path $instanceRoot 'lease.json'
    $expiredPath = Join-Path $instanceRoot 'expired.ready'
    $join | Add-Member -NotePropertyName windows_lease_path -NotePropertyValue (Convert-ToWslProgramDataPath $leasePath) -Force
    $join | Add-Member -NotePropertyName windows_expired_path -NotePropertyValue (Convert-ToWslProgramDataPath $expiredPath) -Force
    $plainJoin = Join-Path $instanceRoot 'join.json'
    Write-Utf8NoBom -Path $plainJoin -Value ($join | ConvertTo-Json -Depth 8 -Compress)
    Set-PrivateAcl -Path $instanceRoot -UserSid ([string]$state.user_sid)
    $wslJoin = Convert-ToWslProgramDataPath $plainJoin
    & wsl.exe -d ([string]$state.distro_name) -u root -- /bin/bash -lc `
        "install -d -m 0700 /etc/opti-temporary-worker && install -m 0600 '$wslJoin' /etc/opti-temporary-worker/join.json"
    if ($LASTEXITCODE -ne 0) { throw 'Could not copy the protected enrollment into WSL.' }
    Remove-Item -LiteralPath $plainJoin -Force

    Write-Step 'Connecting Tailscale inside WSL and downloading the exact host worker build'
    & wsl.exe -d ([string]$state.distro_name) -u root -- /usr/local/sbin/opti-temporary-worker provision
    if ($LASTEXITCODE -ne 0) { throw "WSL worker provisioning failed with code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { throw 'The host-issued worker lease handoff is missing.' }
    $lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
    if ([string]$lease.format -ne 'opti-temporary-worker-lease-v1') { throw 'The worker lease handoff is invalid.' }
    $expiresAt = $null
    if ([string]$lease.expires_at) { $expiresAt = [DateTimeOffset]::Parse([string]$lease.expires_at) }
    Set-StateValue $state 'phase' 'registering-runtime'
    Set-StateValue $state 'machine_id' ([string]$lease.machine_id)
    Set-StateValue $state 'machine_name' ([string]$lease.machine_name)
    Set-StateValue $state 'slot_count' ([int]$lease.slot_count)
    Set-StateValue $state 'expires_at' $(if ($null -ne $expiresAt) { $expiresAt.ToString('o') } else { '' })
    Save-State $state
    & wsl.exe -d ([string]$state.distro_name) -u root -- systemctl enable opti-temporary-worker.service
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable the WSL worker service.' }
    Register-RuntimeAndCleanup -State $state -ExpiresAt $expiresAt
    Set-StateValue $state 'phase' 'complete'
    Save-State $state
    if ([bool]$state.schedule_enabled) { Start-ScheduledTask -TaskName $ScheduleTask }
    else { Start-WorkerRuntime $state }
    Remove-Item -LiteralPath $ProtectedJoinPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $rootfs -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $SetupTask -Confirm:$false -ErrorAction SilentlyContinue
    $downloadedBootstrap = [IO.Path]::GetFullPath($PSCommandPath)
    $expectedDownload = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'Install-OptiTemporaryWorker.ps1'))
    if ($downloadedBootstrap -eq $expectedDownload -and $downloadedBootstrap -ne $InstalledBootstrap) {
        Remove-Item -LiteralPath $downloadedBootstrap -Force -ErrorAction SilentlyContinue
    }
    $lifetime = if ([string]$state.expires_at) { "until $($state.expires_at)" } else { 'with no automatic expiration' }
    Write-Step "Opti temporary WSL worker is ready with $($state.slot_count) CPU slots $lifetime."
} catch {
    Write-Step "SETUP FAILED: $($_.Exception.Message)"
    Write-Error $_
    exit 1
}
