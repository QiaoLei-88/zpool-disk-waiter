#!/usr/bin/env python3
import subprocess
import os
import sys

MANIFEST_DIR = "/etc/zpool-disk-waiter"

def generate_manifests():
    os.makedirs(MANIFEST_DIR, exist_ok=True)
    
    try:
        pools_output = subprocess.check_output(["/sbin/zpool", "list", "-H", "-o", "name"], text=True)
        pools = [line.strip() for line in pools_output.strip().split("\n") if line.strip()]
    except Exception as e:
        print(f"[NOTE] 获取 zpool 列表失败 / Failed to list zpools ({e})")
        return

    if not pools:
        print("[NOTE] 当前没有正在运行的 ZFS 存储池 / No active ZFS pools found.")
        return

    for pool in pools:
        try:
            # 获取健康状态
            health = subprocess.check_output(["/sbin/zpool", "list", "-H", "-o", "health", pool], text=True).strip()
            status_output = subprocess.check_output(["/sbin/zpool", "status", "-P", pool], text=True)
            
            # 判断是否正在进行数据重构 (无论手动替换还是热备自动顶替)
            is_resilvering = "resilver in progress" in status_output or "resilvering" in status_output
            
            # 【双重保险】如果阵列降级/故障，且没有新的目标盘在重构，拒绝更新清单！
            if health not in ["ONLINE", "AVAIL"] and not is_resilvering:
                print(f"[BLOCKED] ⚠️ [{pool}] 当前处于 {health} 状态且未在重构 / Pool is {health} without resilvering!")
                print(f"   已拒绝刷新静态清单以防故障被静默掩盖 / Manifest update aborted to prevent masking disk failures.")
                continue # 跳过该 pool，保留原有的满盘清单
            
            disks = []
            for line in status_output.split("\n"):
                line = line.strip()
                if line.startswith("/dev/"):
                    parts = line.split()
                    disk_path = parts[0]
                    state = parts[1] if len(parts) > 1 else ""
                    
                    # 正向过滤：只包含明确处于 ONLINE 状态的物理设备
                    if state.startswith("ONLINE"):
                        disks.append(disk_path)
            
            disks = sorted(list(set(disks)))
            
            if disks:
                manifest_path = os.path.join(MANIFEST_DIR, f"{pool}.list")
                with open(manifest_path, "w") as f:
                    for disk in disks:
                        f.write(f"{disk}\n")
                
                # 写入后立刻强制收缩文件权限至 600 (仅 root 可读写)
                os.chmod(manifest_path, 0o600)
                
                print(f"[SUCCESS] 已为 [{pool}] 更新静态清单 / Static manifest updated -> {manifest_path} ({len(disks)} disks)")
            
        except Exception as e:
            print(f"[ERROR] 处理存储池 [{pool}] 时失败 / Failed to process pool [{pool}]: {e}")

if __name__ == "__main__":
    generate_manifests()
