#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Multi-Cloud Karpenter + vCluster + Knative + Istio Setup Script (idempotent + delete)
#  Implements Aggressive Spot Usage with Karpenter, Azure AKS support,
#  Host and vCluster application partitioning,
#  Knative-managed ingress,
#  vCluster-level and host-level monitoring,
#  alias setup, kubecost installation, and usage info.
#  https://github.com/shlapolosa/idp
#
#  Usage:
#    ./setup-karpenter-vclusters.sh [--delete] [--cloud aws|azure] \
#        [--region <r>] [--cluster-name <n>]
# ---------------------------------------------------------------------------

set -Eeuo pipefail
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Cleanup on failure
# ---------------------------------------------------------------------------
cleanup() {
  if [[ $? -ne 0 ]]; then
    error "Script failed"
  fi
}

# ---------------------------------------------------------------------------
# Config (env vars override)
# ---------------------------------------------------------------------------
ACTION="create"                                # create | delete
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"        # aws | azure
CLUSTER_NAME="${CLUSTER_NAME:-modern-engineering}"
REGION="${REGION:-us-west-2}"

# Version defaults (override as needed)
KARPENTER_VERSION="${KARPENTER_VERSION:-1.5.0}"
VCLUSTER_VERSION="${VCLUSTER_VERSION:-0.25}"
K8S_VERSION="${K8S_VERSION:-1.29}"
KNATIVE_SERVING_VERSION="${KNATIVE_SERVING_VERSION:-1.18.0}"
KNATIVE_EVENTING_VERSION="${KNATIVE_EVENTING_VERSION:-1.18.0}"
ISTIO_VERSION="${ISTIO_VERSION:-1.26.1}"

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Delete resources
# ---------------------------------------------------------------------------
delete_cluster() {
  info "Deleting resources for '${CLUSTER_NAME}'..."
  # vClusters
  for v in modern-engineering modernengg-dev modernengg-prod; do
    if kubectl get ns "vcluster-$v" &>/dev/null; then
      vcluster delete "$v" --namespace "vcluster-$v" --yes || true
      kubectl delete ns "vcluster-$v" --ignore-not-found
      kubectl config delete-context "vcluster-${v}" || true
    fi
  done
  # Host contexts
  kubectl config delete-context "${CLUSTER_NAME}" || true
  kubectl config delete-cluster "${CLUSTER_NAME}" || true
  if [[ "${CLOUD_PROVIDER}" == "aws" ]]; then
    eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" || true
    aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}" || true
    aws cloudformation wait stack-delete-complete --stack-name "Karpenter-${CLUSTER_NAME}" || true
  else
    az aks delete --name "${CLUSTER_NAME}" --resource-group "rg-${CLUSTER_NAME}" --yes || true
    az group delete --name "rg-${CLUSTER_NAME}" --yes --no-wait || true
  fi
  # Alias cleanup
  local bashrc="$HOME/.bashrc"
  for a in kc ve vd vp; do sed -i.bak "/alias $a='/d" "$bashrc" || true; done
  success "Teardown complete. Aliases removed."
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
validate_prerequisites() {
  info "Validating prerequisites..."
  for tool in kubectl helm curl; do
    command -v "$tool" &>/dev/null || error "$tool not installed"
  done
  if [[ "${CLOUD_PROVIDER}" == "aws" ]]; then
    for tool in aws eksctl vcluster; do
      command -v "$tool" &>/dev/null || error "$tool not installed"
    done
    aws sts get-caller-identity &>/dev/null || error "AWS CLI not configured"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export ACCOUNT_ID
  else
    for tool in az vcluster; do
      command -v "$tool" &>/dev/null || error "$tool not installed"
    done
    az account show &>/dev/null || error "Azure CLI not logged in"
  fi
  success "Prerequisites OK"
}

# ---------------------------------------------------------------------------
# CLI Help
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $0 [--delete] [--cloud aws|azure] [--region <r>] [--cluster-name <n>]

Options:
  --delete             Tear down all resources created
  --cloud aws|azure    Cloud provider (default: aws)
  --region <r>         Region (default: us-west-2)
  --cluster-name <n>   Cluster name (default: modern-engineering)

Examples:
  $0 --cloud aws --region us-west-2 --cluster-name my-cluster
  $0 --delete --cloud aws --cluster-name my-cluster
USAGE
}

# ---------------------------------------------------------------------------
# Host cluster creation
# ---------------------------------------------------------------------------
create_eks_cluster() {
  info "Deploying Karpenter CFN stack..."

    # download CFN template to a real temp file
  local tmpfile
  tmpfile=$(mktemp /tmp/karpenter-cfn-XXXX.yaml)
  curl -fsSL \
    "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
    -o "$tmpfile"

  aws cloudformation deploy --stack-name "Karpenter-${CLUSTER_NAME}" \
    --template-file "$tmpfile" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}"

  rm -f "$tmpfile"

  if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" &>/dev/null; then
    info "EKS cluster exists, skipping creation"
  else
    info "Creating EKS cluster with a small bootstrap nodegroup…"

# 1. Pick your profile
profile="${AWS_PROFILE:-default}"

# 2. Where is your SSO directory?
sso_region=$(aws configure get sso_region        --profile "$profile")

# 3. Where do your AWS services live?
aws_region=$(aws configure get region             --profile "$profile")
# Fallback if you haven’t set it:
aws_region=${aws_region:-us-west-2}

account=$(aws configure get sso_account_id       --profile "$profile")
role=$(aws configure get sso_role_name           --profile "$profile")

# 4. Grab the most recent SSO cache file
cache=$(ls -1t ~/.aws/sso/cache/*.json | head -n1)
token=$(jq -r .accessToken "$cache")

# 5. Exchange for AWS creds in the SSO realm
creds_json=$(
  aws sso get-role-credentials \
    --account-id   "$account" \
    --role-name    "$role" \
    --access-token "$token" \
    --region       "$sso_region"
)

# 6. Export them
export AWS_ACCESS_KEY_ID=$(jq -r .roleCredentials.accessKeyId     <<<"$creds_json")
export AWS_SECRET_ACCESS_KEY=$(jq -r .roleCredentials.secretAccessKey <<<"$creds_json")
export AWS_SESSION_TOKEN=$(jq -r .roleCredentials.sessionToken    <<<"$creds_json")

# 7. And set the AWS region for STS/EKS calls
export AWS_REGION="$aws_region"
export AWS_DEFAULT_REGION="$aws_region"

# 8. Now list clusters

export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="1.5.0"
export K8S_VERSION="1.32"

export AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
export CLUSTER_NAME="${USER}-karpenter-demo"
export AWS_DEFAULT_REGION="us-west-2"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT="$(mktemp)"
export ALIAS_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value | xargs aws ec2 describe-images --query 'Images[0].Name' --image-ids | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"

echo "${KARPENTER_NAMESPACE}" "${KARPENTER_VERSION}" "${K8S_VERSION}" "${CLUSTER_NAME}" "${AWS_DEFAULT_REGION}" "${AWS_ACCOUNT_ID}" "${TEMPOUT}" "${ALIAS_VERSION}"


eksctl create cluster -f - <<EOF
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
  ## If you intend to run Windows workloads, the kube-proxy group should be specified.
  # For more information, see https://github.com/aws/karpenter/issues/5099.
  # - eks:kube-proxy-windows

managedNodeGroups:
- instanceType: t3.small
  amiFamily: AmazonLinux2023
  name: ${CLUSTER_NAME}-ng
  desiredCapacity: 2
  minSize: 1
  maxSize: 4

addons:
- name: vpc-cni
  version: latest
  attachPolicyARNs:
    - arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKS_CNI_Policy
- name: kube-proxy
  version: latest
- name: coredns
  version: latest
- name: eks-pod-identity-agent
  version: latest
EOF

export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.endpoint" --output text)"
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

echo "${CLUSTER_ENDPOINT} ${KARPENTER_IAM_ROLE_ARN}"

    aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"
    success "EKS cluster created with bootstrap nodes"
  fi
}
create_aks_cluster() {
  info "Ensuring resource group..."
  az group create --name "rg-${CLUSTER_NAME}" --location "${REGION}"
  if az aks show --resource-group "rg-${CLUSTER_NAME}" --name "${CLUSTER_NAME}" &>/dev/null; then
    info "AKS cluster exists, skipping creation"
  else
    info "Creating AKS cluster..."
    az aks create --resource-group "rg-${CLUSTER_NAME}" --name "${CLUSTER_NAME}" \
      --kubernetes-version "${K8S_VERSION}" --node-count 2 --node-vm-size Standard_D2s_v3 \
      --enable-managed-identity --enable-addons monitoring \
      --enable-cluster-autoscaler --min-count 1 --max-count 10 \
      --network-plugin azure --network-plugin-mode overlay \
      --network-dataplane cilium --generate-ssh-keys
    az aks get-credentials --resource-group "rg-${CLUSTER_NAME}" --name "${CLUSTER_NAME}"
    success "AKS cluster created"
  fi
}

# ---------------------------------------------------------------------------
# Karpenter (spot-only)
# ---------------------------------------------------------------------------
install_karpenter() {
  info "Installing Karpenter ${KARPENTER_VERSION}..."


# Logout of helm registry to perform an unauthenticated pull against the public ECR
helm registry logout public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

cat <<EOF | envsubst | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h # 30 * 24h = 720h
  limits:
    cpu: 20
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "KarpenterNodeRole-${CLUSTER_NAME}" # replace with your cluster name
  amiSelectorTerms:
    - alias: "al2023@${ALIAS_VERSION}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}" # replace with your cluster name
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}" # replace with your cluster name
EOF

  success "Karpenter configured for spot-only nodes"
}


# ---------------------------------------------------------------------------
# Istio & Knative
# ---------------------------------------------------------------------------
install_istio() {
  info "Installing Istio ${ISTIO_VERSION}..."
  curl -L "https://istio.io/downloadIstio" | ISTIO_VERSION="${ISTIO_VERSION}" sh -
  "istio-${ISTIO_VERSION}/bin/istioctl" install --set profile=demo --skip-confirmation
  success "Istio installed"
}
install_knative_serving() {
  info "Installing Knative Serving..."
  kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-crds.yaml"
  kubectl apply -f "https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-core.yaml"
  success "Knative Serving installed"
}
install_knative_eventing() {
  info "Installing Knative Eventing..."
  kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_EVENTING_VERSION}/eventing-crds.yaml"
  kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-v${KNATIVE_EVENTING_VERSION}/eventing-core.yaml"
  success "Knative Eventing installed"
}
configure_knative_istio() {
  info "Configuring Knative Istio networking..."
  kubectl apply -f "https://github.com/knative/net-istio/releases/download/knative-v${KNATIVE_SERVING_VERSION}/istio.yaml"
  kubectl apply -f "https://github.com/knative/net-istio/releases/download/knative-v${KNATIVE_SERVING_VERSION}/net-istio.yaml"
  success "Knative Istio networking configured"
}

# ---------------------------------------------------------------------------
# vCluster CLI & clusters
# ---------------------------------------------------------------------------
install_vcluster() {
  info "Installing vCluster CLI..."
  helm repo add loft-sh https://charts.loft.sh &>/dev/null || true
  helm repo update &>/dev/null
  if ! command -v vcluster &>/dev/null; then
    curl -sLo /tmp/vcluster "https://github.com/loft-sh/vcluster/releases/download/v${VCLUSTER_VERSION}/vcluster-linux-amd64"
    sudo install -m0755 /tmp/vcluster /usr/local/bin/vcluster
  fi
  success "vCluster CLI ready"
}
create_vclusters() {
  info "Creating vClusters..."
  for v in modern-engineering modernengg-dev modernengg-prod; do
    if kubectl get ns "vcluster-$v" &>/dev/null; then
      info "vCluster $v exists, skipping"
    else
      kubectl create ns "vcluster-$v" --dry-run=client -o yaml | kubectl apply -f -
      vcluster create "$v" --namespace "vcluster-$v" --version "$VCLUSTER_VERSION" --wait
      success "vCluster $v created"
    fi
  done
}

# ---------------------------------------------------------------------------
# Host-only applications
# ---------------------------------------------------------------------------
install_host_applications() {
  info "Installing host-only applications..."
  helm repo add gitea-charts https://dl.gitea.io/charts/ &>/dev/null || true
  helm upgrade --install gitea gitea-charts/gitea \
    --namespace gitea --create-namespace \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=128Mi
  helm repo add bitnami https://charts.bitnami.com/bitnami &>/dev/null || true
  helm upgrade --install keycloak bitnami/keycloak \
    --namespace keycloak --create-namespace \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=256Mi
  kubectl create ns backstage --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backstage
  namespace: backstage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backstage
  template:
    metadata:
      labels:
        app: backstage
    spec:
      containers:
      - name: backstage
        image: backstage/backstage:latest
        ports:
        - containerPort: 7007
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
EOF
  success "Host applications installed"
}

# ---------------------------------------------------------------------------
# vCluster application installs
# ---------------------------------------------------------------------------
install_applications() {
  info "Installing vCluster applications..."
  contexts=("vcluster-modern-engineering" "vcluster-modernengg-dev" "vcluster-modernengg-prod")
  for ctx in "${contexts[@]}"; do
    info "Deploying into context $ctx"
    kubectl config use-context "$ctx"
    kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    helm repo add jetstack https://charts.jetstack.io &>/dev/null || true
    helm upgrade --install cert-manager jetstack/cert-manager \
      --namespace cert-manager --create-namespace \
      --set installCRDs=true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null || true
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring --create-namespace
  done
  kubectl config use-context "${CLUSTER_NAME}"
  success "vCluster applications installed"
}

# ---------------------------------------------------------------------------
# Host-level monitoring (Prometheus/Grafana)
# ---------------------------------------------------------------------------
install_host_monitoring() {
  info "Installing host-level monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null || true
  helm upgrade --install host-monitoring prometheus-community/kube-prometheus-stack \
    --namespace host-monitoring --create-namespace
  success "Host monitoring installed"
}

# ---------------------------------------------------------------------------
# Kubecost
# ---------------------------------------------------------------------------
install_kubecost() {
  info "Installing Kubecost cost-analyzer..."
  helm repo add kubecost https://kubecost.github.io/cost-analyzer/ &>/dev/null || true
  helm repo update &>/dev/null
  helm upgrade --install kubecost kubecost/cost-analyzer \
    --namespace kubecost --create-namespace \
    --set prometheus.server.persistentVolume.size=10Gi \
    --set prometheus.alertmanager.persistentVolume.size=2Gi \
    --wait
  success "Kubecost installed"
}

# ---------------------------------------------------------------------------
# Aliases, usage info
# ---------------------------------------------------------------------------
configure_aliases() {
  info "Configuring context-switch aliases..."
  local bashrc="$HOME/.bashrc"
  {
    grep -q "alias kc=" "$bashrc" || echo "alias kc='kubectl config use-context ${CLUSTER_NAME}'"
    echo "alias ve='kubectl config use-context vcluster-modern-engineering'"
    echo "alias vd='kubectl config use-context vcluster-modernengg-dev'"
    echo "alias vp='kubectl config use-context vcluster-modernengg-prod'"
  } >> "$bashrc"
  success "Aliases added to $bashrc"
}
show_connection_info() {
  success "Deployment complete!"
  cat <<EOF

==================================================
🚀  MODERN ENGINEERING CLUSTER READY
==================================================
🔑  Aliases (run 'source ~/.bashrc'):
    kc   # host cluster
    ve   # dev vCluster
    vd   # prod-dev vCluster
    vp   # prod vCluster
🌐  Local setup:
    - aws configure (AWS)
    - az aks get-credentials -g rg-${CLUSTER_NAME} -n ${CLUSTER_NAME} (Azure)
💻  Access:
    - Argo CD: kubectl port-forward svc/argocd-server -n argocd 8080:443
    - Kubecost: kubectl port-forward svc/kubecost-cost-analyzer -n kubecost 9090 &
EOF
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
  validate_prerequisites
  [[ "$ACTION" == "delete" ]] && delete_cluster && exit 0

  if [[ "${CLOUD_PROVIDER}" == "aws" ]]; then
    create_eks_cluster
  else
    create_aks_cluster
  fi

  install_karpenter
  install_istio
  install_knative_serving
  install_knative_eventing
  configure_knative_istio

  install_host_monitoring
  install_kubecost

  install_host_applications
  install_vcluster
  create_vclusters
  install_applications

  configure_aliases
  show_connection_info
}

# CLI parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) ACTION="delete"; shift;;
    --cloud) CLOUD_PROVIDER="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) error "Unknown option: $1";;
  esac
done

main "$@"
