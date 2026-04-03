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

# ─── Preflight: KVM ──────────────────────────────────────────────────

info "Checking KVM support..."

if [ ! -e /dev/kvm ]; then
    error "/dev/kvm not found. Enable hardware virtualization in BIOS and load kvm modules:
    sudo modprobe kvm
    sudo modprobe kvm_intel  # or kvm_amd"
fi

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    warn "/dev/kvm not accessible by current user. Fixing permissions..."
    sudo chmod 666 /dev/kvm
fi

# ─── Preflight: required tools ───────────────────────────────────────

for cmd in curl jq unzip; do
    command -v "$cmd" &>/dev/null || error "$cmd is required. Install with: sudo apt install $cmd"
done

info "Preflight checks passed."

# ─── Kernel modules (persist across reboots) ─────────────────────────

info "Ensuring KubeVirt kernel modules are loaded..."

MODULES=(kvm vhost_net tun br_netfilter)

# Detect Intel vs AMD for kvm_intel/kvm_amd
if grep -q vmx /proc/cpuinfo; then
    MODULES+=(kvm_intel)
elif grep -q svm /proc/cpuinfo; then
    MODULES+=(kvm_amd)
fi

for mod in "${MODULES[@]}"; do
    if ! lsmod | grep -q "^${mod}"; then
        info "Loading kernel module: $mod"
        sudo modprobe "$mod" || warn "Failed to load $mod (may not be available)"
    fi
done

# Persist for next boot
if [ ! -f /etc/modules-load.d/kubevirt.conf ]; then
    info "Persisting kernel modules to /etc/modules-load.d/kubevirt.conf"
    printf '%s\n' "${MODULES[@]}" | sudo tee /etc/modules-load.d/kubevirt.conf > /dev/null
fi

# ─── AppArmor check ──────────────────────────────────────────────────

if command -v aa-status &>/dev/null && sudo aa-status 2>/dev/null | grep -q "profiles are in enforce mode"; then
    warn "AppArmor is active. If VMs fail to start, check: dmesg | grep apparmor"
    warn "You may need to adjust AppArmor profiles for QEMU/libvirt."
fi

# ─── k3s ─────────────────────────────────────────────────────────────

if command -v k3s &>/dev/null; then
    info "k3s already installed, skipping."
else
    info "Installing k3s..."

    # Create k3s config directory
    sudo mkdir -p /etc/rancher/k3s

    # k3s config optimized for KubeVirt
    sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<'EOF'
write-kubeconfig-mode: "0644"
disable:
  - traefik
  - servicelb
EOF

    curl -sfL https://get.k3s.io | sh -

    info "Waiting for k3s node to be Ready..."
    until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
        sleep 2
    done
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Persist KUBECONFIG for the user's shell sessions
if ! grep -q 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml' ~/.bashrc 2>/dev/null; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
    info "Added KUBECONFIG to ~/.bashrc"
fi

info "k3s is ready."
kubectl get nodes

# ─── KubeVirt ────────────────────────────────────────────────────────

KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r '.tag_name')
info "Target KubeVirt version: $KUBEVIRT_VERSION"

if kubectl get namespace kubevirt &>/dev/null 2>&1; then
    info "KubeVirt namespace exists, checking installation..."
else
    info "Installing KubeVirt operator..."
    kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

    info "Waiting for KubeVirt operator..."
    kubectl wait --for=condition=Available deployment/virt-operator \
        -n kubevirt --timeout=180s
fi

info "Applying KubeVirt CR..."
kubectl apply -f "$REPO_DIR/manifests/kubevirt/kubevirt-cr.yaml"

info "Waiting for KubeVirt deployment (1-3 minutes)..."
kubectl wait --for=jsonpath='{.status.phase}'=Deployed kubevirt/kubevirt \
    -n kubevirt --timeout=300s

info "KubeVirt is ready."

# ─── CDI ─────────────────────────────────────────────────────────────

CDI_VERSION=$(curl -s https://api.github.com/repos/kubevirt/containerized-data-importer/releases/latest | jq -r '.tag_name')
info "Target CDI version: $CDI_VERSION"

if kubectl get namespace cdi &>/dev/null 2>&1; then
    info "CDI namespace exists, checking installation..."
else
    info "Installing CDI operator..."
    kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"

    info "Waiting for CDI operator..."
    kubectl wait --for=condition=Available deployment/cdi-operator \
        -n cdi --timeout=180s
fi

info "Applying CDI CR..."
kubectl apply -f "$REPO_DIR/manifests/kubevirt/cdi-cr.yaml"

info "Waiting for CDI deployment..."
kubectl wait --for=jsonpath='{.status.phase}'=Deployed cdi/cdi \
    -n cdi --timeout=300s

info "CDI is ready."

# ─── StorageProfile patch (critical for local-path + CDI) ────────────

info "Patching StorageProfile for local-path provisioner..."
bash "$REPO_DIR/manifests/kubevirt/storageprofile-patch.sh"

# ─── virtctl ─────────────────────────────────────────────────────────

if command -v virtctl &>/dev/null; then
    info "virtctl already installed."
else
    info "Installing virtctl..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  VIRTCTL_ARCH="linux-amd64" ;;
        aarch64) VIRTCTL_ARCH="linux-arm64" ;;
        *)       error "Unsupported architecture: $ARCH" ;;
    esac

    curl -Lo /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-${VIRTCTL_ARCH}"
    chmod +x /tmp/virtctl
    sudo mv /tmp/virtctl /usr/local/bin/virtctl
fi

# ─── VNC viewer (tigervnc for proper cursor positioning) ─────────────

if command -v vncviewer &>/dev/null; then
    info "VNC viewer already installed."
else
    info "Installing tigervnc-viewer (needed for VNC console with correct cursor)..."
    sudo apt install -y tigervnc-viewer
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
info "========================================="
info " Setup complete!"
info "========================================="
echo ""
echo "  k3s:      $(k3s --version 2>/dev/null | head -1)"
echo "  KubeVirt: $(kubectl get kubevirt kubevirt -n kubevirt -o jsonpath='{.status.observedKubeVirtVersion}' 2>/dev/null || echo 'deploying...')"
echo "  CDI:      $(kubectl get cdi cdi -n cdi -o jsonpath='{.status.observedVersion}' 2>/dev/null || echo 'deploying...')"
echo "  virtctl:  $(virtctl version --client 2>/dev/null | head -1 || echo 'installed')"
echo ""
echo "  Next step: ./scripts/create-vm.sh"
echo ""
