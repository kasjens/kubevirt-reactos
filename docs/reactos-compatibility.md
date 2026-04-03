# ReactOS Hardware Compatibility on KubeVirt/QEMU/KVM

Reference document for running ReactOS as a KubeVirt guest VM.
Last verified: April 2026, ReactOS 0.4.15, KubeVirt v1.8.1 on k3s v1.34.6.

## Hardware Compatibility Matrix

| Component | Working | Broken | Notes |
|-----------|---------|--------|-------|
| **Machine type** | `i440fx` (`pc-i440fx-rhel7.6.0`) | `q35` | q35 causes ReactOS kernel panic on PCIe/ICH9/ACPI. QEMU in KubeVirt uses RHEL-versioned machine names. |
| **Disk bus** | `ide` (via sidecar hook) | `virtio`, `sata`/AHCI | viostor makes ReactOS unbootable (CORE-12695). SATA/AHCI: SeaBIOS in KubeVirt's QEMU cannot boot from it on i440fx. |
| **NIC** | `e1000` (recommended), `rtl8139`, `ne2k_pci`, `pcnet` | `virtio-net`, `e1000e` | e1000 = Gigabit + built-in driver. rtl8139 = 100 Mbps. virtio-net crashes (CORE-4615). |
| **Display** | Standard VGA (`-vga std`) | QXL, virtio-gpu | QXL causes BSOD on every boot (CORE-9779). |
| **Boot mode** | BIOS (SeaBIOS) | UEFI/OVMF | UEFI boot is in development (FreeLoader UEFI port) but experimental. |
| **Memory balloon** | N/A (disable) | balloon driver | Not implemented in ReactOS. |
| **Audio** | AC97, Intel HDA | — | Not critical for most use cases. |
| **USB** | UHCI, OHCI | xHCI | Limited USB support. |

## ReactOS Version Guidance

| Version | Status | QEMU/KVM Notes |
|---------|--------|----------------|
| **0.4.15** (Mar 2025) | Stable release, recommended | TLS/crypto fixes — RAPPS (Applications Manager) HTTPS downloads work. |
| 0.4.14 (Dec 2021) | Previous stable | Works on QEMU 4.2+. RAPPS broken — TLS stack can't handle modern HTTPS (CORE-16741). |
| < 0.4.14-RC | Old releases | Fail to boot on QEMU 4.2+ (Launchpad Bug #1859106). |

## IDE Device Limit

i440fx provides two IDE channels (primary + secondary), each with master/slave — **4 IDE devices maximum**:

- Primary master: boot disk
- Primary slave: (available)
- Secondary master: CD-ROM (install ISO)
- Secondary slave: (available)

After ReactOS installation, remove the CD-ROM volume to free a slot.

## KubeVirt-Specific Configuration

### KubeVirt v1.8+ Breaking Changes

KubeVirt v1.8+ introduced two changes that break ReactOS compatibility:

1. **IDE bus hard-blocked** — The admission webhook rejects `bus: ide` with no configuration override. The only workaround is a **sidecar hook** that modifies the libvirt domain XML after admission, rewriting `bus='scsi'` to `bus='ide'`. The `Sidecar` feature gate must be enabled.

2. **i440fx not in default allowed list** — The default `emulatedMachines` only allows `q35*` and `pc-q35*`. Add `pc-i440fx*` to the KubeVirt CR:

```yaml
spec:
  configuration:
    emulatedMachines:
      - "q35*"
      - "pc-q35*"
      - "pc-i440fx*"
      - "pc*"
    developerConfiguration:
      featureGates:
        - Sidecar          # Required for IDE hook
```

### What We Tried That Doesn't Work

- **SATA bus** (`bus: sata`): Creates an AHCI controller on i440fx. SeaBIOS in KubeVirt's QEMU cannot boot from it — boot sector at 0x7c00 stays all zeros.
- **SCSI bus** (`bus: scsi`): Maps to `virtio-scsi-pci-non-transitional`. SeaBIOS cannot boot from non-transitional virtio devices.
- **q35 machine type**: ReactOS kernel panics during boot (hits `kdb:>` debugger with bug checks in `ntoskrnl/ke/bug.c`).

### Overrides from KubeVirt Defaults

Every default must be explicitly overridden. The VM manifest uses `bus: scsi` to pass admission — the sidecar hook rewrites it to IDE:

```yaml
domain:
  machine:
    type: pc-i440fx-rhel7.6.0   # Default: q35 (must add to emulatedMachines)
  firmware:
    bootloader:
      bios: {}                   # Default: can vary
  devices:
    disks:
    - disk:
        bus: scsi                # Passes admission; hook rewrites to ide
    interfaces:
    - model: e1000               # Default: virtio-net
      masquerade: {}
    autoattachMemBalloon: false   # Default: true
```

The VM template must include the hook annotation:

```yaml
template:
  metadata:
    annotations:
      hooks.kubevirt.io/hookSidecars: >
        [{"args":["--version","v1alpha2"],
          "configMap":{"name":"ide-bus-hook","key":"hook.sh",
                       "hookPath":"/usr/bin/onDefineDomain"}}]
```

### Clock Configuration

ReactOS expects localtime (like Windows). Configure RTC accordingly:

```yaml
clock:
  utc: {}
  timer:
    rtc:
      tickPolicy: catchup
    pit:
      tickPolicy: delay
    hpet:
      present: false
```

### No Hyper-V Enlightenments

Unlike Windows Server, ReactOS does not implement any Hyper-V paravirtual interfaces. Do NOT add `features.hyperv` to the VM spec — it will have no effect or cause instability.

## VirtIO Driver Status in ReactOS

Tracked under JIRA CORE-14064 (umbrella issue for VirtIO support).

| Driver | JIRA | Status |
|--------|------|--------|
| viostor (block) | CORE-12695 | Broken — makes ReactOS unbootable |
| virtio-net (network) | CORE-4615 | Broken — driver fails to load |
| QXL (display) | CORE-9779 | Broken — BSOD on boot |
| vioinput (input) | — | Not attempted |
| vioser (serial) | — | Not attempted |
| balloon | — | Not implemented |

**Do not install Windows VirtIO drivers** (`virtio-win-*.iso`) in ReactOS. They are built for Windows NT kernel internals that ReactOS has not yet replicated.

## Performance Expectations

All I/O goes through emulated devices (IDE, e1000) rather than paravirtualized VirtIO. Expect:

- **Disk I/O:** ~50–100 MB/s sequential (vs. ~1+ GB/s with VirtIO)
- **Network:** Gigabit theoretical with e1000 (adequate for local dev)
- **CPU:** Near-native with KVM hardware acceleration
- **Display:** VGA resolution, adequate for desktop use via VNC

This is acceptable for a hobby/lab environment but not suitable for any production workload.

### Machine Type Node Labels

KubeVirt requires a matching node label for the requested machine type. If the VM gets stuck in `Scheduling` with a node affinity error, check available types:

```bash
kubectl get node -o json | jq -r '.metadata.labels | to_entries[] | select(.key | contains("machine-type")) | .key'
```

Use a machine type that has a corresponding label (e.g., `pc-i440fx-rhel7.6.0` not `pc-i440fx-2.12`).

### CDI Upload Proxy on k3s

`virtctl image-upload` cannot auto-discover the CDI upload proxy URL on k3s. Provide it explicitly:

```bash
UPLOADPROXY_URL="https://$(kubectl get svc cdi-uploadproxy -n cdi -o jsonpath='{.spec.clusterIP}'):443"
virtctl image-upload ... --uploadproxy-url="$UPLOADPROXY_URL" --insecure
```

## Useful QEMU Flags (for reference)

When running ReactOS directly under QEMU (outside KubeVirt), these flags are known-good:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -machine pc-i440fx-2.12 \
  -cpu host \
  -m 1024 \
  -vga std \
  -rtc base=localtime \
  -net nic,model=e1000 -net user \
  -drive file=reactos.qcow2,format=qcow2,if=ide \
  -cdrom ReactOS-0.4.14.iso \
  -boot d \
  -serial file:reactos-debug.log
```

## References

- [ReactOS QEMU Wiki](https://reactos.org/wiki/index.php/QEMU)
- [ReactOS JIRA — VirtIO umbrella](https://jira.reactos.org/browse/CORE-14064)
- [QEMU Bug #1859106 — SeaBIOS regression](https://bugs.launchpad.net/qemu/+bug/1859106)
- [KubeVirt Virtual Hardware docs](https://kubevirt.io/user-guide/compute/virtual_hardware/)
- [KubeVirt Issue #10786 — StorageProfile + local-path](https://github.com/kubevirt/kubevirt/issues/10786)
- [hectorm/docker-qemu-reactos](https://github.com/hectorm/docker-qemu-reactos) — Docker-based ReactOS reference
- [uroesch/packer-reactos](https://github.com/uroesch/packer-reactos) — Packer build for ReactOS QEMU images
