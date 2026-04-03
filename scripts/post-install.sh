#!/usr/bin/env bash
# Remove the installation ISO from the VM and switch to disk-only boot.
# Run this after ReactOS installation is complete.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

info "Removing install ISO from ReactOS VM..."

# Patch the VM: remove the install-iso disk and volume
kubectl patch vm reactos -n reactos --type=json -p '[
  {"op": "remove", "path": "/spec/template/spec/volumes/1"},
  {"op": "remove", "path": "/spec/template/spec/domain/devices/disks/1"}
]'

info "Restarting VM to apply changes..."
virtctl restart reactos -n reactos 2>/dev/null || \
    (kubectl delete vmi reactos -n reactos 2>/dev/null; sleep 2)

# Wait for VM to come back
info "Waiting for VM to start..."
for i in $(seq 1 30); do
    PHASE=$(kubectl get vmi reactos -n reactos -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$PHASE" = "Running" ]; then
        break
    fi
    echo "  VM phase: $PHASE ($i/30)"
    sleep 5
done

# Optionally delete the ISO DataVolume to free disk space
echo ""
read -rp "Delete the ISO DataVolume to free disk space? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    kubectl delete dv reactos-iso -n reactos 2>/dev/null || \
        kubectl delete pvc reactos-iso -n reactos 2>/dev/null || true
    info "ISO DataVolume deleted."
fi

echo ""
info "========================================="
info " Post-install complete!"
info "========================================="
echo ""
echo "  ReactOS now boots from disk only."
echo "  Connect: ./scripts/vnc.sh"
echo ""
