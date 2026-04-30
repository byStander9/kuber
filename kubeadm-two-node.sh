#!/usr/bin/env bash
# Two-VM Kubernetes lab (control plane + one worker) using the same flow as typical kubeadm
# walkthroughs (e.g. https://www.youtube.com/watch?v=xX52dc3u2HU ) — node prep, kubeadm init,
# CNI, then kubeadm join on the second host.
#
# This script is a thin launcher for ../kubeadm-scripts (sibling of this folder under your
# home directory). Run it from Linux/WSL on the respective CVMs:
#
#   Control plane VM:
#     export PUBLIC_IP_ACCESS=false    # or true if you use the public IP for the API / kubeconfig
#     sudo -E bash kubeadm-two-node.sh master
#
#   Worker VM (use the full join line from the master after kubeadm init, or
#   kubeadm token create --print-join-command on the control plane):
#     sudo -E bash kubeadm-two-node.sh worker kubeadm join 10.0.0.1:6443 --token ... --discovery-token-ca-cert-hash sha256:...
#
# Optional: force NIC on Tencent CVMs if auto-detect is wrong
#   export NETWORK_INTERFACE=eth0
#
# Verify (from either node after install, or from the control plane):
#   bash ../kubeadm-scripts/scripts/verify-setup.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$ROOT/../kubeadm-scripts/scripts" && pwd)"

if [[ ! -f "$SCRIPTS/common.sh" ]] || [[ ! -f "$SCRIPTS/master.sh" ]]; then
  echo "Could not find kubeadm-scripts under: $SCRIPTS" >&2
  echo "Expected layout: <parent>/kuber_script/kubeadm-two-node.sh and <parent>/kubeadm-scripts/scripts/{common,master}.sh" >&2
  exit 1
fi

case "${1:-}" in
  master)
    sudo -E bash "$SCRIPTS/common.sh"
    sudo -E bash "$SCRIPTS/master.sh"
    echo ""
    echo "Control plane is up. On the worker host, after running the same repo's common.sh (or: worker mode below), run:"
    echo "  kubeadm token create --print-join-command"
    echo "from the control plane, then on the worker:"
    echo "  sudo -E $ROOT/kubeadm-two-node.sh worker kubeadm join <args>"
    ;;
  worker)
    shift
    sudo -E bash "$SCRIPTS/worker.sh" "$@"
    ;;
  *)
    echo "Usage: sudo -E $0 master" >&2
    echo "       sudo -E $0 worker [kubeadm join <args>...]" >&2
    exit 1
    ;;
esac
