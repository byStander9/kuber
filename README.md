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

---

## Troubleshooting & Fixes (Tencent Cloud)

### 1. `kubectl`이 실행되지 않음 — `permission denied` on `~/.kube/config`

**문제**: `sudo -E bash kubeadm-two-node.sh master`로 실행하면 스크립트 내부의 `$(id -u)`/`$(id -g)`가 root(0)를 반환하여, `~/.kube` 디렉토리와 `config` 파일이 `root:root` 소유로 생성된다. 일반 유저로 `kubectl`을 실행하면 permission denied 오류가 발생한다.

**수정**: 스크립트 실행 후 아래 명령으로 소유권을 복구한다.

```bash
sudo chown -R $USER:$USER ~/.kube
```

---

### 2. 노드 이름 대소문자 불일치 — `node(s) had no node IPs`

**문제**: 일부 클라우드 환경(Tencent Cloud 등)에서 hostname이 대문자를 포함하는 경우, kubelet이 등록한 노드 이름과 kubeadm이 인식하는 이름이 불일치하여 노드 IP를 찾지 못하는 오류가 발생한다.

**수정**: `kubelet` 실행 인자에 `--hostname-override`를 추가하여 hostname을 소문자로 강제 지정하고, `kubeadm init`의 `--node-name`도 동일하게 소문자로 맞춘다.

```bash
# /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=<node-ip> --hostname-override=<lowercase-hostname>
```

---

### 3. Calico CRD 적용 실패 — `Apply failed: field ... is owned by another manager`

**문제**: `kubectl apply`로 Calico CRD를 적용할 때 서버 측 필드 소유권 충돌로 인해 오류가 발생한다.

**수정**: `--server-side --force-conflicts` 옵션을 추가한다.

```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/projectcalico/calico/<version>/manifests/operator-crds.yaml
```

---

### 4. NodePort 외부 접근 불가 — 워커 노드 Pod로 패킷이 전달되지 않음

**문제**: Tencent Cloud는 VM 간 라우팅 시 Pod CIDR(예: `192.168.x.x`) 주소를 목적지로 하는 패킷을 차단한다. Calico의 기본 캡슐화 모드인 `VXLANCrossSubnet`은 같은 서브넷 내 노드 간에는 캡슐화를 생략(direct routing)하기 때문에, 마스터에서 워커의 Pod로 향하는 패킷이 클라우드 네트워크에서 드롭된다. NodePort 요청이 마스터에서 처리되더라도 워커 Pod로 포워딩되는 경우 응답이 없는 현상이 나타난다.

**수정**: `custom-resources.yaml`의 캡슐화 모드를 `VXLAN`(풀 캡슐화)으로 변경하여 모든 크로스 노드 Pod 트래픽을 UDP로 감싼다.

```bash
# custom-resources.yaml 적용 전
sed -i "s|encapsulation: VXLANCrossSubnet|encapsulation: VXLAN|g" custom-resources.yaml
```

이미 클러스터가 구성된 경우 아래 명령으로 직접 수정한다.

```bash
kubectl edit installation default
# encapsulation: VXLANCrossSubnet → encapsulation: VXLAN 으로 변경
```
