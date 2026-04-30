# kuber

Two-VM Kubernetes lab (Tencent CVM friendly).

## Quick start (kubeadm, 1 control plane + 1 worker)

Clone this repo on **both** VMs, then:

### Control plane VM

```bash
cd ~/kuber
chmod +x kubeadm-two-node.sh
sudo -E bash kubeadm-two-node.sh master
```

Print join command (if you missed it):

```bash
sudo kubeadm token create --print-join-command
```

### Worker VM

```bash
cd ~/kuber
chmod +x kubeadm-two-node.sh
sudo -E bash kubeadm-two-node.sh worker kubeadm join <control-plane-ip>:6443 --token ... --discovery-token-ca-cert-hash sha256:...
```

### Verify (run on control plane)

```bash
sudo -E bash kubeadm-two-node.sh verify
kubectl get nodes -o wide
```

## Notes

- If the script picks the wrong NIC, force it: `export NETWORK_INTERFACE=eth0`
- To advertise the public IP for the API server: `export PUBLIC_IP_ACCESS=true`
- If NodePort from the internet is flaky, force a single iptables backend (recommended on Ubuntu): `export IPTABLES_BACKEND=nft`
