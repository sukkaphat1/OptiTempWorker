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
