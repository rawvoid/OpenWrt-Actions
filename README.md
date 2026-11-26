# OpenWrt-Actions

面向**多设备、多 OpenWrt 变种（ImmortalWrt / 官方 OpenWrt 等）**的模块化固件自动化编译工程。通过“设备档案自包含 + 分层文件叠加 + 编译前 Fail-Fast 校验”设计，新增设备或切换分支无需改动核心 CI 工作流。

> **安全原则**：仓库面向 Public 运行以使用 GitHub 免费 4 核 Runner，严禁提交任何个人密码、PPPoE 账号、DDNS API Key 或 ZeroTier Network ID。

---

## 目录结构

```text
OpenWrt-Actions/
├── .editorconfig
├── .gitignore
├── .github/
│   └── workflows/
│       ├── build.yml                      # 通用多设备/多变种构建工作流
│       └── lint.yml                       # Push / PR 自动语法、ShellCheck 与配置同步校验
├── scripts/
│   ├── collect-artifacts.sh               # 固件收集、SHA256 校验与 Release Notes 生成
│   ├── configure-lan-ip.sh                # 默认 LAN IP 合法性校验与 config_generate 注入
│   └── test-repo.sh                       # 仓库一致性、脚本静态检查与单元测试
├── common/
│   └── files/                             # 跨设备通用预置文件（先拷入构建目录）
│       └── etc/
│           └── uci-defaults/
│               └── 99-z0-common           # 通用初始化（上海时区、中文、Argon 默认主题）
├── devices/
│   ├── n3160-i210/                        # Intel N3160 + I210 纯有线主路由（ImmortalWrt）
│   │   ├── device.env                     # 上游源、版本标签、目标路径与产物匹配规则
│   │   ├── seed.config                    # 该设备完全独立的差异配置（不做多文件拼接）
│   │   ├── verify.sh                      # 编译前 .config 正反向 Fail-Fast 校验脚本
│   │   └── files/                         # 设备专属预置文件（后拷入，可覆盖 common）
│   │       └── etc/
│   │           ├── init.d/
│   │           │   └── n3160-tune         # START=19 调优服务（前置 Ring/EEE、1:1 IRQ/XPS + WAN RPS）
│   │           ├── sysctl.d/
│   │           │   └── 99-router.conf     # 4GB 内存、conntrack 与网络协议栈调优
│   │           └── uci-defaults/
│   │               └── 99-z9-device       # 禁用 packet_steering 与 autocore 启动脚本冲突
│   ├── redmi-ax6-stock/                   # Redmi AX6 原厂分区无线主路由（纯官方 ImmortalWrt）
│   │   ├── device.env                     # immortalwrt/immortalwrt v25.12.2，默认 LAN IP 192.168.10.1
│   │   ├── seed.config                    # 精简主路由配置（标准 SQM/CAKE，无 NSS）
│   │   ├── verify.sh                      # 原厂分区防砖护栏 + 精简包校验
│   │   └── files/etc/sysctl.d/99-router.conf
│   └── redmi-ax6-stock-nss/               # Redmi AX6 原厂分区满血 NSS 主路由（LiBwrt）
│       ├── device.env                     # LiBwrt/LibWrt v25.12.2，默认 LAN IP 192.168.10.1
│       ├── seed.config                    # 满血 NSS（512M 内存档案 + Wi-Fi Offload + NSS SQM）
│       ├── verify.sh                      # 原厂分区 + 512M NSS/ath11k 内存护栏 + 精简包校验
│       └── files/
│           └── etc/
│               ├── sysctl.d/99-router.conf
│               └── uci-defaults/99-z9-device  # 禁用 packet_steering 与内核 Flow Offloading 防止与 NSS 冲突
└── README.md
```

---

## 触发编译

1. 打开仓库 **Actions** 页面，选择 **Build Firmware**。
2. 点击 **Run workflow** 并填写参数：
   - `device`：目标设备目录名（可选 `n3160-i210`、`redmi-ax6-stock`、`redmi-ax6-stock-nss`）。
   - `ref_override`：临时覆盖 `device.env` 中的 `UPSTREAM_REF`（例如测试新 tag `v25.12.3`），留空则使用默认值。
   - `lan_ip`：动态覆盖 `device.env` 中的 `DEFAULT_LAN_IP`（仅支持 RFC1918 私网 IPv4，如 `10.11.1.1`、`192.168.10.1`），留空则使用 `device.env` 默认值（若也为空则沿用上游 `192.168.1.1`）；通过修改 `package/base-files/files/bin/config_generate` 生效（首次刷机与重置生效，保留配置升级不覆盖）。
   - `use_cache`：是否启用分层的 `dl/` 与 `.ccache/` 缓存（默认 `true`）。
   - `publish_release`：是否自动发布带设备前缀的 GitHub Release（Tag 格式为 `<device>-<ref>-YYYYMMDD-r<run_number>`，默认 `true`）。
   - `ssh_debug`：是否在下载/编译前挂载 `tmate` 调试终端（默认 `false`，强制启用 `limit-access-to-actor: true`，需在个人 GitHub 账号中预先配置 SSH 公钥）。

---

## 首个设备档案：`n3160-i210`

### 硬件与固件基线
- **硬件平台**：Intel Celeron N3160（Braswell / Airmont，4C4T，支持 SSE4.1/4.2、AES-NI、PCLMULQDQ，不支持 AVX/AVX2），4GB RAM，Intel I210 网卡（`kmod-igb`，4 Tx / 4 Rx 队列），纯有线无 Wi-Fi。
- **固件基线**：ImmortalWrt `v25.12.2`（Linux `6.12`，`firewall4` / `nftables`，`apk` 包管理）。
- **编译优化**：`-O2 -pipe -march=silvermont -maes -mpclmul`，开启 `ccache`。
- **镜像输出**：同时生成 Legacy BIOS/MBR（`*squashfs-combined.img.gz`）与 UEFI/GPT（`*squashfs-combined-efi.img.gz`）SquashFS 双镜像，GRUB 菜单超时 `3s`，根分区默认 `1024 MiB`。
- **核心功能**：PPPoE + 原生 IPv6 / DHCPv6-PD、Wake-on-LAN、KMS（`vlmcsd`）、UPnP（强制 `miniupnpd-nftables`）、DDNS（`ddns-scripts` + 阿里云 + Cloudflare，内置 `bind-host` 与 `openssl-util`）、ZeroTier、SQM/CAKE 队列整形（`luci-app-sqm` + `kmod-sched-cake`）、Watchcat 断网守护（`luci-app-watchcat`）、LuCI HTTPS（`luci-ssl-openssl`）+ Argon 主题 + 中文语言包、完整运维工具（`vim-full`、`htop`、`ethtool-full`、`ip-full`、`tcpdump-mini`、`iperf3`、`mtr-nojson`、`bind-dig`、`lm-sensors`、`pciutils`、`smartmontools`、`lsblk`、`jq`、`openssh-sftp-server`）；并精简了 `automount`、`kmod-drm-i915` 与 `i915-firmware-dmc`。

### 常见定制入口
| 定制项 | 修改位置 | 说明 |
| --- | --- | --- |
| 默认 LAN IP | [device.env](devices/n3160-i210/device.env) / `lan_ip` | 默认 `10.11.1.1`，支持在触发构建时通过 `lan_ip` 输入框动态覆盖 |
| 根分区大小 | [seed.config](devices/n3160-i210/seed.config) | 修改 `CONFIG_TARGET_ROOTFS_PARTSIZE=1024`（同步更新 `verify.sh` 中对应数值） |
| DDNS 服务商子包 | [seed.config](devices/n3160-i210/seed.config) | 取消注释 `ddns-scripts-dnspod` / `ddns-scripts-dnspod-v3` / `ddns-scripts-huaweicloud` / `ddns-scripts-cnkuai` |
| WAN 物理网口名 | [n3160-tune](devices/n3160-i210/files/etc/init.d/n3160-tune) | 顶部 `WAN_IF=""` 默认自动从 UCI 探测并剥离 VLAN 后缀；若需指定可改为 `WAN_IF="eth0"` 等 |
| 内核网络栈参数 | [99-router.conf](devices/n3160-i210/files/etc/sysctl.d/99-router.conf) | 调整 `nf_conntrack_max`、`netdev_max_backlog`、`netdev_budget` 等参数 |

### 刷机后验证命令

SSH 登录路由器后执行以下命令确认各项硬件驱动与调优生效：

```sh
# 1. 查看调优日志与已生效的 WAN 口识别结果
logread -e n3160-tune

# 2. 检查 CPU 调频驱动与当前策略（应为 intel_cpufreq + schedutil）
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor

# 3. 检查 Intel I210 驱动、Ring Buffer（RX/TX 1024）与 EEE（Disabled）
for eth in /sys/class/net/eth*; do
  dev="${eth##*/}"
  echo "=== $dev ==="
  ethtool -i "$dev" | grep -E 'driver|version'
  ethtool -g "$dev" | sed -n '/Current hardware settings:/,$p'
  ethtool --show-eee "$dev" 2>/dev/null || true
done

# 4. 检查 1:1 IRQ/XPS 同核对齐与 WAN 单口纯 RPS / LAN 纯硬件 RSS 状态
grep -E 'CPU0|igb|TxRx' /proc/interrupts
cat /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/eth*/queues/rx-*; do
  echo "$q: rps_cpus=$(cat "$q/rps_cpus") rps_flow_cnt=$(cat "$q/rps_flow_cnt")"
done
for q in /sys/class/net/eth*/queues/tx-*; do
  echo "$q: xps_cpus=$(cat "$q/xps_cpus")"
done

# 5. 检查 n3160-tune 已启用，且 packet_steering 与 autocore 服务已禁用（防止覆盖 RPS）
/etc/init.d/n3160-tune enabled && echo "n3160-tune enabled OK"
/etc/init.d/packet_steering enabled || echo "packet_steering disabled OK"
/etc/init.d/autocore enabled || echo "autocore disabled OK"

# 6. 检查温度传感器、CPU 微码加载与 iTCO 硬件看门狗
sensors
dmesg | grep -iE 'microcode|iTCO|coretemp'
ubus call system watchdog

# 7. 检查 sysctl 与 BBR 拥塞控制生效状态
sysctl kernel.panic net.ipv4.tcp_congestion_control \
  net.netfilter.nf_conntrack_max net.core.netdev_max_backlog \
  net.core.netdev_budget
```

---

## 设备档案：`redmi-ax6-stock` 与 `redmi-ax6-stock-nss`

两套面向 **Redmi 路由器 AX6（原厂双分区 `redmi_ax6-stock`，35.75 MiB 活动分区）** 的平行主路由档案，默认 LAN IP 均为 `192.168.10.1`，可根据需要分别或并行触发编译：

| 档案名 | 上游基线 | 转发加速 | SQM 队列 | 适用场景 |
| --- | --- | --- | --- | --- |
| `redmi-ax6-stock` | `immortalwrt/immortalwrt` `v25.12.2` | 软件流卸载（按需在防火墙开启） | 标准 `luci-app-sqm` + `kmod-sched-cake` | 纯官方稳定保底，与官方签名 `apk` 源 100% 兼容 |
| `redmi-ax6-stock-nss` | `LiBwrt/LibWrt` `v25.12.2`（`ref_override` 可填 `25.12-nss` 追踪最新提交） | 高通满血 NSS（NAT/PPPoE/Bridge/VLAN + Wi-Fi Offload） | `luci-app-sqm` + `sqm-scripts-nss`（LuCI 中选 `nss-zk.qos`） | 跑满千兆有线/无线时 CPU 占用极低、发热量更低 |

### 硬件基线与共同配置
- **硬件平台**：Qualcomm IPQ8071A（4 核 Cortex-A53 1.4 GHz，支持 ARMv8 CRC/AES/SHA）、512 MiB RAM、128 MiB NAND（原厂双分区 `rootfs` / `rootfs_1` 各 35.75 MiB）、QCN5024（2.4G）+ QCN5054（5G）Wi-Fi 6，无 USB 接口。
- **编译优化**：`-Os -pipe -mcpu=cortex-a53+crc+crypto`（兼顾原厂分区紧凑体积与硬件加解密性能），开启 `ccache`。
- **镜像输出**：同时输出 `*redmi_ax6-stock-squashfs-factory.ubi`（首次原厂刷入 / U-Boot 刷入）与 `*redmi_ax6-stock-squashfs-sysupgrade.bin`（OpenWrt/ImmortalWrt 后台升级）。
- **已启用功能**：PPPoE + 原生 IPv6 / DHCPv6-PD、完整版 `wpad-openssl`（WPA3 / 802.11r/k/v）、LuCI HTTPS（`luci-ssl-openssl` + 默认 Bootstrap 主题 + 中文）、UPnP（`miniupnpd-nftables`）、DDNS（`ddns-scripts` + 阿里云 + Cloudflare + `openssl-util`，省略 `bind-host`）、Wake-on-LAN、KMS（`vlmcsd`）、SQM、Watchcat、TCP BBR、WireGuard、ZeroTier、流量统计（`luci-app-nlbwmon`）、静态 ARP 绑定（`luci-app-arpbind`）、运维工具（`openssh-sftp-server`、`curl`、`htop`、`iperf3`、`tcpdump-mini`、`ip-full`、精简版 `vim`）。
- **512 MiB 内存与原厂分区保护**：`redmi-ax6-stock-nss` 的 `verify.sh` 强制校验 `CONFIG_NSS_MEM_PROFILE_MEDIUM=y` 与 `CONFIG_ATH11K_MEM_PROFILE_512M=y`（阻止 IPQ807x 默认的 1GB 内存配置引发 OOM）；两套档案均禁止误编扩容布局 `redmi_ax6` 镜像，并剔除 AX6 无硬件对应的 USB / 存储 / PCIe Wi-Fi / Aquantia 10G PHY 驱动。

### 刷机与使用注意事项
- **分区确认**：仅适用于**原厂双分区**或兼容原厂分区表的第三方自定义 U-Boot；若已改为 OpenWrt 扩容单分区布局，请勿直接刷入。
- **两套固件互刷**：在 `redmi-ax6-stock` 与 `redmi-ax6-stock-nss` 之间通过 `sysupgrade` 切换时，请**不要勾选保留配置**，防止卸载开关与 SQM 队列脚本残留冲突。
- **NSS 版专用禁忌**：`redmi-ax6-stock-nss` 首次启动脚本 [99-z9-device](devices/redmi-ax6-stock-nss/files/etc/uci-defaults/99-z9-device) 已自动禁用 `packet_steering`、软件流卸载与硬件流卸载，日常请勿在防火墙里手动开启；同时避免使用 DSA `config bridge-vlan` 语法（与 NSS Wi-Fi Offload 不兼容）。
- **无线建议**：首次配置将国家代码设为 `CN`；5GHz 追求极稳推荐 `80MHz` 固定非 DFS 信道（如 36/44/149），2.4GHz 推荐 `20MHz` + `WPA2-PSK` 兼容老旧 IoT 设备。

### 刷机后验证命令

```sh
# 1. 查看闪存剩余空间与当前活动分区（rootfs 或 rootfs_1）
df -h /overlay
fw_printenv flag_boot_rootfs

# 2. 检查无线驱动与 512M 内存模式
dmesg | grep -iE 'ath11k|nss'
free -m

# 3. 仅 redmi-ax6-stock-nss：验证 NSS 驱动、ECM 加速与 Wi-Fi Offload 生效，且内核流卸载已关闭
lsmod | grep -E 'qca_nss|ecm'
cat /sys/module/ath11k/parameters/nss_offload
uci -q get network.globals.packet_steering
uci -q get firewall.@defaults[0].flow_offloading
```

---

## 如何新增设备或接入其他 OpenWrt 变种

只需 3 步，无需修改工作流核心逻辑：

1. **创建设备目录与档案文件**：新建 `devices/<new-device>/` 并放入以下文件：
   - `device.env`：定义 `DEVICE_NAME`（必须与目录名一致）、`DEVICE_TITLE`、`UPSTREAM_FLAVOR`（如 `immortalwrt` / `openwrt`）、`UPSTREAM_REPO`、`UPSTREAM_REF`、`TARGET_DIR`、`ARTIFACT_GLOB`、`PKG_MANAGER`（`apk` 或 `opkg`），以及可选的 `DEFAULT_LAN_IP`。
   - `seed.config`：通过 `make defconfig && ./scripts/diffconfig.sh` 导出的独立精简配置文件。
   - `verify.sh`（可选，推荐）：针对新设备的 `.config` 正反向校验脚本（`chmod +x`）。
   - `files/`（可选）：该设备专属根文件系统覆盖文件；其中 `etc/uci-defaults/` 建议使用 `99-z9-device` 命名以免与 `99-z0-common` 及上游默认脚本冲突（注意避免在 `apk` 基线下使用传统包管理命令）。
   - **可选扩展钩子**（按需放置于 `devices/<new-device>/` 根目录）：
     - `feeds.conf.append`：在 `./scripts/feeds update` 前追加自定义 feeds。
     - `pre-defconfig.sh`（`chmod +x`）：在 `make defconfig` 前执行对源码树的定制修改。

2. **注册工作流选项**：在 [.github/workflows/build.yml](.github/workflows/build.yml) 的 `inputs.device.options` 中追加一行 `- <new-device>`。

3. **本地自检**：运行仓库静态检查与单元测试，确保权限、YAML、ShellCheck 与选项列表完全同步：
   ```bash
   ./scripts/test-repo.sh
   ```

---

## 首次推送到 GitHub 前的仓库检查清单

- **仓库可见性**：建议设为 **Public**，以使用 GitHub 免费 4 核标准 Runner（Private 仓库受免费额度分钟数限制）。
- **Actions 权限**：进入 GitHub 仓库 **Settings → Actions → General → Workflow permissions**，确认选中 **Read and write permissions**（尽管 `build.yml` 已声明 `permissions: contents: write`，若组织/仓库策略禁止写入权限，Release 发布仍会被拦截）。
- **SSH 调试公钥（可选）**：仅当使用 `ssh_debug: true` 时，需确保触发工作流的 GitHub 账号下已绑定至少一把 SSH 公钥。
