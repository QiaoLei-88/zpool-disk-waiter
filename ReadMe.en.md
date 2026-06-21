# zpool-disk-waiter

**The ultimate deterministic boot-time physical topology guardian for OpenZFS on Linux.**

## 🚨 Background & Pain Points

When managing ZFS storage pools with a massive number of physical disks in a Linux environment (such as high-density HDD arrays attached to SAS HBA expander backplanes), a classic race condition frequently occurs during the system boot phase:

The OS drive (NVMe/SSD) typically boots extremely fast, triggering the native `zfs-import-cache.service`. However, massive JBOD enclosures require a significantly longer time to execute a **Staggered Spin-up** to protect power supplies. If ZFS attempts to import the pool before the underlying physical disks are fully ready, it will result in an unexpected degraded array, mount failures, or even drop the entire system into Emergency Mode.

This phenomenon stems primarily from objective limitations in the evolution of modern system architectures:

* **Evolution of Boot Mechanisms:** Modern Linux distributions (e.g., Systemd) have deprecated the traditional `systemd-udev-settle` (which blocks until all hardware is ready), fully pivoting to an asynchronous, event-driven architecture.
* **Boundaries of Cross-Platform Architecture:** As a cross-platform file system, OpenZFS does not natively incorporate an OS-specific, long-term hardware polling/blocking logic at its lowest level.
* **Limitations of Existing Bridges:** The official attempt to bridge this via `zfs-mount-generator` (dynamically generating Systemd `.device` dependencies) introduces operational pain points: black-box logic and the inability to set independent timeout margins for different pools (e.g., fast NVMe vs. slow HDD).

**This project aims to bridge this engineering gap.** Embracing the architectural philosophy of "Separation of Concerns," we provide a lightweight, non-intrusive pre-boot timing barrier to supply the missing piece of the puzzle for ZFS boot-time disk detection.

## 💡 Architectural Philosophy: Separation of Concerns

`zpool-disk-waiter` abandons the dangerous "forceful takeover of ZFS import" pattern. Instead, it fully embraces the **UNIX philosophy and the Systemd ecosystem** through a holistic design:

1. **Ahead-Of-Time (AOT) Static Manifest:** During normal runtime, a Python script extracts the healthy physical topology of ZFS, preserving only the physical paths of strictly `ONLINE` devices, generating a static boarding manifest (`.list`).
2. **Minimalist Pre-boot Barrier:** At boot, a Bash script runs as an `ExecStartPre` interceptor. It strictly adheres to the **"Boarding Gate Agent"** logic: holding the manifest, standing at the door of `/dev/disk/by-id`, and taking a roll call. It checks *only* for physical presence and never oversteps to execute the import command. It drops the barrier the millisecond the topology aligns, or forcefully closes the gate if the timeout is reached.
3. **Delegated Adjudication:** **This is the core moat of the project.** Whether the roll call is perfectly complete or times out with missing disks, the script always exits gracefully with `exit 0`. It returns the ultimate authority for array fault tolerance, DEGRADED imports, and mounting back to the native ZFS core engine (the Captain / Dispatcher). It will *never* permanently lock down an array that could have safely booted in a degraded state due to a script misjudgment.
4. **State-Gating ZED (ZFS Event Daemon):** Integrates asynchronous topology tracking via ZED hooks. Background manifests are silently updated *only* when the pool is healthy or Resilvering. If an unexpected disk drop occurs, updates are suspended to prevent masking physical hardware failures.

## 🏗️ Core Components

* `/usr/local/bin/zpool-waiter-generator.py`: An intelligent manifest generator enforcing strict positive filtering (Whitelist).
* `/usr/local/bin/zpool-disk-waiter.sh`: The deterministic topology roll-caller and timing barrier script.
* `/etc/systemd/system/zfs-import-cache.service.d/override.conf`: The Systemd drop-in patch. It injects only the `ExecStartPre` sentinel, leaving the official native boot flow completely intact.
* `/etc/zfs/zed.d/` hooks: Enables seamless, self-healing synchronization between topology changes and the static manifest.

## 🚀 Installation & Deployment

This project has zero external dependencies, requiring only standard Bash, Python 3, and a working ZFS/Systemd environment.

```bash
git clone https://github.com/yourusername/zpool-disk-waiter.git
cd zpool-disk-waiter
sudo ./install.sh

```

> **🛡️ Installation Security:** The `install.sh` logic is highly restrained. It uses transparent, atomic deployment processes that do not pollute the admin environment. Permissions are tightly scoped to the minimum required level, and the installation can be cleanly rolled back at any time.

## ⚙️ Advanced Configuration

Out of the box, the project defaults to a generous **5-minute (60 loops * 5 seconds)** grace period for all storage pools (it releases instantly once disks align, causing zero performance overhead).

If you manage multiple pools—for example, a `fastpool` (NVMe array that initializes instantly) and a `tank` (HDD archive pool that takes ages to spin up)—you can configure independent timeout thresholds for each.

Create a configuration file at `/etc/zpool-disk-waiter/[pool_name].conf`:

```bash
# Example: /etc/zpool-disk-waiter/fastpool.conf
# Configure a more aggressive timeout/melt-down strategy for the NVMe pool
MAX_RETRIES=12        # Max 12 polling attempts
CHECK_INTERVAL=5      # 5 seconds per interval

```

Changes take effect immediately. The pre-boot script will automatically detect and apply these isolated policies.

*(Note: For upstream business services like Nginx or KVM virtual machines, it is highly recommended to pair this with Systemd's native `RequiresMountsFor=/mount_point` mechanism. This ensures a perfect start/stop lifecycle loop perfectly tied to the underlying storage.)*

## ⚠️ Disclaimer

**This software is provided "AS IS", without warranty of any kind.**

All scripts provided in this project strictly perform read-only topology checks and timing blocks. By design, they do not contain any instructions that interfere with data streams or alter ZFS states.

However, interacting with system boot chains and low-level storage controllers carries inherent environmental risks. By using this software, you agree to assume full responsibility for your system's stability and data integrity. The author is not liable for any data loss, system downtime, or hardware damage arising from the use or inability to use this software. **Always validate in a non-production staging environment first.**

*Note: In the event of semantic discrepancies between translated versions of this documentation or license, the original Chinese (zh-CN) version shall prevail.*

## 📜 License

This project is open-sourced under the **GNU General Public License v2.0 (GPLv2)** - see the LICENSE file for details.