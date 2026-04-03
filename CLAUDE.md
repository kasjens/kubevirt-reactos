# kubevirt-reactos

Local KubeVirt lab running ReactOS VMs on k3s (Ubuntu host). Hobby project.

## Commands

- `./scripts/setup.sh` — install k3s, KubeVirt, CDI, virtctl, virt-viewer, patch StorageProfile
- `./scripts/create-vm.sh` — download ReactOS 0.4.15 ISO, upload via CDI, deploy IDE hook, launch VM
- `./scripts/teardown.sh` — remove everything (prompts for confirmation)
- `virtctl vnc reactos -n reactos` — graphical console
- `virtctl console reactos -n reactos` — serial console (shows `kdb:>` debugger if ReactOS crashes)
- `kubectl get vm,vmi -n reactos` — VM status

## Architecture

```
scripts/       — bash setup/teardown automation (idempotent, re-runnable)
manifests/
  kubevirt/    — KubeVirt CR (with emulatedMachines + Sidecar gate), CDI CR, StorageProfile patch
  reactos/     — namespace, DataVolumes, VirtualMachine manifest, IDE hook sidecar ConfigMap
docs/          — reference docs (ReactOS compatibility, troubleshooting)
```

## Critical Constraints — ReactOS Has No VirtIO Support

Every KubeVirt default must be overridden for ReactOS. This is the #1 gotcha:

| Component | Must use | KubeVirt default (broken) |
|-----------|----------|--------------------------|
| Machine   | `pc-i440fx-rhel7.6.0` | q35 (ReactOS kernel panics on PCIe/ICH9) |
| Disk bus  | `ide` (via sidecar hook) | virtio (IDE blocked in admission since v1.8) |
| NIC       | `e1000` | virtio-net |
| Boot      | BIOS (SeaBIOS) | UEFI possible |
| Balloon   | disabled | enabled |

Do NOT attempt VirtIO drivers — `viostor` makes ReactOS unbootable, `virtio-net` crashes, QXL BSODs.

## KubeVirt v1.8+ IDE Workaround

KubeVirt v1.8+ hard-blocks `bus: ide` in the admission webhook and defaults to q35-only machine types. Two workarounds are required:

1. **emulatedMachines** — The KubeVirt CR (`kubevirt-cr.yaml`) adds `pc-i440fx*` to the allowed machine types list.
2. **Sidecar hook** — A ConfigMap (`ide-hook-configmap.yaml`) contains a Python script that rewrites `bus='scsi'` to `bus='ide'` in the libvirt domain XML after admission. The VM manifest uses `bus: scsi` to pass validation, and the hook converts it to IDE before QEMU starts. The `Sidecar` feature gate must be enabled.

SATA/AHCI does NOT work — SeaBIOS in KubeVirt's QEMU cannot boot from the AHCI controller on i440fx.

## k3s + KubeVirt Gotchas

- StorageProfile for `local-path` must be patched or CDI DataVolumes fail silently. `setup.sh` handles this.
- Kernel modules `kvm`, `kvm_intel`/`kvm_amd`, `vhost_net`, `tun` must be loaded. Missing `vhost_net` causes scheduling failures.
- No live migration on `local-path` (RWO only). Acceptable for single-node local dev.
- Ubuntu AppArmor may block virt-handler QEMU probing — check `dmesg | grep apparmor` if VMs fail to start.
- CDI upload proxy URL must be provided explicitly (`--uploadproxy-url`) — auto-discovery fails on k3s.
- Machine type must match a node label (`machine-type.node.kubevirt.io/<type>=true`) or the VM stays in `Scheduling`. Use `kubectl get node -o json | jq '.metadata.labels'` to check available types.

## When Compacting

Preserve the ReactOS hardware constraints table, the IDE workaround section, and the k3s gotchas list — these are the most common sources of debugging time.
