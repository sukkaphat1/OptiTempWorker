$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$Failed = $false

foreach ($relative in @(
    'bootstrap\Install-OptiTemporaryWorker.ps1',
    'bootstrap\Remove-OptiTemporaryWorker.ps1',
    'tools\Validate-Project.ps1'
)) {
    $path = Join-Path $Root $relative
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        $Failed = $true
        foreach ($error in $errors) { Write-Error "$relative`: $($error.Message)" -ErrorAction Continue }
    }
}

# Execute the join-bundle parser in isolation. This catches PowerShell's
# case-insensitive typed-variable coercion, which syntax parsing alone cannot
# detect.
$bootstrapPath = Join-Path $Root 'bootstrap\Install-OptiTemporaryWorker.ps1'
$tokens = $null; $errors = $null
$bootstrapAst = [Management.Automation.Language.Parser]::ParseFile(
    $bootstrapPath, [ref]$tokens, [ref]$errors
)
$stateSetter = $bootstrapAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Set-StateValue'
}, $true)
if (-not $stateSetter) {
    Write-Error 'Upgrade-safe state setter is missing.' -ErrorAction Continue
    $Failed = $true
} else {
    . ([scriptblock]::Create($stateSetter.Extent.Text))
    try {
        $sampleState = [pscustomobject]@{ phase = 'created' }
        Set-StateValue $sampleState 'machine_id' 'tm_validation'
        Set-StateValue $sampleState 'phase' 'complete'
        if ([string]$sampleState.machine_id -ne 'tm_validation' -or [string]$sampleState.phase -ne 'complete') {
            throw 'State fields were not added and updated correctly.'
        }
    } catch {
        Write-Error "Installer state regression: $($_.Exception.Message)" -ErrorAction Continue
        $Failed = $true
    } finally {
        Remove-Item Function:\Set-StateValue -ErrorAction SilentlyContinue
    }
}

$bootstrapText = Get-Content -LiteralPath $bootstrapPath -Raw
foreach ($requiredText in @('-RuntimeAction run', '-RuntimeAction monitor', 'schedule_timezone',
                             'prevent_sleep', 'SetThreadExecutionState')) {
    if ($bootstrapText -notmatch [regex]::Escape($requiredText)) {
        Write-Error "Installer runtime feature is missing: $requiredText" -ErrorAction Continue
        $Failed = $true
    }
}
$bundleFunction = $bootstrapAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'ConvertFrom-JoinBundle'
}, $true)
if (-not $bundleFunction) {
    Write-Error 'Join-bundle parser function is missing.' -ErrorAction Continue
    $Failed = $true
} else {
    . ([scriptblock]::Create($bundleFunction.Extent.Text))
    $samplePayload = [ordered]@{
        format = 'opti-temporary-wsl-join-v1'
        created_at = [DateTimeOffset]::UtcNow.ToString('o')
        host_url = 'http://100.64.0.1:7443'
        claim_token = 'owtm_validation'
        tailscale_auth_key = 'tskey-auth-validation'
        github_repository = 'owner/OptiTempWorker'
        release_manifest_sha256 = ('a' * 64)
    }
    $sampleJson = $samplePayload | ConvertTo-Json -Compress
    $sampleBundle = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sampleJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    try {
        $decodedBundle = ConvertFrom-JoinBundle $sampleBundle
        if ([string]$decodedBundle.format -ne 'opti-temporary-wsl-join-v1' -or
                [string]$decodedBundle.claim_token -ne 'owtm_validation') {
            throw 'Decoded join bundle did not preserve its fields.'
        }
    } catch {
        Write-Error "Join-bundle parser regression: $($_.Exception.Message)" -ErrorAction Continue
        $Failed = $true
    } finally {
        Remove-Item Function:\ConvertFrom-JoinBundle -ErrorAction SilentlyContinue
    }
}

if ($env:OS -eq 'Windows_NT') {
    $dataProtectionFunctions = @('Initialize-DataProtection', 'Protect-JoinBundle', 'Unprotect-JoinBundle')
    foreach ($functionName in $dataProtectionFunctions) {
        $functionAst = $bootstrapAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)
        if (-not $functionAst) {
            Write-Error "Installer function is missing: $functionName" -ErrorAction Continue
            $Failed = $true
        } else {
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
    }
    $dpapiTestPath = Join-Path ([IO.Path]::GetTempPath()) ("opti-dpapi-validation-$([guid]::NewGuid().ToString('N')).bin")
    try {
        $dpapiSample = 'Opti DPAPI validation payload'
        Protect-JoinBundle -Value $dpapiSample -Destination $dpapiTestPath
        if ((Unprotect-JoinBundle -Source $dpapiTestPath) -ne $dpapiSample) {
            throw 'DPAPI round trip did not preserve the join bundle.'
        }
    } catch {
        Write-Error "Windows DPAPI regression: $($_.Exception.Message)" -ErrorAction Continue
        $Failed = $true
    } finally {
        Remove-Item -LiteralPath $dpapiTestPath -Force -ErrorAction SilentlyContinue
        foreach ($functionName in $dataProtectionFunctions) {
            Remove-Item "Function:\$functionName" -ErrorAction SilentlyContinue
        }
    }
    $powerFunctions = @('Hold-SystemAwake', 'Release-SystemAwake')
    foreach ($functionName in $powerFunctions) {
        $functionAst = $bootstrapAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)
        if (-not $functionAst) { throw "Installer function is missing: $functionName" }
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    try {
        Hold-SystemAwake $true
        Release-SystemAwake
    } catch {
        Write-Error "Windows sleep-hold regression: $($_.Exception.Message)" -ErrorAction Continue
        $Failed = $true
    } finally {
        foreach ($functionName in $powerFunctions) {
            Remove-Item "Function:\$functionName" -ErrorAction SilentlyContinue
        }
    }
}

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) { throw 'Python is required for validation.' }
& $python.Source -m py_compile `
    (Join-Path $Root 'linux\overlay\usr\local\lib\opti-temporary-worker\control.py') `
    (Join-Path $Root 'tools\build_release_manifest.py')
if ($LASTEXITCODE -ne 0) { $Failed = $true }

& $python.Source -m unittest discover -s (Join-Path $Root 'tests') -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { $Failed = $true }

foreach ($required in @(
    'linux\build-rootfs.sh',
    'linux\overlay\etc\wsl.conf',
    'linux\overlay\usr\local\sbin\opti-temporary-worker',
    'linux\overlay\usr\local\sbin\opti-wsl-keepalive',
    'linux\overlay\usr\local\lib\opti-temporary-worker\control.py',
    'bootstrap\Install-OptiTemporaryWorker.ps1',
    'bootstrap\Remove-OptiTemporaryWorker.ps1',
    'tests\test_control.py',
    '.github\workflows\release.yml'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $required) -PathType Leaf)) {
        Write-Error "Missing required file: $required" -ErrorAction Continue
        $Failed = $true
    }
}

if ($Failed) { throw 'Opti temporary worker validation failed.' }
Write-Host 'Opti temporary worker source validation passed.' -ForegroundColor Green
