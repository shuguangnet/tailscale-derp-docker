# Tailscale DERP 跨平台一键部署

参考 oneKeyEasyTier 的交互方式，用统一菜单部署自建 Tailscale DERP、管理服务和批量添加子节点。支持 Debian、Ubuntu、Alpine 等 Linux，支持 macOS 和 Windows。

| 系统 | 管理脚本 | Tailscale 安装 | DERP 运行方式 |
| --- | --- | --- | --- |
| Debian / Ubuntu | POSIX shell | 官方软件源 | Docker Engine |
| Alpine Linux | POSIX shell + OpenRC | 官方软件源 | Alpine Docker + OpenRC |
| 其他受 Tailscale 支持的 Linux | POSIX shell | 官方安装器 | Docker Engine |
| macOS | POSIX shell | 官方 PKG | Docker Desktop |
| Windows 10/11 | PowerShell | winget 或官方 MSI | Docker Desktop |
| Windows Server | PowerShell | winget 或官方 MSI | 建议仅作为节点，DERP 使用 Linux 主机/虚拟机 |

## 架构

- `derper` 容器：仅在宿主机 `127.0.0.1:8080` 提供 HTTP 后端。
- edge-caddy：在 `https://DERP_HOSTNAME:8443` 终止 TLS 并反向代理到 DERP。
- STUN：直接开放宿主机 `3478/udp`。

DNS 中必须先把 DERP 域名的 A/AAAA 记录指向服务器。防火墙需要开放 `8443/tcp` 和 `3478/udp`。

## 一键启动交互菜单

Debian、Ubuntu、Alpine 等 Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/install.sh | sudo sh
```

macOS 不要给整个菜单加 `sudo`，需要安装系统组件时脚本会单独请求权限：

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/install.sh | sh
```

Windows 请在“管理员 PowerShell”中运行：

```powershell
irm https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/install.ps1 | iex
```

菜单支持：

- 部署或更新主 DERP 服务
- 启动、停止、重启、查看状态和日志、卸载主服务
- 安装 Tailscale 并让当前设备加入网络
- 快速添加并立即部署子节点
- 查看子节点列表和脱敏配置
- 修改子节点 SSH、hostname、auth key 和额外参数
- 通过 SSH 把子节点加入 Tailscale
- 删除本地子节点配置
- 查看主 DERP 服务状态

快速添加子节点时只需输入：

1. SSH 地址，例如 `root@1.2.3.4` 或 `admin@host:2222`
2. 节点名称
3. 首次添加时输入一次 auth key

auth key 会安全保存并供后续节点复用。脚本通过 SSH 自动识别 Linux、macOS 或 Windows，并自动判断是否需要 sudo，然后立即安装和加入网络。Unix 非 `root` 用户需要具备免密码 sudo；Windows SSH 用户需要管理员权限。

Linux/macOS 节点配置按字段保存，auth key 文件权限为 `600`。Windows 配置保存在 `%ProgramData%\TailscaleDERP\nodes.json`，ACL 仅允许当前管理员和 Administrators 访问。

已经克隆仓库时也可以运行：

```sh
sudo sh manage.sh # Linux
sh manage.sh      # macOS
```

Windows 已下载的管理器位于 `%ProgramData%\TailscaleDERP\app\manage.ps1`。

## 非交互部署主服务

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/install.sh \
  | sudo DERP_HOSTNAME=bs.de.933999.xyz sh
```

也可以克隆后执行：

```sh
git clone https://github.com/shuguangnet/tailscale-derp-docker.git
cd tailscale-derp-docker
sudo DERP_HOSTNAME=bs.de.933999.xyz sh install.sh
```

安装目录默认为 `/opt/tailscale-derp-docker`。部署完成后，将生成的 `Caddyfile.snippet` 合并到宿主机 edge-caddy 配置并重新加载 Caddy：

```caddyfile
https://bs.de.933999.xyz:8443 {
    reverse_proxy 127.0.0.1:8080
}
```

如果 edge-caddy 运行在容器中，不能直接访问宿主机的 `127.0.0.1`。请让它访问宿主机网关地址，或把两个服务接入同一个 Docker 网络后代理到 `tailscale-derper:8080`。

## Tailscale Policy

部署会生成 `derp-map.json`。把其中的 `derpMap` 字段合并到 Tailscale 管理后台的 Access controls Policy 中。默认配置为：

```json
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "901": {
        "RegionID": 901,
        "RegionCode": "custom",
        "RegionName": "Custom DERP",
        "Nodes": [
          {
            "Name": "901a",
            "RegionID": 901,
            "HostName": "bs.de.933999.xyz",
            "DERPPort": 8443,
            "STUNPort": 3478
          }
        ]
      }
    }
  }
}
```

保存 Policy 后，在客户端运行 `tailscale netcheck`。看到 `901`、`bs.de.933999.xyz:8443` 或该节点为首选 DERP，说明配置已生效。

## 当前设备直接加入

在 Tailscale 后台的 **Settings / Keys / Auth keys** 创建 `Reusable`、`Pre-approved`、非 `Ephemeral` 的 auth key。

Linux：

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/scripts/tailscale-onekey-join-linux.sh \
  | sudo TS_AUTHKEY=tskey-auth-xxxxxxxx TS_HOSTNAME=my-node sh
```

macOS：

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/scripts/tailscale-onekey-join-linux.sh \
  | TS_AUTHKEY=tskey-auth-xxxxxxxx TS_HOSTNAME=my-mac sh
```

Windows 管理员 PowerShell：

```powershell
$env:TS_AUTHKEY = "tskey-auth-xxxxxxxx"
$env:TS_HOSTNAME = "my-windows"
irm https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/scripts/tailscale-onekey-join-windows.ps1 | iex
```

额外的 `tailscale up` 参数可通过 `TS_EXTRA_ARGS` 传入：

```sh
sudo TS_AUTHKEY=tskey-auth-xxxxxxxx \
  TS_HOSTNAME=my-exit-node \
  TS_EXTRA_ARGS='--advertise-exit-node --ssh' \
  sh scripts/tailscale-onekey-join-linux.sh
```

## 子节点高级管理

日常使用直接选择菜单中的“快速添加并部署子节点”。需要指定平台、端口、额外参数或单独 auth key 时，可以使用完整命令：

快速命令同样只需要 SSH 地址和节点名称：

```sh
sudo TS_AUTHKEY=tskey-auth-xxxxxxxx sh manage.sh node quick root@192.0.2.10 edge-1
```

完整高级配置：

```sh
sudo sh manage.sh node add \
  --id edge-1 \
  --platform alpine \
  --ssh-host 192.0.2.10 \
  --ssh-user root \
  --ssh-port 22 \
  --hostname edge-one \
  --auth-key tskey-auth-xxxxxxxx \
  --extra-args '--ssh' \
  --sudo no

sudo sh manage.sh node list
sudo sh manage.sh node show edge-1
sudo sh manage.sh node edit edge-1 --ssh-port 2222 --hostname edge-new
sudo sh manage.sh node deploy edge-1
sudo sh manage.sh node delete edge-1 --yes
```

删除操作只删除本机保存的配置，不会从 Tailscale 管理后台删除对应设备。

## 平台说明

- Linux 是生产 DERP 的推荐平台。
- macOS 和 Windows 可以通过 Docker Desktop 运行 DERP，适合开发、测试或具备稳定公网环境的主机。
- macOS 首次安装 Tailscale 后，系统可能要求批准 VPN/网络扩展。
- Windows Server 若没有 `winget`，脚本会下载 Tailscale 官方 MSI。Windows Server 建议作为 Tailscale 节点；生产 DERP 使用 Linux 主机或 Linux 虚拟机。
- macOS/Windows 上的 edge-caddy 如果运行在容器中，不能直接用容器内的 `127.0.0.1` 访问 DERP 后端，需要使用 `host.docker.internal:8080` 或共享 Docker 网络。

## 运维

```sh
cd /opt/tailscale-derp-docker
docker compose ps
docker compose logs -f derper
docker compose build --pull
docker compose up -d
```

升级 Tailscale 时修改 `.env` 中的 `TAILSCALE_VERSION`，再重新构建。当前默认固定为 `v1.98.9`，避免未审查的上游更新自动进入生产环境。

## 测试

```sh
sh tests/run.sh
```

测试覆盖 auth key 缺失、节点加入参数、服务启动调用、状态检查、DERP Policy 生成和非法端口校验。GitHub Actions 还会运行 ShellCheck 与 Compose 配置检查。

## 官方文档

- [Auth keys](https://tailscale.com/docs/features/access-control/auth-keys)
- [Custom DERP servers](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)
- [Quickstart](https://tailscale.com/docs/how-to/quickstart)
