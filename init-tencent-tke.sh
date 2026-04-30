#!/usr/bin/env bash
# Tencent TKE: create a managed cluster + worker CVMs (same behavior as init-tencent-tke.ps1).
# Requires: tccli, jq, env vars below.

set -euo pipefail

REGION="${TKE_REGION:?Set TKE_REGION}"
VPC_ID="${TKE_VPC_ID:?Set TKE_VPC_ID}"
SUBNET_ID="${TKE_SUBNET_ID:?Set TKE_SUBNET_ID}"
ZONE="${TKE_ZONE:?Set TKE_ZONE}"
CLUSTER_NAME="${TKE_CLUSTER_NAME:-tke-lab-$(date +%Y%m%d%H%M%S)}"
CLUSTER_CIDR="${TKE_CLUSTER_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${TKE_SERVICE_CIDR:-10.96.0.0/16}"
K8S_VERSION="${TKE_K8S_VERSION:-1.28.3}"
INSTANCE_TYPE="${TKE_INSTANCE_TYPE:-SA2.MEDIUM4}"
WORKER_COUNT="${TKE_WORKER_COUNT:-2}"
ASSIGN_PUBLIC="${TKE_ASSIGN_PUBLIC_IP:-true}"

if [[ -z "${TKE_NODE_PASSWORD:-}" && -z "${TKE_SSH_KEY_ID:-}" ]]; then
  echo "Set TKE_NODE_PASSWORD or TKE_SSH_KEY_ID" >&2
  exit 1
fi

LOGIN_JSON='{}'
if [[ -n "${TKE_SSH_KEY_ID:-}" ]]; then
  LOGIN_JSON=$(jq -n --arg k "$TKE_SSH_KEY_ID" '{KeyIds: [$k]}')
fi
if [[ -n "${TKE_NODE_PASSWORD:-}" ]]; then
  LOGIN_JSON=$(echo "$LOGIN_JSON" | jq --arg p "$TKE_NODE_PASSWORD" '. + {Password: $p}')
fi

PUB_JSON='false'
[[ "$ASSIGN_PUBLIC" == "true" ]] && PUB_JSON='true'

RUN_JSON=$(jq -n \
  --arg zone "$ZONE" \
  --arg vpc "$VPC_ID" \
  --arg sn "$SUBNET_ID" \
  --arg it "$INSTANCE_TYPE" \
  --arg wc "$WORKER_COUNT" \
  --argjson pub "$PUB_JSON" \
  --argjson login "$LOGIN_JSON" \
  '{
    InstanceChargeType: "POSTPAID_BY_HOUR",
    Placement: { Zone: $zone, ProjectId: 0 },
    InstanceType: $it,
    InstanceCount: ($wc | tonumber),
    VirtualPrivateCloud: { VpcId: $vpc, SubnetId: $sn },
    SystemDisk: { DiskType: "CLOUD_BSSD", DiskSize: 50 },
    InternetAccessible: { InternetMaxBandwidthOut: 20, PublicIpAssigned: $pub },
    LoginSettings: $login
  }')

BODY=$(jq -n \
  --arg cn "$CLUSTER_NAME" \
  --arg vpc "$VPC_ID" \
  --arg sn "$SUBNET_ID" \
  --arg ccidr "$CLUSTER_CIDR" \
  --arg scidr "$SERVICE_CIDR" \
  --arg kv "$K8S_VERSION" \
  --arg rjson "$(echo "$RUN_JSON" | jq -c .)" \
  '{
    ClusterType: "MANAGED_CLUSTER",
    ClusterCIDRSettings: {
      ClusterCIDR: $ccidr,
      IgnoreClusterCIDRConflict: false,
      MaxNodePodNum: 64,
      MaxClusterServiceNum: 256,
      ServiceCIDR: $scidr
    },
    ClusterBasicSettings: {
      ClusterVersion: $kv,
      ClusterName: $cn,
      VpcId: $vpc,
      SubnetId: $sn,
      ProjectId: 0,
      ClusterDescription: "Lab cluster (init-tencent-tke.sh)"
    },
    ClusterAdvancedSettings: {
      NetworkType: "GR",
      ContainerRuntime: "containerd"
    },
    RunInstancesForNode: [
      {
        NodeRole: "WORKER",
        RunInstancesPara: [$rjson]
      }
    ]
  }')

TMP=$(mktemp --suffix=.json)
trap 'rm -f "$TMP"' EXIT
echo "$BODY" >"$TMP"

echo "Creating TKE cluster '$CLUSTER_NAME' in $REGION with ${WORKER_COUNT} worker(s)..."
tccli tke CreateCluster --region "$REGION" --cli-input-json "file://$TMP"
