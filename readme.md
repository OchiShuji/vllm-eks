# vLLM on EKS — Setup Guide

Serves **Gemma 2 2B** via vLLM on an EKS Auto Mode cluster in `ap-northeast-1`, with HTTPS on `vllm.consulting-io.com`.

## Architecture

See `architecture.drawio` (open with [draw.io](https://app.diagrams.net) or the VS Code draw.io extension).

```
Client → Route 53 → ALB (HTTPS :443, TLS 1.3)
       → Ingress → NetworkPolicy → vLLM Service → vLLM Pod (g4dn, GPU)
                                                  ↑
                              CSI Driver ← AWS Secrets Manager (HF_TOKEN)
```

## Prerequisites

Ensure the following tools are installed:

```bash
brew install eksctl kubectl helm awscli terraform
```

Verify AWS identity and region:

```bash
aws sts get-caller-identity
aws configure get region   # must be ap-northeast-1
```

## Current Status (as of 2026-04-18)

| Step | Description | Status |
|------|-------------|--------|
| 0 | Pre-flight checks | Done |
| 1 | EKS cluster | Done — torn down pending quota fix |
| 2 | HF_TOKEN in Secrets Manager + CSI driver | Done — torn down |
| 3 | GPU NodePool (g4dn) + NodeClass | Done — torn down |
| 4 | vLLM Deployment | Partially done — blocked by GPU quota |
| 5 | NetworkPolicy | Not applied |
| 6 | ALB Ingress | Not applied |

### Blocker: GPU vCPU Quota

Two quota increase requests were submitted (status: `CASE_OPENED`). Check status before proceeding:

```bash
aws service-quotas list-requested-service-quota-changes-by-service \
  --service-code ec2 --region ap-northeast-1 \
  --query 'RequestedQuotas[?contains(QuotaName,`G and VT`)].[QuotaName,Status,DesiredValue]' \
  --output table
```

Required quotas (both must be `APPROVED`):

| Quota | Code | Required |
|-------|------|----------|
| Running On-Demand G and VT instances | L-DB2E81BA | 4 vCPU |
| All G and VT Spot Instance Requests | L-3819A6DF | 4 vCPU |

---

## Deployment Steps

### Step 0 — Variables to fill in

Before starting, collect:

| Variable | Value |
|----------|-------|
| `HF_TOKEN` | Your Hugging Face token |
| `ALLOWED_CIDRS` | IP range allowed to access the ALB endpoint |

### Step 1 — Create EKS Cluster

```bash
eksctl create cluster -f cluster.yaml
# Takes ~15 minutes. Validates:
eksctl get cluster --region ap-northeast-1
kubectl config current-context   # must show vllm-cluster
```

### Step 2 — Terraform (ACM cert, Secrets Manager, IAM)

```bash
cd tf
terraform init

# Pass HF_TOKEN securely via env var — never hardcode it
export TF_VAR_hf_token="<your_hf_token>"

# After eksctl completes, node role name is auto-set in variables.tf.
# If it changed (re-created cluster), update node_role_name in variables.tf first.

terraform apply
cd ..
```

This creates:
- ACM certificate for `vllm.consulting-io.com` (DNS-validated via Route 53)
- Secrets Manager secret `vllm-cluster/hf-token`
- IAM inline policy granting node role read access to the secret

The `acm_certificate_arn` output is already hard-coded in `manifests/04-ingress.yaml`.

### Step 3 — Install Helm charts (CSI Secrets Store driver)

```bash
bash helm-install.sh
```

This installs the Secrets Store CSI driver and AWS Secrets Manager provider,
and patches the DaemonSet with the `CriticalAddonsOnly` toleration required by EKS Auto Mode nodes.

### Step 4 — Apply Kubernetes Manifests

Fill in `$ALLOWED_CIDRS` in `manifests/04-ingress.yaml` before applying.

```bash
# Apply in order
kubectl apply -f manifests/00-secret-provider-class.yaml
kubectl apply -f manifests/01-gpu-nodepool.yaml
kubectl apply -f manifests/02-vllm-deployment.yaml
kubectl apply -f manifests/03-network-policy.yaml
kubectl apply -f manifests/04-ingress.yaml
```

Watch Karpenter provision the GPU node (takes 3–5 minutes):

```bash
kubectl get nodeclaim -w
kubectl get nodes -l node-type=gpu -w
```

Watch the vLLM pod come up (model download takes ~5 minutes):

```bash
kubectl get pod -l app=vllm -w
kubectl logs -f -l app=vllm
```

### Step 5 — Post-deployment Validation

```bash
# Confirm HTTPS-only ALB
kubectl get ingress vllm-ingress -o yaml | grep certificate-arn

# Confirm no plaintext token in pod spec
kubectl get deployment vllm -o yaml | grep -i hf_token
# Expected: secretKeyRef only — no plaintext value

# Confirm NetworkPolicy is active
kubectl get networkpolicy

# Confirm GPU node is running
kubectl get nodes -l node-type=gpu

# Test the endpoint (replace with actual ALB DNS)
ALB=$(kubectl get ingress vllm-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s https://vllm.consulting-io.com/v1/models | jq .
```

---

## Known Issues & Lessons Learned

### 1. EKS Auto Mode node taint
Auto Mode nodes carry `CriticalAddonsOnly:NoSchedule`. Any DaemonSet or pod targeting these nodes must include:
```yaml
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
    effect: NoSchedule
```
This is already applied in `helm-install.sh` (patch) and `manifests/02-vllm-deployment.yaml`.

### 2. Karpenter nodeSelector
Use `karpenter.sh/nodepool: gpu-nodepool` as the pod nodeSelector — not custom labels like `workload-type`.
Custom labels in `NodePool.spec.template.metadata.labels` are applied to nodes after launch but cannot be used by Karpenter to match pods during scheduling.

### 3. NodePool `nodeClassRef.group`
Must be `eks.amazonaws.com` (no version suffix). Using `eks.amazonaws.com/v1` causes a validation error.

### 4. AWS provider Helm chart conflict
The `aws-secrets-manager` chart bundles the CSI driver as a subchart. Since we install the CSI driver separately, disable the subchart:
```bash
--set secrets-store-csi-driver.install=false
```

### 5. GPU quota (main blocker)
New AWS accounts have 0 vCPU quota for G-family instances. Request increases for both On-Demand (`L-DB2E81BA`) and Spot (`L-3819A6DF`) before deploying.

---

## Cleanup

To tear down everything:

```bash
# Kubernetes resources
kubectl delete -f manifests/
helm uninstall secrets-provider-aws csi-secrets-store -n kube-system

# AWS resources via Terraform
cd tf && TF_VAR_hf_token=dummy terraform destroy -auto-approve && cd ..

# IAM policy (if not managed by Terraform)
aws iam delete-role-policy \
  --role-name eksctl-vllm-cluster-cluster-AutoModeNodeRole-vl1nYpksyusp \
  --policy-name vllm-hf-token-secrets-manager

# Secrets Manager
aws secretsmanager delete-secret \
  --secret-id vllm-cluster/hf-token \
  --force-delete-without-recovery \
  --region ap-northeast-1

# EKS cluster (~10 minutes)
eksctl delete cluster --name vllm-cluster --region ap-northeast-1
```

## File Reference

```
.
├── architecture.drawio          # System architecture diagram
├── cluster.yaml                 # eksctl ClusterConfig
├── helm-install.sh              # CSI driver + AWS provider Helm install
├── tf/
│   ├── main.tf                  # Provider config
│   ├── variables.tf             # Region, domain, HF_TOKEN, node role name
│   ├── acm.tf                   # ACM cert + Route 53 DNS validation
│   ├── secrets_manager.tf       # Secrets Manager secret for HF_TOKEN
│   ├── iam.tf                   # IAM policy on node role
│   └── outputs.tf               # Prints ACM certificate ARN
└── manifests/
    ├── 00-secret-provider-class.yaml   # Maps Secrets Manager → K8s Secret
    ├── 01-gpu-nodepool.yaml            # Karpenter NodePool + NodeClass (g4dn, 100Gi)
    ├── 02-vllm-deployment.yaml        # vLLM Deployment + Service
    ├── 03-network-policy.yaml         # Restrict ingress to ALB only
    └── 04-ingress.yaml                # ALB Ingress (HTTPS, ACM, IP restriction)
```
