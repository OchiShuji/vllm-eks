#!/usr/bin/env bash
set -euo pipefail

# Install Secrets Store CSI Driver and AWS provider on vllm-cluster.
# Prerequisites: kubectl context must point to vllm-cluster.

echo "==> Adding Helm repos"
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm repo update

echo "==> Installing Secrets Store CSI Driver"
helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true

echo "==> Installing AWS Secrets Manager provider (CSI subchart disabled to avoid conflict)"
helm upgrade --install secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws \
  --namespace kube-system \
  --set secrets-store-csi-driver.install=false

echo "==> Patching AWS provider DaemonSet with CriticalAddonsOnly toleration"
# EKS Auto Mode nodes carry CriticalAddonsOnly:NoSchedule taint by default.
kubectl patch daemonset secrets-provider-aws-secrets-store-csi-driver-provider-aws \
  -n kube-system \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]}]'

echo "==> Waiting for CSI driver and AWS provider pods to be Running"
kubectl rollout status daemonset/csi-secrets-store-secrets-store-csi-driver -n kube-system --timeout=120s
kubectl rollout status daemonset/secrets-provider-aws-secrets-store-csi-driver-provider-aws -n kube-system --timeout=120s

echo "==> Done"
