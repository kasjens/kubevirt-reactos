#!/usr/bin/env bash
set -euo pipefail

# CDI cannot auto-detect access modes from k3s's local-path provisioner.
# Without this patch, DataVolume creation fails silently.
# See: https://github.com/kubevirt/kubevirt/issues/10786

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

echo "Patching StorageProfile for local-path provisioner..."

# Wait for the StorageProfile to exist (CDI creates it after detecting the StorageClass)
for i in $(seq 1 30); do
    if kubectl get storageprofile local-path &>/dev/null 2>&1; then
        break
    fi
    echo "  Waiting for StorageProfile 'local-path' to appear... ($i/30)"
    sleep 2
done

if ! kubectl get storageprofile local-path &>/dev/null 2>&1; then
    echo "ERROR: StorageProfile 'local-path' not found after 60s."
    echo "Verify CDI is deployed and local-path StorageClass exists."
    exit 1
fi

kubectl patch storageprofile local-path --type merge \
    -p '{"spec":{"claimPropertySets":[{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]}}'

echo "StorageProfile patched successfully."
kubectl get storageprofile local-path -o jsonpath='{.spec.claimPropertySets}' && echo ""
