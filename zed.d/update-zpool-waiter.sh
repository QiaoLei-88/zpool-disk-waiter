#!/bin/bash
# ZED Hook: 异步触发 ZFS 静态清单更新

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG_FILE="/var/log/zpool-waiter-generator.log"

# 扔到后台异步执行，防止阻塞 ZFS 内核事件汇报
/usr/local/bin/zpool-waiter-generator.py >> "$LOG_FILE" 2>&1 &

exit 0
