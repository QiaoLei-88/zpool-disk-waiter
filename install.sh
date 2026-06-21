#!/bin/bash
# zpool-disk-waiter 一键部署脚本
# 请使用 root 权限运行

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] 请使用 root 权限运行 / Please run as root."
  exit 1
fi

# 建立全局安全结界：任何意外创建的文件默认 600，目录默认 700
umask 077

# 原子化安全部署函数：统一处理目录创建、文件拷贝、属主及权限
# 用法: secure_deploy <八进制权限> <源文件路径 | "-d"> <目标路径>
secure_deploy() {
    local mode="$1"
    local src="$2"
    local dest="$3"
    
    if [ "$src" == "-d" ]; then
        mkdir -pv "$dest"
        chmod -v "$mode" "$dest"
        chown -v root:root "$dest"
    else
        # 保持 -p 以留存原始修改时间 (mtime)，随后由 chown/chmod 实施原子化强行覆盖
        cp -ivp "$src" "$dest"
        chmod -v "$mode" "$dest"
        chown -v root:root "$dest"
    fi
}

echo "=== 开始安装 / Starting installation: zpool-disk-waiter ==="

# 0. 提前创建配置清单目录并锁死 700 权限
MANIFEST_DIR="/etc/zpool-disk-waiter"
echo "[0/4] 创建受保护的配置目录 / Creating hardened config directory ..."
secure_deploy 700 -d "$MANIFEST_DIR"

# 1. 拷贝可执行脚本并赋予 700 权限 (仅 root 可执行)
echo "[1/4] 安装核心脚本 / Installing core scripts to /usr/local/bin/ ..."
secure_deploy 700 bin/zpool-disk-waiter.sh /usr/local/bin/zpool-disk-waiter.sh
secure_deploy 700 bin/zpool-waiter-generator.py /usr/local/bin/zpool-waiter-generator.py

# 2. 部署 Systemd 补充配置补丁 (收缩至 644 权限，消除 API 警告)
echo "[2/4] 部署 Systemd 补充补丁 / Deploying Systemd drop-in patch ..."
SYSTEMD_DIR="/etc/systemd/system/zfs-import-cache.service.d"
secure_deploy 755 -d "$SYSTEMD_DIR"
secure_deploy 644 systemd/override.conf "$SYSTEMD_DIR/override.conf"

# 3. 部署 ZED 钩子与事件绑定
echo "[3/4] 部署 ZED 异步触发钩子 / Deploying ZED asynchronous hooks ..."
ZED_DIR="/etc/zfs/zed.d"
if [ -d "$ZED_DIR" ]; then
    secure_deploy 700 zed.d/update-zpool-waiter.sh "$ZED_DIR/update-zpool-waiter.sh"

    # 进入目录创建监听事件的软链接
    cd "$ZED_DIR" || exit
    events=("pool_import" "pool_create" "resilver_start" "vdev_add" "vdev_remove" "vdev_attach" "vdev_detach")
    
    for event in "${events[@]}"; do
        link_name="${event}-update-zpool-waiter.sh"
        
        # 1. 幂等检查：如果软链接已经正确指向目标，直接跳过 / If link is already correct, skip
        [ "$(readlink "$link_name" 2>/dev/null)" == "update-zpool-waiter.sh" ] && continue
        
        # 2. 防御性拦截：若存在同名文件或异质链接，拒绝静默覆写 / If file exists, abort to prevent silent override
        if [ -e "$link_name" ] || [ -L "$link_name" ]; then
            echo "[ERROR] 冲突：$link_name 已存在，拒绝安装！ / Conflict: $link_name exists, aborting."
            exit 1
        fi
        
        ln -s update-zpool-waiter.sh "$link_name"
    done
else
    echo "[WARN] 未找到目录 / Directory not found: $ZED_DIR. 跳过 ZED 更新 / Skipping ZED auto-update."
fi

# 4. 重载服务与初次编译
echo "[4/4] 重载 Systemd 并激活 ZED / Reloading Systemd and activating ZED service ..."
systemctl daemon-reload

# 确保 ZED 服务开机自启并立刻运行
systemctl enable --now zfs-zed.service
systemctl restart zfs-zed.service

echo "初始化：首次编译静态清单 / Initializing: Generating static manifest..."
/usr/local/bin/zpool-waiter-generator.py

echo "=========================================================="
echo "✅ 安装并激活成功 / Installation and activation successful!"
echo " "
echo "💡 提示 / NOTE: 如需为特定池配置自定义等待时间 / To configure custom timeout for a specific pool,"
echo "请创建 / Create /etc/zpool-disk-waiter/[POOL_NAME].conf:"
echo "MAX_RETRIES=12"
echo "CHECK_INTERVAL=5"
echo "=========================================================="
