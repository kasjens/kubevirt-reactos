#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

echo ""
echo "This will remove:"
echo "  - ReactOS VM and all data volumes"
echo "  - KubeVirt and CDI"
echo "  - k3s"
echo "  - virtctl binary"
echo "  - Kernel module config (/etc/modules-load.d/kubevirt.conf)"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ─── Remove ReactOS VM ──────────────────────────────────────────────

info "Removing ReactOS namespace..."
kubectl delete namespace reactos --ignore-not-found --timeout=60s 2>/dev/null || true

# ─── Remove KubeVirt ─────────────────────────────────────────────────

info "Removing KubeVirt..."
kubectl delete kubevirt kubevirt -n kubevirt --ignore-not-found --timeout=60s 2>/dev/null || true

KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "")
if [ -n "$KUBEVIRT_VERSION" ]; then
    kubectl delete -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml" \
        --ignore-not-found 2>/dev/null || warn "KubeVirt operator cleanup had warnings."
fi

# ─── Remove CDI ──────────────────────────────────────────────────────

info "Removing CDI..."
kubectl delete cdi cdi -n cdi --ignore-not-found --timeout=60s 2>/dev/null || true

CDI_VERSION=$(curl -s https://api.github.com/repos/kubevirt/containerized-data-importer/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "")
if [ -n "$CDI_VERSION" ]; then
    kubectl delete -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml" \
        --ignore-not-found 2>/dev/null || true
    kubectl delete -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" \
        --ignore-not-found 2>/dev/null || warn "CDI operator cleanup had warnings."
fi

# ─── Remove k3s ──────────────────────────────────────────────────────

info "Uninstalling k3s..."
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    /usr/local/bin/k3s-uninstall.sh
else
    warn "k3s uninstall script not found — may already be removed."
fi

# ─── Remove virtctl ──────────────────────────────────────────────────

if [ -f /usr/local/bin/virtctl ]; then
    info "Removing virtctl..."
    sudo rm -f /usr/local/bin/virtctl
fi

# ─── Remove kernel module config ─────────────────────────────────────

if [ -f /etc/modules-load.d/kubevirt.conf ]; then
    info "Removing /etc/modules-load.d/kubevirt.conf"
    sudo rm -f /etc/modules-load.d/kubevirt.conf
fi

# ─── Clean cached ISOs ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ -d "$REPO_DIR/.cache" ]; then
    read -p "Remove cached ReactOS ISO ($REPO_DIR/.cache)? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$REPO_DIR/.cache"
        info "Cache removed."
    fi
fi

echo ""
info "Teardown complete."
