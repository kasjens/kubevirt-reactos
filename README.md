# KubeVirt + ReactOS on k3s

Run ReactOS virtual machines on Kubernetes locally using k3s and KubeVirt.

A hobby project for exploring KubeVirt with a lightweight, open-source Windows-compatible OS — no Windows licenses required.

## Prerequisites

- Ubuntu 22.04+ (bare metal or VM with nested virtualization enabled)
- Hardware virtualization support (Intel VT-x / AMD-V)
- `curl`, `jq`, `unzip` installed
- At least 4 GiB free RAM and 20 GiB free disk space

### Verify KVM support

```bash
# Should return > 0
egrep -c '(vmx|svm)' /proc/cpuinfo

# Should exist
ls -la /dev/kvm

# If missing:
sudo modprobe kvm
sudo modprobe kvm_intel  # or kvm_amd
```

## Quick Start

```bash
git clone https://github.com/<you>/kubevirt-reactos.git
cd kubevirt-reactos

# 1. Install k3s, KubeVirt, CDI, virtctl (includes StorageProfile patch)
./scripts/setup.sh

# 2. Download ReactOS ISO and create the VM
./scripts/create-vm.sh

# 3. Connect via VNC (opens a graphical console)
./scripts/vnc.sh

# 4. Install ReactOS through the graphical installer

# 5. After installation, remove the ISO and switch to disk-only boot
./scripts/post-install.sh

# When done:
./scripts/teardown.sh
```

## Architecture

```
┌──────────────────────────────────────────┐
│           Ubuntu Host                    │
│  /dev/kvm (direct access, no nesting)    │
│  ┌────────────────────────────────────┐  │
│  │            k3s                      │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │       KubeVirt                │  │  │
│  │  │  ┌────────────────────────┐  │  │  │
│  │  │  │   ReactOS VM           │  │  │  │
│  │  │  │   QEMU/KVM             │  │  │  │
│  │  │  │   i440fx + IDE (hook)  │  │  │  │
│  │  │  │   + e1000 NIC          │  │  │  │
│  │  │  └────────────────────────┘  │  │  │
│  │  │  IDE sidecar hook rewrites   │  │  │
│  │  │  scsi→ide in libvirt XML     │  │  │
│  │  └──────────────────────────────┘  │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

## Repository Structure

```
kubevirt-reactos/
├── CLAUDE.md                       # Claude Code project context
├── README.md
├── scripts/
│   ├── setup.sh                    # k3s + KubeVirt + CDI + virtctl + virt-viewer + StorageProfile
│   ├── create-vm.sh                # Download ReactOS ISO, upload via CDI, deploy hook, launch VM
│   ├── post-install.sh             # Remove ISO, switch to disk-only boot after installation
│   ├── teardown.sh                 # Remove everything cleanly
│   └── vnc.sh                      # VNC console (proxy + tigervnc for correct cursor)
├── manifests/
│   ├── kubevirt/
│   │   ├── kubevirt-cr.yaml        # KubeVirt CR (i440fx enabled, Sidecar feature gate)
│   │   ├── cdi-cr.yaml             # CDI custom resource with resource overrides
│   │   └── storageprofile-patch.sh # Patch local-path StorageProfile for CDI
│   └── reactos/
│       ├── namespace.yaml          # reactos namespace
│       ├── datavolume-disk.yaml    # Blank boot disk (4 GiB)
│       ├── ide-hook-configmap.yaml # Sidecar hook: rewrites scsi→ide in libvirt XML
│       └── vm.yaml                 # VirtualMachine manifest (i440fx/IDE/e1000)
├── docs/
│   └── reactos-compatibility.md    # ReactOS hardware compat reference
└── .gitignore
```

## ReactOS on KubeVirt — Why Legacy Hardware Only

ReactOS is a clean-room reimplementation of the Windows NT architecture. It is **not Windows** and **cannot use Windows VirtIO drivers**. Every VirtIO component is broken:

| Component | What works | What doesn't |
|-----------|-----------|--------------|
| Disk | **IDE** (via sidecar hook) | VirtIO (`viostor` unbootable), SATA/AHCI (SeaBIOS can't boot) |
| Network | **e1000** (Gigabit, built-in driver) | `virtio-net` (crashes), `e1000e` (no driver) |
| Display | **Standard VGA** | QXL (BSOD on every boot) |
| Machine | **i440fx** (`pc-i440fx-rhel7.6.0`) | q35 (ReactOS kernel panics on PCIe/ICH9/ACPI) |
| Boot | **BIOS** (SeaBIOS) | UEFI (experimental, not stable) |

This means the VM manifest must override every KubeVirt default. The manifests in this repo handle all of this.

Performance is lower than a typical KubeVirt Windows VM because all I/O goes through emulated devices rather than paravirtualized ones. For a local dev environment this is fine.

### KubeVirt v1.8+ Compatibility

KubeVirt v1.8+ introduced two breaking changes for ReactOS:

1. **IDE bus blocked** — The admission webhook hard-rejects `bus: ide`. No configuration override exists. This repo works around it with a **sidecar hook** (`ide-hook-configmap.yaml`) that rewrites `bus='scsi'` to `bus='ide'` in the libvirt domain XML after admission. The `Sidecar` feature gate must be enabled in the KubeVirt CR.

2. **i440fx not in default allowed list** — The KubeVirt CR must include `pc-i440fx*` in `spec.configuration.emulatedMachines`. QEMU in KubeVirt uses RHEL-versioned machine names (`pc-i440fx-rhel7.6.0`), not upstream names like `pc-i440fx-2.12`.

Both are handled automatically by the manifests in this repo.

### Recommended ReactOS version

**ReactOS 0.4.15** (March 2025) — most recent stable release. Includes TLS/crypto fixes that make the Applications Manager work with HTTPS downloads. Versions before 0.4.14-RC fail to boot on QEMU 4.2+ due to a SeaBIOS regression.

## k3s Configuration Notes

The setup script configures k3s specifically for KubeVirt:

- **Disabled components:** Traefik and ServiceLB (frees resources, avoids port conflicts)
- **Kernel modules:** `kvm`, `kvm_intel`/`kvm_amd`, `vhost_net`, `tun` — persisted via `/etc/modules-load.d/kubevirt.conf`
- **StorageProfile patch:** CDI cannot auto-detect access modes from k3s's `local-path` provisioner. Without patching, DataVolumes fail silently. The setup script patches this automatically.
- **No live migration:** `local-path` only supports RWO. Acceptable for single-node local dev.

## Common Operations

```bash
# VM lifecycle
virtctl start reactos -n reactos
virtctl stop reactos -n reactos
virtctl restart reactos -n reactos

# Console access
./scripts/vnc.sh                      # graphical (proxy + tigervnc, best cursor)
virtctl vnc reactos -n reactos       # graphical (virt-viewer, may have cursor offset)
virtctl console reactos -n reactos   # serial / text

# Port forwarding (once ReactOS is installed and networking works)
virtctl port-forward vm/reactos 3389:3389 -n reactos   # RDP
virtctl port-forward vm/reactos 8080:80 -n reactos     # HTTP

# Debugging
kubectl get vm,vmi -n reactos
kubectl describe vmi reactos -n reactos
kubectl logs -n reactos -l kubevirt.io/vm=reactos -c compute
```

## Graduating to Talos

The ReactOS manifests are portable to any KubeVirt cluster. To move to Talos:

1. Add Talos machine config patch for KVM kernel modules
2. Deploy a real storage backend (Rook-Ceph or similar) for RWX block volumes
3. Add dedicated VM worker nodes with taints
4. Watch for Talos 1.9.x SELinux bug — use 1.8.x or 1.10+

See [docs/reactos-compatibility.md](docs/reactos-compatibility.md) for detailed hardware compatibility reference.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| VM stuck in `Scheduling` | Missing `vhost_net` module | `sudo modprobe vhost_net` |
| VM stuck in `Scheduling` with node affinity error | Machine type not available on node | Check `kubectl get node -o json \| jq '.metadata.labels'` for `machine-type.node.kubevirt.io/<type>=true` labels. Use a type that exists (e.g., `pc-i440fx-rhel7.6.0`). |
| DataVolume stuck in `WaitForFirstConsumer` | Normal for `local-path` | Use `--force-bind` with `virtctl image-upload` |
| DataVolume fails with no access mode | StorageProfile not patched | Run `./manifests/kubevirt/storageprofile-patch.sh` |
| `uploadproxy URL not found` | CDI upload proxy auto-discovery fails on k3s | Use `--uploadproxy-url` flag (handled by `create-vm.sh`) |
| VM boots to black screen (SATA/AHCI) | SeaBIOS can't boot from AHCI controller | Use IDE disk bus via sidecar hook, not SATA |
| VM boots to black screen (q35) | ReactOS kernel panics on q35 PCIe/ICH9/ACPI | Must use `i440fx` machine type |
| Serial console shows `kdb:>` | ReactOS kernel debugger triggered | Type `cont` to continue, or `bt` for backtrace to diagnose crash |
| ReactOS BSOD on boot | QXL display or VirtIO drivers | Ensure VGA display, IDE disk, e1000 NIC |
| `IDE bus is not supported` on VM creation | KubeVirt v1.8+ blocks IDE in admission | Use `bus: scsi` in manifest with IDE sidecar hook |
| `machine type is not supported: pc-i440fx-*` | i440fx not in emulatedMachines list | Add `pc-i440fx*` to KubeVirt CR `spec.configuration.emulatedMachines` |
| `Permission denied` in virt-handler logs | Ubuntu AppArmor blocking QEMU | Check `dmesg \| grep apparmor` |
| ISO download stalls | SourceForge throttling | Download manually from [reactos.org](https://reactos.org/download/) |

## License

MIT
