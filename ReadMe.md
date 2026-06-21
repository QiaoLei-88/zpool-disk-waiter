# zpool-disk-waiter

**OpenZFS on Linux 环境下极致确定性的开机物理拓扑守卫。**

## 🚨 背景与痛点

在 Linux 环境下管理拥有大量物理硬盘的 ZFS 存储池（如连接在 SAS HBA 扩展柜背板上的高密度 HDD 阵列）时，系统启动阶段经常面临一个经典的时序问题：

系统盘（NVMe/SSD）通常会极快地完成启动，并触发原生 `zfs-import-cache.service`。然而，大型 JBOD 扩展柜为了保护电源，需要较长时间执行**错位起转（Staggered Spin-up）**。如果 ZFS 在底层物理硬盘完全就绪前尝试导入，将导致阵列意外降级、无法挂载，甚至使系统进入救援模式（Emergency Mode）。

这一现象主要源于现代系统架构演进中的一些客观限制：

* **系统启动机制的演进**：现代 Linux（如 Systemd）已废弃了传统的 `systemd-udev-settle`（阻塞等待全部硬件就绪）服务，全面转向异步事件驱动架构。
* **跨平台架构的边界**：OpenZFS 作为跨平台文件系统，其底层机制并未原生内置针对单一操作系统的长期硬件轮询死等逻辑。
* **现有桥接方案的局限**：官方尝试通过 `zfs-mount-generator` 动态生成 Systemd `.device` 依赖，但在实际应用中带来了逻辑黑盒化、多存储池（快盘 vs 慢盘）难以设置独立超时容限等运维痛点。

**本项目旨在填补这一工程断层。** 我们采用“关注点分离”的架构哲学，通过轻量级、非侵入式的前置时序屏障，为 ZFS 解决开机认盘的最后一块拼图。

## 💡 架构哲学：关注点分离

`zpool-disk-waiter` 摒弃了危险的“强行接管 ZFS 导入”模式，全面拥抱 **UNIX 哲学与 Systemd 生态**，采用“三位一体”的设计：

1. **静态清单预编译 (AOT Manifest)**：平时（运行态）由 Python 脚本提取 ZFS 的健康物理拓扑，只保留绝对确定的 `ONLINE` 状态设备的物理路径，生成静态检录清单（`.list`）。
2. **极简前置屏障 (Minimalist Barrier)**：开机时，Bash 脚本作为 `ExecStartPre` 前置拦截器运行。它秉持“登机门地服”逻辑：手里拿着名单，站在 `/dev/disk/by-id` 门口点名。只查物理存在性，绝不越权执行导入动作。拓扑对齐瞬间放行；若超时则强制关门。
3. **无损移交裁决 (Delegated Adjudication)**：**这是本项目的核心护城河。** 无论全员到齐，还是超时缺盘，脚本最终均以 `exit 0` 优雅退场。将后续的残缺阵列容错判定、降级（DEGRADED）挂载与实际导入工作，完整归还给 ZFS 原生核心引擎（机长/签派）。绝不因为误判而把原本可以安全降级上线的阵列彻底锁死。
4. **ZED 异步状态门控 (State-Gating ZED)**：集成 ZFS Event Daemon (ZED) 自动追踪拓扑变更。仅在存储池健康或处于重构（Resilvering）状态时，后台才会静默更新静态清单；若发生意外掉盘，系统挂起更新，防止物理缺盘故障被掩盖。

## 🏗️ 核心组件

* `/usr/local/bin/zpool-waiter-generator.py`：智能清单生成器，执行严格的正向过滤（Whitelist）。
* `/usr/local/bin/zpool-disk-waiter.sh`：确定性拓扑检录与时序阻塞脚本（点名员）。
* `/etc/systemd/system/zfs-import-cache.service.d/override.conf`：Systemd 补充补丁。仅注入 `ExecStartPre` 前置岗哨，不对官方核心启动流做任何破坏。
* `/etc/zfs/zed.d/` 下的各类事件钩子：实现拓扑变化与静态清单的无感自愈同步。

## 🚀 安装部署

本项目没有任何外部依赖，仅需标准的 Bash、Python 3 以及就绪的 ZFS/Systemd 环境。

```bash
git clone https://github.com/yourusername/zpool-disk-waiter.git
cd zpool-disk-waiter
sudo ./install.sh

```

> **🛡️ 安装安全性**：`install.sh` 执行逻辑严谨克制。全程采用透明的原子化安全部署，不破坏管理员环境，权限精确收缩至最小可用级别，随时可无痕回滚。

## ⚙️ 高级配置

项目安装后开箱即用，默认会为所有的存储池提供长达 **5 分钟（60次 * 5秒）** 的拓扑就绪宽限期（盘齐立刻放行，零性能损耗）。

如果您拥有多组存储池，例如一组秒速上线的 NVMe 阵列 `fastpool`，和一组需要长时间起转的 HDD 归档池 `tank`，您可以为每个池单独配置超时轮次。

创建配置文件 `/etc/zpool-disk-waiter/[存储池名称].conf`：

```bash
# 示例: /etc/zpool-disk-waiter/fastpool.conf
# 为 NVMe 池配置更激进的超时熔断策略
MAX_RETRIES=12        # 最大轮询 12 次
CHECK_INTERVAL=5      # 每次间隔 5 秒

```

保存后即刻生效。开机接管脚本会自动识别并应用此独立策略。

*(注：上层业务服务如 Nginx 或 KVM 虚拟机，建议搭配 Systemd 原生的 `RequiresMountsFor=/挂载点` 机制，以实现应用随底层存储精确起停的完美闭环。)*

## ⚠️ 免责声明

**本软件按“原样”提供，不提供任何形式的担保。**

本项目提供的所有脚本严格执行只读的拓扑核对与时序阻塞，设计中不包含任何干涉数据流或更改 ZFS 状态的指令。

但在涉及系统引导链与底层存储控制的场景下，仍具备客观环境风险。使用本软件即表示您同意自行对系统的稳定性与数据完整性负责。作者不对任何因使用或无法使用本软件而导致的包括但不限于数据丢失、系统停机或硬件损坏负责。**请务必先在非生产环境中进行验证测试。**

*注：若本项目的多语言文档或协议翻译之间存在语义分歧，均以当前的中文版本（zh-CN）为准。*

## 📜 开源协议

本项目采用 **GNU General Public License v2.0 (GPLv2)** 协议开源 - 详情请参阅 LICENSE 文件。
