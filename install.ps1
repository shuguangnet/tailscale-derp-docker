$ErrorActionPreference = "Stop"

$RepoSlug = if ($env:REPO_SLUG) { $env:REPO_SLUG } else { "shuguangnet/tailscale-derp-docker" }
$InstallDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:ProgramData "TailscaleDERP\app" }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run PowerShell as Administrator."
}

$tempDir = Join-Path $env:TEMP ("tailscale-derp-" + [Guid]::NewGuid().ToString("N"))
$archive = Join-Path $tempDir "source.zip"
$extractDir = Join-Path $tempDir "extract"

try {
    New-Item -ItemType Directory -Path $tempDir, $extractDir -Force | Out-Null
    Invoke-WebRequest -Uri "https://github.com/$RepoSlug/archive/refs/heads/main.zip" -OutFile $archive -UseBasicParsing
    Expand-Archive -Path $archive -DestinationPath $extractDir -Force
    $sourceDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $sourceDir) { throw "Downloaded archive did not contain the repository." }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDir.FullName "*") -Destination $InstallDir -Recurse -Force
}
finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

& (Join-Path $InstallDir "manage.ps1")
