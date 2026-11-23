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
│   └── test-repo.sh                       # 仓库一致性、脚本静态检查与 verify.sh 单元测试
├── common/
│   └── files/                             # 跨设备通用预置文件（先拷入构建目录）
│       └── etc/
│           └── uci-defaults/
│               └── 99-z0-common           # 通用初始化（上海时区、中文、Argon 默认主题）
├── devices/
│   └── n3160-i210/                        # 首个设备档案：Intel N3160 + I210 纯有线主路由
│       ├── device.env                     # 上游源、版本标签、目标路径与产物匹配规则
│       ├── seed.config                    # 该设备完全独立的差异配置（不做多文件拼接）
│       ├── verify.sh                      # 编译前 .config 正反向 Fail-Fast 校验脚本
│       └── files/                         # 设备专属预置文件（后拷入，可覆盖 common）
│           └── etc/
│               ├── rc.local               # CPU schedutil、I210 Ring/EEE、静态 IRQ + WAN RPS
│               ├── sysctl.d/
│               │   └── 99-router.conf     # 4GB 内存、conntrack 与网络协议栈调优
│               └── uci-defaults/
│                   └── 99-z9-device       # 禁用 packet_steering 与 autocore 启动脚本冲突
└── README.md
```

---

## 触发编译

1. 打开仓库 **Actions** 页面，选择 **Build Firmware**。
2. 点击 **Run workflow** 并填写参数：
   - `device`：目标设备目录名（当前可选 `n3160-i210`）。
   - `ref_override`：临时覆盖 `device.env` 中的 `UPSTREAM_REF`（例如测试新 tag `v25.12.3`），留空则使用默认值。
   - `use_cache`：是否启用分层的 `dl/` 与 `.ccache/` 缓存（默认 `true`）。
   - `publish_release`：是否自动发布带设备前缀的 GitHub Release（Tag 格式为 `<device>-<ref>-YYYYMMDD-r<run_number>`，默认 `true`）。
   - `ssh_debug`：是否在下载/编译前挂载 `tmate` 调试终端（默认 `false`，强制启用 `limit-access-to-actor: true`，需在个人 GitHub 账号中预先配置 SSH 公钥）。

---

## 首个设备档案：`n3160-i210`

### 硬件与固件基线
- **硬件平台**：Intel Celeron N3160（Braswell / Airmont，4C4T，支持 SSE4.1/4.2、AES-NI、PCLMULQDQ，不支持 AVX/AVX2），4GB RAM，Intel I210 网卡（`kmod-igb`，4 Tx / 4 Rx 队列），纯有线无 Wi-Fi。
- **固件基线**：ImmortalWrt `v25.12.2`（Linux `6.12`，`firewall4` / `nftables`，`apk` 包管理）。
- **编译优化**：`-O2 -pipe -march=silvermont -maes -mpclmul`，开启 `ccache`。
- **镜像输出**：仅生成 UEFI SquashFS 镜像（`*squashfs-combined-efi.img.gz`），根分区默认 `512 MiB`。
- **核心功能**：PPPoE + 原生 IPv6 / DHCPv6-PD、Wake-on-LAN、KMS（`vlmcsd`）、UPnP（强制 `miniupnpd-nftables`）、DDNS（`ddns-scripts` + 阿里云 + Cloudflare，内置 `bind-host` 与 `openssl-util`）、ZeroTier、LuCI HTTPS（`luci-ssl-openssl`）+ Argon 主题 + 中文语言包、完整运维工具（`vim-full`、`htop`、`ethtool-full`、`ip-full`、`tcpdump-mini`、`iperf3`、`mtr-nojson`、`bind-dig`、`lm-sensors`、`pciutils`、`openssh-sftp-server`）。

### 常见定制入口
| 定制项 | 修改位置 | 说明 |
| --- | --- | --- |
| 根分区大小 | [seed.config](devices/n3160-i210/seed.config) | 修改 `CONFIG_TARGET_ROOTFS_PARTSIZE=512`（同步更新 `verify.sh` 中对应数值） |
| DDNS 服务商子包 | [seed.config](devices/n3160-i210/seed.config) | 取消注释 `ddns-scripts-dnspod` / `ddns-scripts-dnspod-v3` / `ddns-scripts-huaweicloud` / `ddns-scripts-cnkuai` |
| WAN 物理网口名 | [rc.local](devices/n3160-i210/files/etc/rc.local) | 顶部 `WAN_IF=""` 默认自动从 UCI 探测并剥离 VLAN 后缀；若需指定可改为 `WAN_IF="eth0"` 等 |
| 内核网络栈参数 | [99-router.conf](devices/n3160-i210/files/etc/sysctl.d/99-router.conf) | 调整 `nf_conntrack_max`、`netdev_budget_usecs` 等参数 |

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

# 4. 检查静态 IRQ 绑核与 WAN 单口 RPS / LAN 纯硬件 RSS 状态
grep -E 'CPU0|igb|TxRx' /proc/interrupts
cat /proc/sys/net/core/rps_sock_flow_entries
for q in /sys/class/net/eth*/queues/rx-*; do
  echo "$q: rps_cpus=$(cat "$q/rps_cpus") rps_flow_cnt=$(cat "$q/rps_flow_cnt")"
done

# 5. 检查 packet_steering 与 autocore 服务已禁用（防止覆盖 RPS）
/etc/init.d/packet_steering enabled || echo "packet_steering disabled OK"
/etc/init.d/autocore enabled || echo "autocore disabled OK"

# 6. 检查温度传感器、CPU 微码加载与 iTCO 硬件看门狗
sensors
dmesg | grep -iE 'microcode|iTCO|coretemp'
ubus call system watchdog

# 7. 检查 sysctl 与 BBR 拥塞控制生效状态
sysctl kernel.panic net.ipv4.tcp_congestion_control \
  net.netfilter.nf_conntrack_max net.core.netdev_max_backlog \
  net.core.netdev_budget net.core.netdev_budget_usecs
```

---

## 如何新增设备或接入其他 OpenWrt 变种

只需 3 步，无需修改工作流核心逻辑：

1. **创建设备目录与档案文件**：新建 `devices/<new-device>/` 并放入以下文件：
   - `device.env`：定义 `DEVICE_NAME`（必须与目录名一致）、`DEVICE_TITLE`、`UPSTREAM_FLAVOR`（如 `immortalwrt` / `openwrt`）、`UPSTREAM_REPO`、`UPSTREAM_REF`、`TARGET_DIR`、`ARTIFACT_GLOB`、`PKG_MANAGER`（`apk` 或 `opkg`）。
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
