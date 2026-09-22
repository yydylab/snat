# Linux SNAT Manager

用于 Linux 服务器的交互式 SNAT、端口放行与防火墙策略管理脚本。

脚本会检测当前系统和防护墙软件，按出口接口维护 NAT 与端口规则，并提供初始化备份和多版本配置快照，方便在调整 VPN、内网转发或多网卡出口时安全回退。

## 功能

- 自动识别 Debian、Ubuntu、RHEL、Rocky Linux、AlmaLinux、Fedora、Alpine、Arch 等发行版
- 自动选择可用的防护墙软件：`firewalld`、`ufw`、`nftables`、`iptables`
- 按接口维护多个 SNAT 源网段，使用 `MASQUERADE`
- 按接口维护 TCP、UDP、TCP+UDP、ICMP 端口放行规则
- 配置 IPv4 路由转发
- 配置入站、出站、转发三项安全策略
- 使用 systemd 或 OpenRC 持久化恢复规则
- 首次运行自动备份宿主机防火墙与 IPv4 转发配置
- 支持保存多个配置快照、选择快照载入及删除用户快照

## 安装与运行

```bash
curl -fsSL -o snat.sh https://raw.githubusercontent.com/yydylab/snat/main/snat.sh
chmod +x snat.sh
sudo ./snat.sh
```

也可以使用 `wget`：

```bash
wget -O snat.sh https://raw.githubusercontent.com/yydylab/snat/main/snat.sh
chmod +x snat.sh
sudo ./snat.sh
```

脚本必须以 `root` 运行。

## 主菜单

| 编号 | 功能 | 概览 |
| --- | --- | --- |
| `01` | 重检本机环境 | 系统信息 |
| `02` | 选择配置接口 | 默认路由出口接口 |
| `03` | 配置安全策略 | 入站、出站、转发的允许或拒绝状态 |
| `04` | 配置路由转发 | IPv4 转发状态与设置 |
| `05` | 配置端口策略 | 已配置端口放行规则数量 |
| `06` | 配置NAT规则 | 已配置 SNAT 规则数量 |
| `07` | 查询配置明细 | 汇总 NAT 与端口策略 |
| `08` | 保存配置快照 | 创建当前待应用配置的快照 |
| `09` | 回退快照配置 | 选择并载入历史配置快照 |
| `10` | 应用保存配置 | 应用并持久化当前策略与规则 |
| `11` | 更新最新脚本 | 从主/备用地址更新脚本 |
| `99` | 退出脚本 | 退出程序 |

## 配置流程

1. 使用 `01` 检查系统、防护墙软件、IPv4 转发和当前接口状态。
2. 使用 `02` 选择要配置的出口接口。
3. 按需在 `03`、`04`、`05`、`06` 中配置安全策略、转发、端口和 NAT 规则。
4. 使用 `08` 为当前配置保存一个快照。
5. 使用 `10` 确认后应用并持久化配置。

`05` 和 `06` 中的修改仅在内存中待应用；执行 `10` 前不会写入宿主机防火墙规则。

## 备份与快照

### 初始化宿主机备份

首次启动时，脚本会创建仅一次的宿主机初始化备份：

```text
/etc/vpn-fw-helper/initial-backup
```

该备份包含与恢复相关的 IPv4 转发、`iptables`、`ip6tables`、`nftables`、`ufw`、`firewalld` 配置和状态信息，用于保留脚本首次运行前的基线。

### 配置快照

配置快照目录：

```text
/etc/vpn-fw-helper/snapshots
```

首次启动会自动建立 `000-initial` 初始化配置快照，该快照不可删除。之后通过 `08` 创建的用户快照以时间编号保存，可在 `09` 中：

- 输入快照编号载入该配置
- 输入 `d` 加编号删除用户快照，例如 `d2`

载入快照不会立即修改宿主机。确认载入后，请使用 `10` 应用保存。

## 使用场景

- OpenVPN、WireGuard、IPsec、SoftEther 等 VPN 客户端出口转发
- 多网卡服务器按不同接口配置 SNAT
- 内网网段访问公网
- VPS NAT、实验室网络或容器网络的出口转发

常见接口包括：

```text
eth0
ens18
ens192
enp1s0
tun0
wg0
ppp0
docker0
```

## 注意事项

- 云服务器还需要在安全组或云防火墙中放行相应端口。
- 请先确认当前 SSH 管理端口和默认安全策略，避免把自己锁在服务器外。
- 规则持久化依赖系统可用的 systemd 或 OpenRC。
- `11` 自更新使用脚本内配置的主地址与备用地址；若自行 Fork，请按需修改脚本中的更新地址。

## License

[MIT](LICENSE)
