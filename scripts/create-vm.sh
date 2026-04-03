#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

# ReactOS ISO — update version as needed
REACTOS_VERSION="0.4.15"
REACTOS_ISO_URL="https://sourceforge.net/projects/reactos/files/ReactOS/${REACTOS_VERSION}/ReactOS-${REACTOS_VERSION}-release-1-gdbb43bbaeb2-x86-iso.zip/download"
ISO_DIR="$REPO_DIR/.cache"
ISO_ZIP="$ISO_DIR/ReactOS-${REACTOS_VERSION}-iso.zip"
ISO_FILE="$ISO_DIR/ReactOS-${REACTOS_VERSION}.iso"

# ─── Download ReactOS ISO ────────────────────────────────────────────

mkdir -p "$ISO_DIR"

if [ -f "$ISO_FILE" ]; then
    info "ReactOS ISO already cached at $ISO_FILE"
else
    info "Downloading ReactOS ${REACTOS_VERSION}..."
    info "(SourceForge can be slow — if this stalls, download manually from https://reactos.org/download/)"

    curl -L --max-time 300 -o "$ISO_ZIP" "$REACTOS_ISO_URL" || \
        error "Download failed. Try manually: curl -L -o $ISO_ZIP '$REACTOS_ISO_URL'"

    info "Extracting ISO..."
    unzip -o "$ISO_ZIP" -d "$ISO_DIR"

    # Find the extracted ISO (filename may vary slightly)
    ISO_FOUND=$(find "$ISO_DIR" -maxdepth 1 -name "*.iso" -print -quit)
    if [ -z "$ISO_FOUND" ]; then
        error "No .iso file found after extraction in $ISO_DIR"
    fi

    if [ "$ISO_FOUND" != "$ISO_FILE" ]; then
        mv "$ISO_FOUND" "$ISO_FILE"
    fi

    rm -f "$ISO_ZIP"
    info "ReactOS ISO ready: $ISO_FILE ($(du -h "$ISO_FILE" | cut -f1))"
fi

# ─── Create namespace ────────────────────────────────────────────────

info "Creating namespace..."
kubectl apply -f "$REPO_DIR/manifests/reactos/namespace.yaml"

# ─── Upload ISO via CDI ──────────────────────────────────────────────

if kubectl get dv reactos-iso -n reactos &>/dev/null 2>&1; then
    info "ISO DataVolume already exists."
else
    info "Uploading ReactOS ISO to cluster via CDI..."

    # Wait for CDI upload proxy
    kubectl wait --for=condition=Available deployment/cdi-uploadproxy \
        -n cdi --timeout=120s

    # --force-bind is required because local-path uses WaitForFirstConsumer
    # binding mode, which keeps the PVC pending until a pod claims it.
    # --uploadproxy-url is required because virtctl cannot auto-discover
    # the CDI upload proxy on k3s (ClusterIP-only service).
    UPLOADPROXY_URL="https://$(kubectl get svc cdi-uploadproxy -n cdi -o jsonpath='{.spec.clusterIP}'):443"

    virtctl image-upload dv reactos-iso \
        --namespace=reactos \
        --size=1Gi \
        --image-path="$ISO_FILE" \
        --storage-class=local-path \
        --access-mode=ReadWriteOnce \
        --uploadproxy-url="$UPLOADPROXY_URL" \
        --insecure \
        --force-bind

    info "ISO uploaded successfully."
fi

# ─── Create boot disk ───────────────────────────────────────────────

if kubectl get dv reactos-boot-disk -n reactos &>/dev/null 2>&1; then
    info "Boot disk DataVolume already exists."
else
    info "Creating boot disk DataVolume..."
    kubectl apply -f "$REPO_DIR/manifests/reactos/datavolume-disk.yaml"
fi

# Boot disk may stay in WaitForFirstConsumer until the VM pod binds it — that's normal
info "Boot disk created (may show WaitForFirstConsumer until VM starts — this is expected)."

# ─── Deploy IDE sidecar hook ────────────────────────────────────────

info "Deploying IDE sidecar hook..."
kubectl apply -f "$REPO_DIR/manifests/reactos/ide-hook-configmap.yaml"

# ─── Create the VM ───────────────────────────────────────────────────

info "Creating ReactOS VirtualMachine..."
kubectl apply -f "$REPO_DIR/manifests/reactos/vm.yaml"

info "Waiting for VM to start..."
for i in $(seq 1 30); do
    PHASE=$(kubectl get vmi reactos -n reactos -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$PHASE" = "Running" ]; then
        break
    fi
    echo "  VM phase: $PHASE ($i/30)"
    sleep 5
done

echo ""
info "========================================="
info " ReactOS VM created!"
info "========================================="
echo ""
echo "  VM status:"
kubectl get vm,vmi -n reactos 2>/dev/null || true
echo ""
echo "  Connect via VNC to install ReactOS:"
echo "    ./scripts/vnc.sh"
echo ""
echo "  After installation completes and ReactOS reboots:"
echo "    ./scripts/post-install.sh"
echo ""
