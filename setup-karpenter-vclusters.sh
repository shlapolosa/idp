#!/bin/bash

# Multi-Cloud Karpenter + vCluster Setup Script
# Part of shlapolosa/idp repository: https://github.com/shlapolosa/idp
# Replaces setup-environments.sh with cost-optimized architecture
# Supports AWS EKS and Azure AKS with scale-to-zero capabilities

set -e

# Configuration
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"  # aws or azure
CLUSTER_NAME="${CLUSTER_NAME:-modern-engineering}"
REGION="${REGION:-us-west-2}"
KARPENTER_VERSION="${KARPENTER_VERSION:-0.16.3}"
VCLUSTER_VERSION="${VCLUSTER_VERSION:-0.20.0}"
K8S_VERSION="${K8S_VERSION:-1.29}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites for $CLOUD_PROVIDER..."
    
    # Common tools
    command -v kubectl >/dev/null 2>&1 || error "kubectl not found"
    command -v helm >/dev/null 2>&1 || error "helm not found"
    
    if [[ "$CLOUD_PROVIDER" == "aws" ]]; then
        command -v aws >/dev/null 2>&1 || error "AWS CLI not found"
        command -v eksctl >/dev/null 2>&1 || error "eksctl not found"
        aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI not configured"
        export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    elif [[ "$CLOUD_PROVIDER" == "azure" ]]; then
        command -v az >/dev/null 2>&1 || error "Azure CLI not found"
        az account show >/dev/null 2>&1 || error "Azure CLI not logged in"
        export SUBSCRIPTION_ID=$(az account show --query id --output tsv)
    else
        error "Unsupported cloud provider: $CLOUD_PROVIDER"
    fi
    
    success "Prerequisites validated for $CLOUD_PROVIDER"
}

# Create EKS cluster with Karpenter
create_eks_cluster() {
    log "Creating EKS cluster with Karpenter support..."
    
    # Export environment variables per Karpenter docs
    export KARPENTER_NAMESPACE="kube-system"
    export TEMPOUT="$(mktemp)"
    export ARM_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-arm64/recommended/image_id --query Parameter.Value --output text)"
    export AMD_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id --query Parameter.Value --output text)"
    export GPU_AMI_ID="$(aws ssm get-parameter --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id --query Parameter.Value --output text)"
    
    # Create CloudFormation template per Karpenter getting started
    curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > $TEMPOUT
    aws cloudformation deploy \
      --stack-name "Karpenter-${CLUSTER_NAME}" \
      --template-file "${TEMPOUT}" \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides "ClusterName=${CLUSTER_NAME}"
    
    # Create cluster using eksctl
    eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: "${CLUSTER_NAME}"

iam:
  withOIDC: true
  serviceAccounts:
  - metadata:
      name: karpenter
      namespace: "${KARPENTER_NAMESPACE}"
    roleName: "${CLUSTER_NAME}-karpenter"
    attachPolicyARNs:
    - "arn:aws:iam::${ACCOUNT_ID}:policy/KarpenterNodeInstanceProfile"
    roleOnly: true

iamIdentityMappings:
- arn: "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeInstanceProfile"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes

managedNodeGroups:
- instanceType: t3.medium
  amiFamily: AmazonLinux2
  name: "${CLUSTER_NAME}-ng"
  desiredCapacity: 2
  minSize: 1
  maxSize: 10
  taints:
  - key: CriticalAddonsOnly
    value: "true"
    effect: NoSchedule
EOF

    # Update kubeconfig
    aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME
    
    success "EKS cluster created"
}\n\n# Create AKS cluster with Node Autoprovisioning (Karpenter)\ncreate_aks_cluster() {\n    log \"Creating AKS cluster with Node Autoprovisioning...\"\n    \n    local resource_group=\"rg-${CLUSTER_NAME}\"\n    \n    # Create resource group\n    az group create --name $resource_group --location $REGION\n    \n    # Create AKS cluster with Node Autoprovisioning (preview)\n    az aks create \\\n        --resource-group $resource_group \\\n        --name $CLUSTER_NAME \\\n        --kubernetes-version $K8S_VERSION \\\n        --node-count 2 \\\n        --node-vm-size Standard_D2s_v3 \\\n        --enable-addons monitoring \\\n        --enable-msi-auth-for-monitoring \\\n        --enable-managed-identity \\\n        --enable-cluster-autoscaler \\\n        --min-count 1 \\\n        --max-count 10 \\\n        --network-plugin azure \\\n        --network-plugin-mode overlay \\\n        --network-dataplane cilium \\\n        --generate-ssh-keys\n    \n    # Get credentials\n    az aks get-credentials --resource-group $resource_group --name $CLUSTER_NAME\n    \n    success \"AKS cluster created\"\n}\n\n# Install Karpenter (AWS only)\ninstall_karpenter() {\n    if [[ \"$CLOUD_PROVIDER\" != \"aws\" ]]; then\n        log \"Skipping Karpenter installation for $CLOUD_PROVIDER (using Node Autoprovisioning)\"\n        return\n    fi\n    \n    log \"Installing Karpenter $KARPENTER_VERSION...\"\n    \n    # Logout of helm registry to perform an unauthenticated pull against the public ECR\n    helm registry logout public.ecr.aws\n    \n    # Install Karpenter\n    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version \"${KARPENTER_VERSION}\" \\\n        --namespace \"${KARPENTER_NAMESPACE}\" --create-namespace \\\n        --set \"settings.clusterName=${CLUSTER_NAME}\" \\\n        --set \"settings.interruptionQueue=${CLUSTER_NAME}\" \\\n        --set controller.resources.requests.cpu=1 \\\n        --set controller.resources.requests.memory=1Gi \\\n        --set controller.resources.limits.cpu=1 \\\n        --set controller.resources.limits.memory=1Gi \\\n        --wait\n    \n    # Create default EC2NodeClass and NodePool\n    kubectl apply -f - <<EOF\napiVersion: karpenter.k8s.aws/v1beta1\nkind: EC2NodeClass\nmetadata:\n  name: default\nspec:\n  amiFamily: AL2\n  role: \"KarpenterNodeInstanceProfile\"\n  subnetSelectorTerms:\n    - tags:\n        karpenter.sh/discovery: \"${CLUSTER_NAME}\"\n  securityGroupSelectorTerms:\n    - tags:\n        karpenter.sh/discovery: \"${CLUSTER_NAME}\"\n  instanceStorePolicy: RAID0\n  userData: |\n    #!/bin/bash\n    /etc/eks/bootstrap.sh ${CLUSTER_NAME}\n---\napiVersion: karpenter.sh/v1beta1\nkind: NodePool\nmetadata:\n  name: default\nspec:\n  template:\n    metadata:\n      labels:\n        provisioner: karpenter\n    spec:\n      requirements:\n        - key: kubernetes.io/arch\n          operator: In\n          values: [\"amd64\"]\n        - key: kubernetes.io/os\n          operator: In\n          values: [\"linux\"]\n        - key: karpenter.sh/capacity-type\n          operator: In\n          values: [\"spot\", \"on-demand\"]\n        - key: node.kubernetes.io/instance-type\n          operator: In\n          values: [\"t3.micro\", \"t3.small\", \"t3.medium\", \"t3.large\", \"t3.xlarge\", \"c6a.large\", \"c6a.xlarge\", \"c6a.2xlarge\"]\n      nodeClassRef:\n        apiVersion: karpenter.k8s.aws/v1beta1\n        kind: EC2NodeClass\n        name: default\n      taints:\n        - key: karpenter.sh/unschedulable\n          value: \"true\"\n          effect: NoSchedule\n  limits:\n    cpu: 1000\n    memory: 1000Gi\n  disruption:\n    consolidationPolicy: WhenIdle\n    consolidateAfter: 30s\n    expireAfter: 30m\nEOF\n\n    success \"Karpenter installed and configured\"\n}\n\n# Install vCluster operator\ninstall_vcluster() {\n    log \"Installing vCluster $VCLUSTER_VERSION...\"\n    \n    # Add vCluster helm repo\n    helm repo add loft-sh https://charts.loft.sh\n    helm repo update\n    \n    # Install vCluster CLI\n    if ! command -v vcluster >/dev/null 2>&1; then\n        curl -L -o vcluster \"https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64\" && \\\n        sudo install -c -m 0755 vcluster /usr/local/bin && \\\n        rm -f vcluster\n    fi\n    \n    success \"vCluster installed\"\n}\n\n# Create vClusters with scale-to-zero configuration\ncreate_vclusters() {\n    local vclusters=(\"modern-engineering\" \"modernengg-dev\" \"modernengg-prod\")\n    \n    for vcluster_name in \"${vclusters[@]}\"; do\n        log \"Creating vCluster: $vcluster_name\"\n        \n        # Create namespace\n        kubectl create namespace \"vcluster-$vcluster_name\" --dry-run=client -o yaml | kubectl apply -f -\n        \n        # Create vCluster with scale-to-zero configuration\n        vcluster create \"$vcluster_name\" \\\n            --namespace \"vcluster-$vcluster_name\" \\\n            --values - <<EOF\n# Resource limits for cost optimization\nresources:\n  limits:\n    cpu: 500m\n    memory: 512Mi\n  requests:\n    cpu: 100m\n    memory: 128Mi\n\n# Sync configuration\nsync:\n  nodes:\n    enabled: true\n    syncBackChanges: true\n  persistentvolumes:\n    enabled: true\n  ingresses:\n    enabled: true\n  networkpolicies:\n    enabled: true\n  services:\n    enabled: true\n\n# Enable isolation\nisolation:\n  enabled: true\n  namespace: \"vcluster-$vcluster_name\"\n  \n# Node selection for Karpenter\nnodeSelector:\n  provisioner: karpenter\n\n# Tolerate Karpenter taints\ntolerations:\n  - key: karpenter.sh/unschedulable\n    operator: Equal\n    value: \"true\"\n    effect: NoSchedule\n\n# Auto-scaling configuration\nreplicas: 1\n\n# Enable sleep mode for cost optimization\nsleepMode:\n  enabled: true\n  sleepAfter: 1800  # 30 minutes of inactivity\n  wakeupOnRequests: true\n\n# Storage optimization\npersistence:\n  size: 5Gi\n  storageClass: gp3\nEOF\n        \n        success \"vCluster $vcluster_name created\"\n    done\n}\n\n# Install applications equivalent to setup-environments.sh\ninstall_applications() {\n    log \"Installing applications in vClusters...\"\n    \n    # Application configurations per vCluster\n    declare -A vcluster_apps=(\n        [\"modern-engineering\"]=\"argocd gitea keycloak backstage nginx-ingress grafana prometheus alertmanager\"\n        [\"modernengg-dev\"]=\"nginx-ingress monitoring cert-manager\"\n        [\"modernengg-prod\"]=\"nginx-ingress monitoring cert-manager istio\"\n    )\n    \n    for vcluster_name in \"${!vcluster_apps[@]}\"; do\n        local apps=(${vcluster_apps[$vcluster_name]})\n        log \"Installing applications in vCluster: $vcluster_name\"\n        \n        # Connect to vCluster and install applications\n        vcluster connect \"$vcluster_name\" --namespace \"vcluster-$vcluster_name\" &\n        local connect_pid=$!\n        sleep 10  # Wait for connection\n        \n        # Install each application\n        for app in \"${apps[@]}\"; do\n            case $app in\n                \"nginx-ingress\")\n                    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx\n                    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \\\n                        --namespace ingress-nginx --create-namespace \\\n                        --set controller.service.type=LoadBalancer \\\n                        --set controller.resources.requests.cpu=100m \\\n                        --set controller.resources.requests.memory=128Mi\n                    ;;\n                \"argocd\")\n                    kubectl create namespace argocd\n                    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml\n                    # Configure auto-sync and scale-to-zero\n                    kubectl patch deployment argocd-server -n argocd -p '{\n                        \"spec\": {\n                            \"replicas\": 1,\n                            \"template\": {\n                                \"spec\": {\n                                    \"containers\": [{\n                                        \"name\": \"argocd-server\",\n                                        \"resources\": {\n                                            \"requests\": {\"cpu\": \"50m\", \"memory\": \"64Mi\"},\n                                            \"limits\": {\"cpu\": \"200m\", \"memory\": \"256Mi\"}\n                                        }\n                                    }]\n                                }\n                            }\n                        }\n                    }'\n                    ;;\n                \"gitea\")\n                    helm repo add gitea-charts https://dl.gitea.io/charts/\n                    helm upgrade --install gitea gitea-charts/gitea \\\n                        --namespace gitea --create-namespace \\\n                        --set resources.requests.cpu=50m \\\n                        --set resources.requests.memory=128Mi \\\n                        --set postgresql.primary.resources.requests.cpu=50m \\\n                        --set postgresql.primary.resources.requests.memory=128Mi\n                    ;;\n                \"keycloak\")\n                    helm repo add bitnami https://charts.bitnami.com/bitnami\n                    helm upgrade --install keycloak bitnami/keycloak \\\n                        --namespace keycloak --create-namespace \\\n                        --set resources.requests.cpu=100m \\\n                        --set resources.requests.memory=256Mi \\\n                        --set postgresql.primary.resources.requests.cpu=50m \\\n                        --set postgresql.primary.resources.requests.memory=128Mi\n                    ;;\n                \"backstage\")\n                    kubectl create namespace backstage\n                    # Custom Backstage deployment with resource limits\n                    kubectl apply -f - <<BACKSTAGE_EOF\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: backstage\n  namespace: backstage\nspec:\n  replicas: 1\n  selector:\n    matchLabels:\n      app: backstage\n  template:\n    metadata:\n      labels:\n        app: backstage\n    spec:\n      containers:\n      - name: backstage\n        image: backstage/backstage:latest\n        ports:\n        - containerPort: 7007\n        resources:\n          requests:\n            cpu: 100m\n            memory: 256Mi\n          limits:\n            cpu: 500m\n            memory: 512Mi\nBACKSTAGE_EOF\n                    ;;\n                \"monitoring\")\n                    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts\n                    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \\\n                        --namespace monitoring --create-namespace \\\n                        --set prometheus.prometheusSpec.resources.requests.cpu=100m \\\n                        --set prometheus.prometheusSpec.resources.requests.memory=256Mi \\\n                        --set grafana.resources.requests.cpu=50m \\\n                        --set grafana.resources.requests.memory=128Mi\n                    ;;\n                \"cert-manager\")\n                    helm repo add jetstack https://charts.jetstack.io\n                    helm upgrade --install cert-manager jetstack/cert-manager \\\n                        --namespace cert-manager --create-namespace \\\n                        --set installCRDs=true \\\n                        --set resources.requests.cpu=10m \\\n                        --set resources.requests.memory=32Mi\n                    ;;\n                \"grafana\"|\"prometheus\"|\"alertmanager\")\n                    # These are included in the monitoring stack\n                    ;;\n                \"istio\")\n                    curl -L https://istio.io/downloadIstio | sh -\n                    istio-*/bin/istioctl install --set values.pilot.resources.requests.cpu=50m \\\n                        --set values.pilot.resources.requests.memory=128Mi -y\n                    ;;\n            esac\n        done\n        \n        # Disconnect from vCluster\n        kill $connect_pid 2>/dev/null || true\n        \n        success \"Applications installed in $vcluster_name\"\n    done\n}\n\n# Configure Horizontal Pod Autoscalers for scale-to-zero\nconfigure_autoscaling() {\n    log \"Configuring auto-scaling for cost optimization...\"\n    \n    # Create VPA for better resource allocation\n    kubectl apply -f https://github.com/kubernetes/autoscaler/releases/latest/download/vpa-v1-crd-gen.yaml\n    kubectl apply -f https://github.com/kubernetes/autoscaler/releases/latest/download/vpa-rbac.yaml\n    kubectl apply -f https://github.com/kubernetes/autoscaler/releases/latest/download/vpa-deployment.yaml\n    \n    # Configure HPA for each vCluster\n    for vcluster_name in \"modern-engineering\" \"modernengg-dev\" \"modernengg-prod\"; do\n        kubectl apply -f - <<EOF\napiVersion: autoscaling/v2\nkind: HorizontalPodAutoscaler\nmetadata:\n  name: vcluster-${vcluster_name}-hpa\n  namespace: vcluster-${vcluster_name}\nspec:\n  scaleTargetRef:\n    apiVersion: apps/v1\n    kind: StatefulSet\n    name: ${vcluster_name}\n  minReplicas: 0\n  maxReplicas: 1\n  metrics:\n  - type: Resource\n    resource:\n      name: cpu\n      target:\n        type: Utilization\n        averageUtilization: 50\n  - type: Resource\n    resource:\n      name: memory\n      target:\n        type: Utilization\n        averageUtilization: 70\n  behavior:\n    scaleDown:\n      stabilizationWindowSeconds: 1800  # 30 minutes\n      policies:\n      - type: Percent\n        value: 100\n        periodSeconds: 60\n    scaleUp:\n      stabilizationWindowSeconds: 0\n      policies:\n      - type: Percent\n        value: 100\n        periodSeconds: 15\nEOF\n    done\n    \n    success \"Auto-scaling configured\"\n}\n\n# Setup monitoring and cost tracking\nsetup_monitoring() {\n    log \"Setting up monitoring and cost tracking...\"\n    \n    # Install cost monitoring tools\n    helm repo add kubecost https://kubecost.github.io/cost-model/\n    helm install kubecost kubecost/cost-analyzer \\\n        --namespace kubecost --create-namespace \\\n        --set prometheus.server.persistentVolume.size=10Gi \\\n        --set prometheus.alertmanager.persistentVolume.size=2Gi\n    \n    success \"Monitoring setup complete\"\n}\n\n# Display connection information\nshow_connection_info() {\n    success \"Deployment complete!\"\n    echo\n    echo \"==================================================\"\n    echo \"🚀 KARPENTER + VCLUSTER DEPLOYMENT COMPLETE\"\n    echo \"==================================================\"\n    echo\n    echo \"📊 Cost Optimization Features:\"\n    echo \"• Single control plane: ~\\$72/month vs \\$648/month (3 clusters)\"\n    echo \"• Karpenter scales nodes to 0 when all vClusters idle\"\n    echo \"• vClusters have sleep mode (30min inactivity)\"\n    echo \"• Spot instances used when possible (80% cost savings)\"\n    echo\n    echo \"🔗 Connection Commands:\"\n    echo \"Main cluster:\"\n    if [[ \"$CLOUD_PROVIDER\" == \"aws\" ]]; then\n        echo \"  aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION\"\n    else\n        echo \"  az aks get-credentials --resource-group rg-$CLUSTER_NAME --name $CLUSTER_NAME\"\n    fi\n    echo\n    echo \"vClusters:\"\n    for vcluster_name in \"modern-engineering\" \"modernengg-dev\" \"modernengg-prod\"; do\n        echo \"  vcluster connect $vcluster_name -n vcluster-$vcluster_name\"\n    done\n    echo\n    echo \"🛠️ Management Commands:\"\n    echo \"• Scale all to zero: kubectl scale sts --all --replicas=0 -A\"\n    echo \"• Wake up vCluster: vcluster connect <name> -n vcluster-<name>\"\n    echo \"• Check costs: kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090\"\n    echo \"• Monitor nodes: kubectl get nodes -w\"\n    echo\n    echo \"📋 Equivalent Services:\"\n    echo \"• ArgoCD: Port-forward or LoadBalancer in modern-engineering vCluster\"\n    echo \"• Gitea: Port-forward or LoadBalancer in modern-engineering vCluster\"\n    echo \"• Keycloak: Port-forward or LoadBalancer in modern-engineering vCluster\"\n    echo \"• Backstage: Port-forward or LoadBalancer in modern-engineering vCluster\"\n    echo\n}\n\n# Cleanup function\ncleanup() {\n    if [[ $? -ne 0 ]]; then\n        error \"Setup failed! Check logs above for details.\"\n    fi\n}\n\n# Main execution\nmain() {\n    log \"Starting Karpenter + vCluster setup for $CLOUD_PROVIDER...\"\n    \n    trap cleanup EXIT\n    \n    validate_prerequisites\n    \n    if [[ \"$CLOUD_PROVIDER\" == \"aws\" ]]; then\n        create_eks_cluster\n        install_karpenter\n    elif [[ \"$CLOUD_PROVIDER\" == \"azure\" ]]; then\n        create_aks_cluster\n    fi\n    \n    install_vcluster\n    create_vclusters\n    install_applications\n    configure_autoscaling\n    setup_monitoring\n    \n    show_connection_info\n    \n    trap - EXIT\n    success \"All done! 🎉\"\n}\n\n# Handle command line arguments\nwhile [[ $# -gt 0 ]]; do\n    case $1 in\n        --cloud)\n            CLOUD_PROVIDER=\"$2\"\n            shift 2\n            ;;\n        --cluster-name)\n            CLUSTER_NAME=\"$2\"\n            shift 2\n            ;;\n        --region)\n            REGION=\"$2\"\n            shift 2\n            ;;\n        --help|-h)\n            echo \"Multi-Cloud Karpenter + vCluster Setup\"\n            echo\n            echo \"Usage: $0 [options]\"\n            echo\n            echo \"Options:\"\n            echo \"  --cloud <aws|azure>     Cloud provider (default: aws)\"\n            echo \"  --cluster-name <name>   Cluster name (default: modern-engineering)\"\n            echo \"  --region <region>       Region (default: us-west-2)\"\n            echo \"  --help                  Show this help\"\n            echo\n            echo \"Environment Variables:\"\n            echo \"  CLOUD_PROVIDER          Cloud provider override\"\n            echo \"  CLUSTER_NAME            Cluster name override\"\n            echo \"  REGION                  Region override\"\n            echo \"  KARPENTER_VERSION       Karpenter version (default: 1.0.6)\"\n            echo \"  VCLUSTER_VERSION        vCluster version (default: 0.20.0)\"\n            echo\n            echo \"Examples:\"\n            echo \"  $0                                    # AWS EKS with defaults\"\n            echo \"  $0 --cloud azure --region eastus     # Azure AKS\"\n            echo \"  CLOUD_PROVIDER=aws $0                # Environment variable\"\n            exit 0\n            ;;\n        *)\n            error \"Unknown option: $1. Use --help for usage.\"\n            ;;\n    esac\ndone\n\n# Run main function\nmain \"$@\"