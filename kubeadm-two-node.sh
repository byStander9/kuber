#!/usr/bin/env bash
# Two-VM Kubernetes lab (control plane + one worker) using the same flow as typical kubeadm
# walkthroughs (e.g. https://www.youtube.com/watch?v=xX52dc3u2HU ) — node prep, kubeadm init,
# CNI, then kubeadm join on the second host.
#
# This script is self-contained (no dependency on other repos). Run it on each VM:
#
#   Control plane VM:
#     export PUBLIC_IP_ACCESS=false    # set true if you want to use the public IP for the API server
#     sudo -E bash kubeadm-two-node.sh master
#
#   Worker VM (use the full join line from the master after kubeadm init, or
#   kubeadm token create --print-join-command on the control plane):
#     sudo -E bash kubeadm-two-node.sh worker kubeadm join 10.0.0.1:6443 --token ... --discovery-token-ca-cert-hash sha256:...
#
# Optional environment:
#   NETWORK_INTERFACE=eth0            # force NIC if auto-detect is wrong
#   K8S_MINOR=v1.28                   # package channel (default v1.28)
#   KUBERNETES_INSTALL_VERSION=...     # e.g. 1.28.15-1.1 (exact apt version)
#   CRICTL_VERSION=...                # e.g. v1.28.0
#   POD_CIDR=192.168.0.0/16           # Calico default
#   PUBLIC_IP_ACCESS=true|false       # master: use public IP for control-plane endpoint
#   CALICO_VERSION=v3.31.3            # Calico manifests version

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

K8S_MINOR="${K8S_MINOR:-v1.28}"
KUBERNETES_INSTALL_VERSION="${KUBERNETES_INSTALL_VERSION:-1.28.15-1.1}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.28.0}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
PUBLIC_IP_ACCESS="${PUBLIC_IP_ACCESS:-false}"
CALICO_VERSION="${CALICO_VERSION:-v3.31.3}"

log() { echo "[kubeadm-two-node] $*"; }

detect_nic() {
  if [[ -n "${NETWORK_INTERFACE:-}" ]]; then
    echo "$NETWORK_INTERFACE"
    return 0
  fi
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

ensure_prereqs() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required" >&2
    exit 1
  fi
}

common_setup() {
  ensure_prereqs
  log "Disabling swap + setting sysctls..."
  sudo swapoff -a || true
  (sudo crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | sudo crontab - || true

  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg jq software-properties-common

  # Kernel modules
  cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
  sudo modprobe overlay || true
  sudo modprobe br_netfilter || true

  cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sudo sysctl --system

  log "Installing containerd..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y containerd.io
  sudo systemctl enable --now containerd

  sudo mkdir -p /etc/containerd
  sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  sudo systemctl restart containerd

  log "Installing crictl ($CRICTL_VERSION)..."
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) CRICTL_ARCH="amd64" ;;
    arm64) CRICTL_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac
  curl -fsSLO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
  sudo tar zxvf "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" -C /usr/local/bin >/dev/null
  rm -f "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
  cat <<'EOF' | sudo tee /etc/crictl.yaml >/dev/null
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

  log "Installing kubelet/kubeadm/kubectl ($K8S_MINOR, apt=$KUBERNETES_INSTALL_VERSION)..."
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y "kubelet=${KUBERNETES_INSTALL_VERSION}" "kubectl=${KUBERNETES_INSTALL_VERSION}" "kubeadm=${KUBERNETES_INSTALL_VERSION}"
  sudo apt-mark hold kubelet kubeadm kubectl

  NIC="$(detect_nic)"
  if [[ -z "$NIC" ]] || ! ip link show "$NIC" &>/dev/null; then
    echo "Could not detect network interface. Set NETWORK_INTERFACE (e.g. export NETWORK_INTERFACE=eth0)" >&2
    exit 1
  fi
  log "Using network interface for node-ip: $NIC"
  local_ip="$(ip --json addr show "$NIC" | jq -r '.[0].addr_info[] | select(.family == "inet") | .local' | head -1)"
  if [[ -z "$local_ip" ]]; then
    echo "Could not detect node IP for interface $NIC" >&2
    exit 1
  fi
  echo "KUBELET_EXTRA_ARGS=--node-ip=$local_ip" | sudo tee /etc/default/kubelet >/dev/null
  sudo systemctl enable kubelet

  log "Common setup complete."
}

master_setup() {
  ensure_prereqs
  NIC="$(detect_nic)"
  if [[ -z "$NIC" ]] || ! ip link show "$NIC" &>/dev/null; then
    echo "Set NETWORK_INTERFACE to your primary NIC (e.g. export NETWORK_INTERFACE=eth0)" >&2
    exit 1
  fi

  log "Pulling kubeadm images..."
  sudo kubeadm config images pull

  NODENAME="$(hostname -s)"

  if [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then
    MASTER_PUBLIC_IP="$(curl -fsSL ifconfig.me)"
    log "Initializing control plane using public IP: $MASTER_PUBLIC_IP"
    sudo kubeadm init \
      --control-plane-endpoint="$MASTER_PUBLIC_IP" \
      --apiserver-cert-extra-sans="$MASTER_PUBLIC_IP" \
      --pod-network-cidr="$POD_CIDR" \
      --node-name "$NODENAME" \
      --ignore-preflight-errors Swap
  else
    MASTER_PRIVATE_IP="$(ip addr show "$NIC" | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"
    log "Initializing control plane using private IP ($NIC): $MASTER_PRIVATE_IP"
    sudo kubeadm init \
      --apiserver-advertise-address="$MASTER_PRIVATE_IP" \
      --apiserver-cert-extra-sans="$MASTER_PRIVATE_IP" \
      --pod-network-cidr="$POD_CIDR" \
      --node-name "$NODENAME" \
      --ignore-preflight-errors Swap
  fi

  log "Configuring kubeconfig..."
  mkdir -p "$HOME/.kube"
  sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

  log "Installing Calico CNI ($CALICO_VERSION)..."
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/operator-crds.yaml"
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
  sleep 120
  curl -fsSLO "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"
  sed -i "s|cidr: 192.168.0.0/16|cidr: ${POD_CIDR}|g" custom-resources.yaml
  kubectl apply -f custom-resources.yaml
  sleep 30

  log "Control plane complete. Join command:"
  sudo kubeadm token create --print-join-command || true
}

worker_setup() {
  ensure_prereqs
  if [[ $# -eq 0 ]]; then
    echo ""
    echo "Usage:"
    echo "  sudo -E bash $0 worker kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
    echo ""
    echo "On the control plane, print a join command with:"
    echo "  kubeadm token create --print-join-command"
    exit 1
  fi
  log "Running join..."
  sudo "$@"
}

verify_setup() {
  echo "=== Versions ==="
  (command -v kubeadm >/dev/null 2>&1 && kubeadm version -o short) || echo "kubeadm: not installed"
  (command -v kubelet >/dev/null 2>&1 && kubelet --version) || echo "kubelet: not installed"
  (command -v kubectl >/dev/null 2>&1 && kubectl version --client --short) || echo "kubectl: not installed"
  (command -v containerd >/dev/null 2>&1 && containerd --version) || echo "containerd: not installed"
  (command -v crictl >/dev/null 2>&1 && crictl --version) || echo "crictl: not installed"
  echo ""
  echo "=== Services ==="
  sudo systemctl is-active --quiet containerd && echo "containerd: running" || echo "containerd: not running"
  sudo systemctl is-active --quiet kubelet && echo "kubelet: running" || echo "kubelet: not running"
  echo ""
  if [[ -f /etc/kubernetes/admin.conf ]] && command -v kubectl >/dev/null 2>&1; then
    echo "=== Cluster ==="
    kubectl get nodes -o wide || true
    kubectl get pods -A | head -n 40 || true
  fi
}

case "${1:-}" in
  master)
    common_setup
    master_setup
    echo ""
    echo "Control plane is up. On the worker host, after running the same repo's common.sh (or: worker mode below), run:"
    echo "  kubeadm token create --print-join-command"
    echo "from the control plane, then on the worker:"
    echo "  sudo -E $ROOT/kubeadm-two-node.sh worker kubeadm join <args>"
    ;;
  worker)
    shift
    common_setup
    worker_setup "$@"
    ;;
  common)
    common_setup
    ;;
  verify)
    verify_setup
    ;;
  *)
    echo "Usage: sudo -E $0 master" >&2
    echo "       sudo -E $0 worker kubeadm join <args...>" >&2
    echo "       sudo -E $0 common" >&2
    echo "       sudo -E $0 verify" >&2
    exit 1
    ;;
esac
