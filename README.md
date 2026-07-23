# Tailscale DERP Docker 一键部署

用 Docker Compose 部署自建 Tailscale DERP，并提供 Linux 节点一键加入脚本。默认适配宿主机已有 edge-caddy、`443` 已被占用、DERP 对外使用 `8443` 的场景。

## 架构

- `derper` 容器：仅在宿主机 `127.0.0.1:8080` 提供 HTTP 后端。
- edge-caddy：在 `https://DERP_HOSTNAME:8443` 终止 TLS 并反向代理到 DERP。
- STUN：直接开放宿主机 `3478/udp`。

DNS 中必须先把 DERP 域名的 A/AAAA 记录指向服务器。防火墙需要开放 `8443/tcp` 和 `3478/udp`。

## 一键部署

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

## Linux 节点一键加入

在 Tailscale 后台的 **Settings / Keys / Auth keys** 创建 `Reusable`、`Pre-approved`、非 `Ephemeral` 的 auth key，然后执行：

```sh
curl -fsSL https://raw.githubusercontent.com/shuguangnet/tailscale-derp-docker/main/scripts/tailscale-onekey-join-linux.sh \
  | sudo TS_AUTHKEY=tskey-auth-xxxxxxxx TS_HOSTNAME=my-node sh
```

额外的 `tailscale up` 参数可通过 `TS_EXTRA_ARGS` 传入：

```sh
sudo TS_AUTHKEY=tskey-auth-xxxxxxxx \
  TS_HOSTNAME=my-exit-node \
  TS_EXTRA_ARGS='--advertise-exit-node --ssh' \
  sh scripts/tailscale-onekey-join-linux.sh
```

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
