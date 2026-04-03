#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

VNC_PORT=${1:-5900}

echo "Connecting to ReactOS VNC console on port $VNC_PORT..."
echo "(Close the VNC viewer window to disconnect)"
echo ""

# Use proxy-only + tigervnc for proper absolute cursor positioning.
# remote-viewer (virt-viewer) has cursor offset issues with ReactOS.
cleanup() {
    kill "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT

virtctl vnc reactos -n reactos --proxy-only --port "$VNC_PORT" &
PROXY_PID=$!
sleep 2

if command -v vncviewer &>/dev/null; then
    vncviewer "127.0.0.1:$VNC_PORT"
elif command -v remote-viewer &>/dev/null; then
    echo "Warning: remote-viewer may have cursor offset issues. Install tigervnc-viewer for best results."
    remote-viewer "vnc://127.0.0.1:$VNC_PORT"
else
    echo "No VNC viewer found. Install with: sudo apt install tigervnc-viewer"
    exit 1
fi
