#Requires -Version 5.1
<#
.SYNOPSIS
  Create a Tencent Kubernetes Engine (TKE) managed cluster with worker nodes via tccli.

.NOTES
  - Prerequisite: Tencent Cloud CLI 3.0 installed (`tccli`) and configured, or env vars set:
      TENCENT_SECRET_ID, TENCENT_SECRET_KEY
  - On TKE *managed* clusters, the Kubernetes control plane is run by Tencent (no user-owned
    "master" CVM). Your CVMs are all worker nodes. TKE *independent* clusters require 3–7
    MASTER_ETCD nodes per API rules, not a single master.
  - For a classic two-VM topology (one control-plane node + one worker), use kubeadm-two-node.sh
    on two CVMs after you create or identify instances.

  Required environment or parameters:
    TKE_REGION, TKE_VPC_ID, TKE_SUBNET_ID, TKE_ZONE
  Authentication for new nodes (one of):
    TKE_NODE_PASSWORD  OR  TKE_SSH_KEY_ID (CVM key pair ID, e.g. skey-xxxxx)

  Optional:
    TKE_CLUSTER_NAME, TKE_CLUSTER_CIDR, TKE_SERVICE_CIDR, TKE_K8S_VERSION,
    TKE_INSTANCE_TYPE, TKE_WORKER_COUNT, TKE_ASSIGN_PUBLIC_IP
#>

[CmdletBinding()]
param(
    [string]$Region = $env:TKE_REGION,
    [string]$VpcId = $env:TKE_VPC_ID,
    [string]$SubnetId = $env:TKE_SUBNET_ID,
    [string]$Zone = $env:TKE_ZONE,
    [string]$ClusterName = $(if ($env:TKE_CLUSTER_NAME) { $env:TKE_CLUSTER_NAME } else { "tke-lab-$(Get-Date -Format 'yyyyMMddHHmmss')" }),
    [string]$ClusterCidr = $(if ($env:TKE_CLUSTER_CIDR) { $env:TKE_CLUSTER_CIDR } else { "10.244.0.0/16" }),
    [string]$ServiceCidr = $(if ($env:TKE_SERVICE_CIDR) { $env:TKE_SERVICE_CIDR } else { "10.96.0.0/16" }),
    [string]$K8sVersion = $(if ($env:TKE_K8S_VERSION) { $env:TKE_K8S_VERSION } else { "1.28.3" }),
    [string]$InstanceType = $(if ($env:TKE_INSTANCE_TYPE) { $env:TKE_INSTANCE_TYPE } else { "SA2.MEDIUM4" }),
    [int]$WorkerCount = $(if ($env:TKE_WORKER_COUNT) { [int]$env:TKE_WORKER_COUNT } else { 2 }),
    [bool]$AssignPublicIp = $(if ($null -ne $env:TKE_ASSIGN_PUBLIC_IP) { $env:TKE_ASSIGN_PUBLIC_IP -eq "true" } else { $true }),
    [string]$NodePassword = $env:TKE_NODE_PASSWORD,
    [string]$SshKeyId = $env:TKE_SSH_KEY_ID
)

$ErrorActionPreference = "Stop"

function Assert-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found in PATH. Install Tencent Cloud CLI: https://www.tencentcloud.com/document/product/1278/45990"
    }
}

Assert-Tool -Name "tccli"

$required = @{
    Region   = $Region
    VpcId    = $VpcId
    SubnetId = $SubnetId
    Zone     = $Zone
}
foreach ($kv in $required.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($kv.Value)) {
        throw "Missing required value: $($kv.Key). Set TKE_$($kv.Key.ToUpper()) or pass -$($kv.Key)."
    }
}

if ($WorkerCount -lt 1 -or $WorkerCount -gt 50) {
    throw "WorkerCount must be between 1 and 50."
}

if ([string]::IsNullOrWhiteSpace($NodePassword) -and [string]::IsNullOrWhiteSpace($SshKeyId)) {
    throw "Set TKE_NODE_PASSWORD or TKE_SSH_KEY_ID so new CVMs can be logged in."
}

$loginSettings = @{}
if (-not [string]::IsNullOrWhiteSpace($SshKeyId)) {
    $loginSettings["KeyIds"] = @($SshKeyId)
}
if (-not [string]::IsNullOrWhiteSpace($NodePassword)) {
    $loginSettings["Password"] = $NodePassword
}

$runInstanceObj = [ordered]@{
    InstanceChargeType = "POSTPAID_BY_HOUR"
    Placement          = @{ Zone = $Zone; ProjectId = 0 }
    InstanceType       = $InstanceType
    InstanceCount      = $WorkerCount
    VirtualPrivateCloud = @{
        VpcId    = $VpcId
        SubnetId = $SubnetId
    }
    SystemDisk = @{
        DiskType = "CLOUD_BSSD"
        DiskSize = 50
    }
    InternetAccessible = @{
        InternetMaxBandwidthOut = 20
        PublicIpAssigned        = $AssignPublicIp
    }
    LoginSettings = $loginSettings
}

$runInstancesParaJson = ($runInstanceObj | ConvertTo-Json -Compress -Depth 8)

$payload = [ordered]@{
    ClusterType           = "MANAGED_CLUSTER"
    ClusterCIDRSettings   = @{
        ClusterCIDR              = $ClusterCidr
        IgnoreClusterCIDRConflict = $false
        MaxNodePodNum            = 64
        MaxClusterServiceNum     = 256
        ServiceCIDR              = $ServiceCidr
    }
    ClusterBasicSettings  = @{
        ClusterVersion    = $K8sVersion
        ClusterName       = $ClusterName
        VpcId             = $VpcId
        SubnetId          = $SubnetId
        ProjectId         = 0
        ClusterDescription = "Lab cluster (init-tencent-tke.ps1)"
    }
    ClusterAdvancedSettings = @{
        NetworkType      = "GR"
        ContainerRuntime = "containerd"
    }
    RunInstancesForNode   = @(
        @{
            NodeRole         = "WORKER"
            RunInstancesPara = @($runInstancesParaJson)
        }
    )
}

$tmp = [System.IO.Path]::GetTempFileName() + ".json"
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, ($payload | ConvertTo-Json -Depth 12), $utf8NoBom)
    $fileUri = "file:///" + ($tmp -replace '\\', '/')
    Write-Host "Writing request to $tmp"
    Write-Host "Creating TKE cluster '$ClusterName' in $Region with $WorkerCount worker CVM(s)..."
    & tccli tke CreateCluster --region $Region --cli-input-json $fileUri
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
}

Write-Host @"

Done. Next steps:
  tccli tke DescribeClusters --region $Region --Filters Name=ClusterName,Values=$ClusterName
  Configure kubectl using the TKE console or DescribeClusterKubeconfig API.

Note: This is a managed cluster — control plane nodes are not your CVMs. For a literal two-VM kubeadm lab, use kubeadm-two-node.sh (runs ../kubeadm-scripts: common.sh, master.sh, worker join).
"@
