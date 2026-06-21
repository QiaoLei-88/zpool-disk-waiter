#!/bin/bash

MANIFEST_DIR="/etc/zpool-disk-waiter"
# 取消了 CACHE_FILE 变量，不再由脚本接管具体的导入动作

# 全局默认安全底线 (适用于大多数 24+ HDD 的错位起转场景)
GLOBAL_MAX_RETRIES=60       # 默认 60 次
GLOBAL_CHECK_INTERVAL=5     # 每次 5 秒，总计最多等待 5 分钟

# 首位声明 DRYRUN 模式前缀
DRY_CMD=""
[ "$1" == "--dry-run" ] && DRY_CMD="echo [DRY-RUN] "

echo "=== 启动确定性拓扑核对 / Starting deterministic topology check ==="

if [ ! -d "$MANIFEST_DIR" ]; then
    echo "[NOTE] 未发现清单目录 / Manifest dir not found: $MANIFEST_DIR. 直接放行 / Bypass."
    exit 0
fi

for list_file in "${MANIFEST_DIR}"/*.list; do
    [ -e "$list_file" ] || continue
    pool_name=$(basename "$list_file" .list)
    
    # 检查存储池是否已在线
    if /sbin/zpool list "$pool_name" >/dev/null 2>&1; then
        echo "[NOTE] [$pool_name] 已激活 / Already active, 跳过 / Skip."
        ${DRY_CMD}continue
    fi

    expected_disks=($(cat "$list_file"))
    total_expected=${#expected_disks[@]}
    [ "$total_expected" -eq 0 ] && continue

    # 单 Pool 个性化参数覆盖逻辑
    MAX_RETRIES=$GLOBAL_MAX_RETRIES
    CHECK_INTERVAL=$GLOBAL_CHECK_INTERVAL
    conf_file="${MANIFEST_DIR}/${pool_name}.conf"
    
    if [ -f "$conf_file" ]; then
        source "$conf_file"
        echo "[INFO] [$pool_name] 加载自定义策略 / Custom policy loaded (Interval: ${CHECK_INTERVAL}s, Max: ${MAX_RETRIES})."
    fi

    echo "--------------------------------------------------"
    echo "[INFO] [$pool_name]: 预期设备 / Expected disks: $total_expected. 启动轮询 / Polling..."

    retry_count=0
    
    while true; do
        ready_count=0
        missing_disks=()

        for disk in "${expected_disks[@]}"; do
            if [ -e "$disk" ]; then
                ((ready_count++))
            else
                missing_disks+=("$disk")
            fi
        done

        if [ "$ready_count" -eq "$total_expected" ]; then
            echo "[SUCCESS] [$pool_name]: 硬盘点名完成，全员到齐！ / All disks accounted for. Boarding completed!"
            echo "[ACTION] 释放时序屏障，交由 ZFS 原生逻辑执行导入 / Passing control to native ZFS engine..."
            break
        fi

        if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
            echo "=================================================="
            echo "[TIMEOUT] ⚠️ [$pool_name]: 登机时间截止，存在缺席硬盘。 / Boarding timeout. Missing passengers reported!"
            echo "[WARN] 敲定最终名单，交由 ZFS 原生逻辑进行最终裁决 / Delegating to ZFS native logic for adjudication:"
            for missing in "${missing_disks[@]}"; do
                echo "  -> 缺席 / MISSING: $missing"
            done
            echo "=================================================="
            break
        fi

        echo "[$pool_name] 检录进度 / BOARDING STATUS: 已到 $ready_count / 应到 $total_expected (等待轮次 / HOLDING CYCLE: $retry_count/$MAX_RETRIES)"
        sleep "$CHECK_INTERVAL"
        ((retry_count++))
    done
done

# 无论拓扑是否齐备，脚本使命均已完成。必须返回 0 以放行后续的官方原生导入指令
exit 0
