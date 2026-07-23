$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$StateDir = if ($env:STATE_DIR) { $env:STATE_DIR } else { Join-Path $env:ProgramData "TailscaleDERP" }
$NodesFile = Join-Path $StateDir "nodes.json"
$JoinWindowsScript = Join-Path $ProjectDir "scripts\tailscale-onekey-join-windows.ps1"
$JoinUnixScript = Join-Path $ProjectDir "scripts\tailscale-onekey-join-linux.sh"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "请以管理员身份运行 PowerShell。"
    }
}

function Initialize-State {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    if (-not (Test-Path $NodesFile)) { "[]" | Set-Content -Path $NodesFile -Encoding UTF8 }
    & icacls.exe $StateDir /inheritance:r /grant:r "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
}

function Get-Nodes {
    Initialize-State
    $content = Get-Content -Path $NodesFile -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }
    return @($content | ConvertFrom-Json)
}

function Save-Nodes([array]$Nodes) {
    Initialize-State
    @($Nodes) | ConvertTo-Json -Depth 5 | Set-Content -Path $NodesFile -Encoding UTF8
}

function Read-Default([string]$Label, [string]$Default = "") {
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $value = Read-Host "$Label$suffix"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Read-Secret([string]$Label) {
    $secure = Read-Host $Label -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Assert-Port([string]$Value) {
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
        throw "端口必须是 1 到 65535 之间的整数。"
    }
}

function Assert-Platform([string]$Platform) {
    if ($Platform -notin @("windows", "linux", "debian", "ubuntu", "alpine", "macos")) {
        throw "平台必须是 windows、linux、debian、ubuntu、alpine 或 macos。"
    }
}

function Assert-SshTarget([string]$HostName, [string]$UserName) {
    if ($HostName -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') { throw "SSH 地址格式无效。" }
    if ($UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "SSH 用户名格式无效。" }
}

function Get-Node([string]$Id) {
    $node = Get-Nodes | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $node) { throw "找不到子节点: $Id" }
    return $node
}

function Add-Node {
    $id = Read-Default "节点 ID"
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "节点 ID 格式无效。" }
    if (Get-Nodes | Where-Object { $_.Id -eq $id }) { throw "节点已存在: $id" }
    $platform = Read-Default "平台 (windows/linux/debian/ubuntu/alpine/macos)" "windows"
    Assert-Platform $platform
    $sshHost = Read-Default "SSH 地址或 IP"
    $sshUser = Read-Default "SSH 用户" $(if ($platform -eq "windows") { $env:USERNAME } else { "root" })
    Assert-SshTarget $sshHost $sshUser
    $sshPort = Read-Default "SSH 端口" "22"
    Assert-Port $sshPort
    $hostname = Read-Default "Tailscale hostname" $id
    $authKey = Read-Secret "Tailscale auth key"
    if ([string]::IsNullOrWhiteSpace($authKey)) { throw "auth key 不能为空。" }
    $extraArgs = Read-Default "额外 tailscale up 参数"
    $useSudo = if ($platform -eq "windows" -or $sshUser -eq "root") { $false } else { (Read-Default "使用免密码 sudo (yes/no)" "yes") -eq "yes" }

    $nodes = @(Get-Nodes)
    $nodes += [pscustomobject]@{
        Id = $id; Platform = $platform; SshHost = $sshHost; SshUser = $sshUser
        SshPort = [int]$sshPort; Hostname = $hostname; AuthKey = $authKey
        ExtraArgs = $extraArgs; UseSudo = $useSudo
    }
    Save-Nodes $nodes
    Write-Host "子节点 $id 已保存。" -ForegroundColor Green
    if ((Read-Default "立即部署 (yes/no)" "yes") -eq "yes") { Deploy-Node $id }
}

function List-Nodes {
    $nodes = @(Get-Nodes)
    if ($nodes.Count -eq 0) { Write-Host "尚未配置子节点。" -ForegroundColor Yellow; return }
    $nodes | Select-Object Id, Platform, @{N="SSH";E={"$($_.SshUser)@$($_.SshHost):$($_.SshPort)"}}, Hostname, UseSudo | Format-Table -AutoSize
}

function Show-Node([string]$Id) {
    $node = Get-Node $Id
    $masked = if ($node.AuthKey.Length -gt 8) { $node.AuthKey.Substring(0, 8) + "..." } else { "***" }
    [pscustomobject]@{
        Id = $node.Id; Platform = $node.Platform; SSH = "$($node.SshUser)@$($node.SshHost):$($node.SshPort)"
        Hostname = $node.Hostname; AuthKey = $masked; ExtraArgs = $node.ExtraArgs; UseSudo = $node.UseSudo
    } | Format-List
}

function Edit-Node([string]$Id) {
    $nodes = @(Get-Nodes)
    $node = $nodes | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $node) { throw "找不到子节点: $Id" }
    $node.Platform = Read-Default "平台" $node.Platform
    Assert-Platform $node.Platform
    $node.SshHost = Read-Default "SSH 地址或 IP" $node.SshHost
    $node.SshUser = Read-Default "SSH 用户" $node.SshUser
    Assert-SshTarget $node.SshHost $node.SshUser
    $node.SshPort = [int](Read-Default "SSH 端口" ([string]$node.SshPort))
    Assert-Port ([string]$node.SshPort)
    $node.Hostname = Read-Default "Tailscale hostname" $node.Hostname
    $extra = Read-Default "额外参数，输入 - 清空" $node.ExtraArgs
    $node.ExtraArgs = if ($extra -eq "-") { "" } else { $extra }
    $node.UseSudo = (Read-Default "使用免密码 sudo (yes/no)" $(if ($node.UseSudo) { "yes" } else { "no" })) -eq "yes"
    if ((Read-Default "替换 auth key (yes/no)" "no") -eq "yes") { $node.AuthKey = Read-Secret "新 auth key" }
    Save-Nodes $nodes
    Write-Host "子节点 $Id 已更新。" -ForegroundColor Green
    if ((Read-Default "立即重新部署 (yes/no)" "no") -eq "yes") { Deploy-Node $Id }
}

function Remove-Node([string]$Id) {
    Get-Node $Id | Out-Null
    if ((Read-Default "删除 $Id 的本地配置 (yes/no)" "no") -ne "yes") { return }
    $nodes = @(Get-Nodes | Where-Object { $_.Id -ne $Id })
    Save-Nodes $nodes
    Write-Host "配置已删除；Tailscale 管理后台中的设备未删除。" -ForegroundColor Yellow
}

function Invoke-SshPayload($Node, [string]$RemoteCommand, [string[]]$Lines) {
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { throw "未找到 OpenSSH Client，请在 Windows 可选功能中安装。" }
    Assert-SshTarget $Node.SshHost $Node.SshUser
    $target = "$($Node.SshUser)@$($Node.SshHost)"
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ssh.Source
    $startInfo.Arguments = "-p $($Node.SshPort) $target `"$RemoteCommand`""
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    foreach ($line in $Lines) { $process.StandardInput.Write($line); $process.StandardInput.Write("`n") }
    $process.StandardInput.Close()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "SSH deployment failed with exit code $($process.ExitCode)." }
}

function Deploy-Node([string]$Id) {
    $node = Get-Node $Id
    $target = "$($node.SshUser)@$($node.SshHost)"
    Write-Host "正在部署 $($node.Platform) 节点 $Id 到 $target..." -ForegroundColor Cyan

    if ($node.Platform -eq "windows") {
        $preamble = @(
            "`$env:TS_AUTHKEY=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`"$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($node.AuthKey)))`"))",
            "`$env:TS_HOSTNAME=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`"$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($node.Hostname)))`"))",
            "`$env:TS_EXTRA_ARGS=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`"$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($node.ExtraArgs)))`"))"
        )
        $payload = @($preamble + (Get-Content $JoinWindowsScript))
        Invoke-SshPayload $node "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command -" $payload
    }
    else {
        $remote = if ($node.UseSudo) { "sudo -n sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'" }
            else { "sh -c 'IFS= read -r TS_AUTHKEY; IFS= read -r TS_HOSTNAME; IFS= read -r TS_EXTRA_ARGS; export TS_AUTHKEY TS_HOSTNAME TS_EXTRA_ARGS; sh'" }
        $payload = @($node.AuthKey, $node.Hostname, $node.ExtraArgs) + @((Get-Content $JoinUnixScript | Select-Object -Skip 1))
        Invoke-SshPayload $node $remote $payload
    }
}

function Install-DockerDesktop {
    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $docker) {
        $candidate = "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe"
        if (Test-Path $candidate) {
            $env:Path = "$(Split-Path -Parent $candidate);$env:Path"
            $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
        }
    }
    if (-not $docker) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) { throw "请先安装 Docker Desktop，或安装 winget 后重试。" }
        & $winget.Source install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "Docker Desktop 安装失败。" }
        $dockerPath = "$env:ProgramFiles\Docker\Docker\resources\bin"
        $env:Path = "$dockerPath;$env:Path"
    }
    $desktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) { Start-Process $desktop -ErrorAction SilentlyContinue }
    for ($i = 0; $i -lt 60; $i++) {
        & docker.exe compose version *> $null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    throw "Docker Desktop 在 2 分钟内没有就绪。"
}

function Deploy-Main {
    Install-DockerDesktop
    $hostname = Read-Default "DERP 域名" "bs.de.933999.xyz"
    if ($hostname -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$') { throw "DERP 域名格式无效。" }
    $derpPort = Read-Default "DERP 对外 TCP 端口" "8443"; Assert-Port $derpPort
    $backendPort = Read-Default "DERP 本地后端端口" "8080"; Assert-Port $backendPort
    $stunPort = Read-Default "STUN UDP 端口" "3478"; Assert-Port $stunPort
    $regionId = [int](Read-Default "DERP Region ID" "901")
    if ($regionId -lt 1) { throw "DERP Region ID 必须是正整数。" }
    $regionCode = Read-Default "DERP Region Code" "de-bs"
    $regionName = Read-Default "DERP Region Name" "Germany BS"

    @(
        "DERP_HOSTNAME='$hostname'", "DERP_PORT='$derpPort'", "DERP_BACKEND_PORT='$backendPort'",
        "DERP_BIND_ADDRESS='127.0.0.1'", "STUN_PORT='$stunPort'", "DERP_REGION_ID='$regionId'",
        "DERP_REGION_CODE='$regionCode'", "DERP_REGION_NAME='$regionName'", "TAILSCALE_VERSION='v1.98.9'"
    ) | Set-Content -Path (Join-Path $ProjectDir ".env") -Encoding ASCII
    @("https://${hostname}:${derpPort} {", "    reverse_proxy 127.0.0.1:${backendPort}", "}") |
        Set-Content -Path (Join-Path $ProjectDir "Caddyfile.snippet") -Encoding ASCII

    $map = @{ derpMap = @{ OmitDefaultRegions = $false; Regions = @{
        ([string]$regionId) = @{ RegionID = $regionId; RegionCode = $regionCode; RegionName = $regionName; Nodes = @(
            @{ Name = "${regionId}a"; RegionID = $regionId; HostName = $hostname; DERPPort = [int]$derpPort; STUNPort = [int]$stunPort }
        ) }
    } } }
    $map | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $ProjectDir "derp-map.json") -Encoding UTF8
    Push-Location $ProjectDir
    try { & docker.exe compose up -d --build; if ($LASTEXITCODE -ne 0) { throw "Docker Compose deployment failed." } }
    finally { Pop-Location }
    Write-Host "DERP 已部署。请合并 Caddyfile.snippet 和 derp-map.json。" -ForegroundColor Green
}

function Main-ServiceMenu {
    if (-not (Test-Path (Join-Path $ProjectDir ".env"))) {
        Write-Host "主 DERP 服务尚未配置，请先选择部署。" -ForegroundColor Yellow
        return
    }
    $choice = Read-Default "主服务操作: start/stop/restart/status/logs/uninstall/back" "status"
    if ($choice -eq "back") { return }
    Push-Location $ProjectDir
    try {
        switch ($choice) {
            "start" { & docker.exe compose up -d }
            "stop" { & docker.exe compose stop }
            "restart" { & docker.exe compose restart }
            "status" { & docker.exe compose ps }
            "logs" { & docker.exe compose logs --tail 100 -f derper }
            "uninstall" { if ((Read-Default "删除容器和持久化密钥 (yes/no)" "no") -eq "yes") { & docker.exe compose down -v } }
            default { Write-Host "无效操作。" -ForegroundColor Red }
        }
    }
    finally { Pop-Location }
}

function Join-LocalDevice {
    $env:TS_AUTHKEY = Read-Secret "Tailscale auth key"
    $env:TS_HOSTNAME = Read-Default "Tailscale hostname" $env:COMPUTERNAME
    $env:TS_EXTRA_ARGS = Read-Default "额外 tailscale up 参数"
    & $JoinWindowsScript
}

function Show-Menu {
    Assert-Admin
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "        Tailscale DERP 跨平台管理器 - Windows" -ForegroundColor Green
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host " 1. 部署或更新主 DERP 服务"
        Write-Host " 2. 管理主 DERP 服务"
        Write-Host " 3. 安装 Tailscale 并让当前设备加入网络"
        Write-Host "-------------------------------------------------------"
        Write-Host " 4. 添加子节点配置"
        Write-Host " 5. 查看子节点列表"
        Write-Host " 6. 查看子节点配置"
        Write-Host " 7. 修改子节点配置"
        Write-Host " 8. 通过 SSH 部署子节点"
        Write-Host " 9. 删除子节点配置"
        Write-Host " 0. 退出"
        Write-Host "=======================================================" -ForegroundColor Cyan
        $choice = Read-Host "请选择 [0-9]"
        try {
            switch ($choice) {
                "1" { Deploy-Main }
                "2" { Main-ServiceMenu }
                "3" { Join-LocalDevice }
                "4" { Add-Node }
                "5" { List-Nodes }
                "6" { Show-Node (Read-Default "节点 ID") }
                "7" { Edit-Node (Read-Default "节点 ID") }
                "8" { Deploy-Node (Read-Default "节点 ID") }
                "9" { Remove-Node (Read-Default "节点 ID") }
                "0" { return }
                default { Write-Host "无效选择。" -ForegroundColor Red }
            }
        }
        catch { Write-Host "错误: $_" -ForegroundColor Red }
        if ($choice -ne "0") { Read-Host "按 Enter 返回主菜单" | Out-Null }
    }
}

if ($env:TAILSCALE_MANAGER_NO_MENU -ne "1") {
    Show-Menu
}
