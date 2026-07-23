$ErrorActionPreference = "Stop"

$AuthKey = $env:TS_AUTHKEY
$NodeHostname = if ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { $env:COMPUTERNAME }
$ExtraArgs = $env:TS_EXTRA_ARGS

if ([string]::IsNullOrWhiteSpace($AuthKey)) {
    throw "TS_AUTHKEY is required."
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run PowerShell as Administrator."
}

function Resolve-TailscaleCli {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

$TailscaleCli = Resolve-TailscaleCli
if (-not $TailscaleCli) {
    Write-Host "Installing Tailscale..." -ForegroundColor Cyan
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        & $winget.Source install --id Tailscale.Tailscale -e --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "winget failed to install Tailscale." }
    }
    else {
        $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" }
            elseif ($env:PROCESSOR_ARCHITECTURE -eq "x86") { "x86" } else { "amd64" }
        $msi = Join-Path $env:TEMP "tailscale-setup.msi"
        Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$architecture.msi" -OutFile $msi -UseBasicParsing
        $process = Start-Process msiexec.exe -ArgumentList @("/i", $msi, "/qn", "/norestart") -Wait -PassThru
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        if ($process.ExitCode -ne 0) { throw "MSI installation failed with exit code $($process.ExitCode)." }
    }
    $TailscaleCli = Resolve-TailscaleCli
    if (-not $TailscaleCli) { throw "tailscale.exe was not found after installation." }
}

$service = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne "Running") {
    Start-Service -Name Tailscale
}

$arguments = @(
    "up",
    "--auth-key=$AuthKey",
    "--hostname=$NodeHostname",
    "--accept-dns=false"
)
if (-not [string]::IsNullOrWhiteSpace($ExtraArgs)) {
    $arguments += $ExtraArgs -split "\s+"
}

& $TailscaleCli @arguments
if ($LASTEXITCODE -ne 0) { throw "tailscale up failed." }
& $TailscaleCli status
& $TailscaleCli netcheck
