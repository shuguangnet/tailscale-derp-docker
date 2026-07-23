$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$files = @(
    (Join-Path $root "install.ps1"),
    (Join-Path $root "manage.ps1"),
    (Join-Path $root "scripts/tailscale-onekey-join-windows.ps1")
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error "$file`: $($_.Message)" }
        exit 1
    }
}

Write-Host "PowerShell syntax tests passed"

$env:TAILSCALE_MANAGER_NO_MENU = "1"
$env:STATE_DIR = Join-Path ([IO.Path]::GetTempPath()) "tailscale-derp-pwsh-test"
. (Join-Path $root "manage.ps1")

Assert-Port "22"
Assert-Platform "windows"
Assert-Platform "alpine"
Assert-Platform "auto"
$target = ConvertFrom-SshTarget "admin@example.com:2222"
if ($target.User -ne "admin" -or $target.Host -ne "example.com" -or $target.Port -ne 2222) {
    throw "ConvertFrom-SshTarget parsed the target incorrectly"
}

$failed = $false
try { Assert-Port "70000" } catch { $failed = $true }
if (-not $failed) { throw "Assert-Port accepted an invalid port" }

$failed = $false
try { Assert-Platform "unknown" } catch { $failed = $true }
if (-not $failed) { throw "Assert-Platform accepted an invalid platform" }

Write-Host "PowerShell function tests passed"
