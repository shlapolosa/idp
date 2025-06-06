# Auto-Scaling Code-Server on AWS

**Repository**: https://github.com/shlapolosa/idp

A sophisticated, cost-optimized VSCode code-server deployment on AWS that automatically scales both horizontally (0-1 instances) and vertically (instance types) based on usage patterns. Includes optional Karpenter + vCluster setup for multi-environment Kubernetes platforms.



socrates.hlapolosa@ghdlogistics.co.za
socrates.hlapolosa@ghdlogistics.co.za

## Getting Started Guide

Choose your track based on your role and responsibilities:

### 🔗 Quick Links
- **[👨‍💼 Admin Track](#admin-track)** - Platform setup, infrastructure management, physical clusters
- **[👩‍💻 Developer Track](#developer-track)** - Development workflow, vClusters, application deployment

---

## 👨‍💼 Admin Track

**Focus**: Infrastructure setup, platform management, physical cluster operations, cost optimization

### Prerequisites

1. **AWS Account** with administrative permissions
2. **Development Machine** with required tools:
   ```bash
   # Install required tools
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip && sudo ./aws/install
   
   # Configure AWS CLI

   idp git:(main) ✗ aws configure sso

   SSO session name (Recommended): platform
   SSO start URL [None]: https://d-9a6769cefb.awsapps.com/start/
   SSO region [None]: us-east-2
   SSO registration scopes [sso:account:access]:
   Attempting to automatically open the SSO authorization page in your default browser.
   If the browser does not open or you wish to use a different device to authorize this request, open the following URL:

   aws configure
   # Enter: Access Key ID, Secret Access Key, Region (us-west-2), Output (json)
   ```

3. **Verify Prerequisites**:
   ```bash
   aws --version          # AWS CLI v2.x
   aws sts get-caller-identity  # Verify credentials
   ```

### Step 1: Deploy IDP Infrastructure

1. **Clone Repository**:
   ```bash
   git clone https://github.com/shlapolosa/idp.git
   cd idp
   ```

2. **Choose Deployment Option**:

   **Option A: Code-Server Only (Individual/Learning)**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   
   # Wait 30-60 minutes for completion
   # Access VSCode at provided CloudFront URL
   # Password: Your AWS Account ID
   ```

   **Option B: Full Platform (Team/Production)**
   ```bash
   chmod +x setup-karpenter-vclusters.sh
   ./setup-karpenter-vclusters.sh --cloud aws --region us-west-2
   
   # Wait 60-90 minutes for completion
   ```

### Step 2: Verify Infrastructure

1. **Check Cluster Status**:
   ```bash
   # Verify main EKS cluster
   aws eks describe-cluster --name modern-engineering --region us-west-2
   
   # Check cluster nodes
   kubectl get nodes -o wide
   
   # Verify Karpenter
   kubectl get nodepool
   kubectl get ec2nodeclass
   ```

2. **Verify vClusters** (Option B only):
   ```bash
   # List vClusters
   vcluster list
   
   # Check vCluster pods
   kubectl get pods -A | grep vcluster
   ```

### Step 3: Configure Access Management

1. **Setup Kubeconfig Management**:
   ```bash
   # Initialize kubeconfig manager
   ./kubeconfig-vault-manager.sh setup modern-engineering us-west-2
   
   # Verify context switching
   kctx_list
   ```

2. **Test Context Switching**:
   ```bash
   # Switch to main cluster
   engineering
   kubectl get nodes
   
   # Switch to management vCluster
   mgmt
   kubectl get pods -A
   ```

### Step 4: Monitor Platform Health

1. **Access Monitoring Tools**:
   ```bash
   # Port-forward to Kubecost (cost monitoring)
   kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090
   # Open: http://localhost:9090
   
   # Check platform services
   kubectl get svc -A | grep LoadBalancer
   ```

2. **Cost Optimization Verification**:
   ```bash
   # Check Karpenter scaling
   kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter
   
   # Monitor node utilization
   kubectl top nodes
   
   # Check vCluster resource usage
   kubectl top pods -A | grep vcluster
   ```

### Step 5: Platform Administration

1. **Manage vCluster Lifecycle**:
   ```bash
   # Scale down vCluster for maintenance
   kubectl scale sts modern-engineering -n vcluster-modern-engineering --replicas=0
   
   # Scale up vCluster
   kubectl scale sts modern-engineering -n vcluster-modern-engineering --replicas=1
   
   # Wake up sleeping vCluster
   vcluster connect modern-engineering -n vcluster-modern-engineering
   ```

2. **Platform Secrets Management**:
   ```bash
   # View platform URLs (stored in SSM)
   aws ssm get-parameter --name "ArgoCDURL"
   aws ssm get-parameter --name "GiteaURL"
   aws ssm get-parameter --name "KeycloakURL"
   
   # Retrieve platform passwords
   aws ssm get-parameter --name "ArgoCDPW" --with-decryption
   ```

### Step 6: Advanced Administration

1. **Enable Vault Integration** (Optional):
   ```bash
   # Setup Vault for enhanced security
   export VAULT_ENABLED=true
   export VAULT_ADDR="https://your-vault-instance.com"
   export VAULT_TOKEN="your-vault-token"
   
   ./kubeconfig-vault-manager.sh setup
   ```

2. **Implement Cost Controls**:
   ```bash
   # Set resource quotas per vCluster
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: compute-quota
     namespace: vcluster-modernengg-dev
   spec:
     hard:
       requests.cpu: "4"
       requests.memory: 8Gi
       limits.cpu: "8"
       limits.memory: 16Gi
   EOF
   ```

3. **Setup Automated Backups**:
   ```bash
   # Backup all kubeconfigs
   ./kubeconfig-vault-manager.sh backup
   
   # Setup scheduled backups
   echo "0 2 * * * /path/to/kubeconfig-vault-manager.sh backup" | crontab -
   ```

---

## 👩‍💻 Developer Track

**Focus**: Application development, vCluster usage, ArgoCD workflows, GitOps practices

### Prerequisites

1. **Platform Access**: Ensure admin has deployed the infrastructure
2. **Development Tools**:
   ```bash
   # Install kubectl
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   
   # Install vCluster CLI
   curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64"
   sudo install -c -m 0755 vcluster /usr/local/bin
   
   # Install ArgoCD CLI
   curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
   sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
   ```

3. **Get Platform URLs** from admin:
   ```bash
   # Get from admin or retrieve from SSM
   export ARGOCD_URL="https://your-platform-dns/argocd"
   export GITEA_URL="https://your-platform-dns/gitea"
   export BACKSTAGE_URL="https://your-platform-dns/"
   ```

### Step 1: Access Development Environment

1. **Get Kubeconfig from Admin**:
   ```bash
   # Request admin to share vCluster access
   # OR if you have main cluster access:
   vcluster connect modernengg-dev -n vcluster-modernengg-dev
   ```

2. **Setup Context Switching**:
   ```bash
   # Download kubeconfig manager (if not available)
   curl -fsSL https://raw.githubusercontent.com/shlapolosa/idp/main/kubeconfig-vault-manager.sh -o kubeconfig-vault-manager.sh
   chmod +x kubeconfig-vault-manager.sh
   
   # Source helper functions
   source ~/.bashrc_kubeconfig
   ```

3. **Test vCluster Access**:
   ```bash
   # Switch to dev environment
   dev
   kubectl get namespaces
   
   # Switch to prod environment  
   prod
   kubectl get namespaces
   
   # Switch to management/ArgoCD
   mgmt
   kubectl get pods -n argocd
   ```

### Step 2: Setup Development Workflow

1. **Access ArgoCD**:
   ```bash
   # Connect to management vCluster
   mgmt
   
   # Get ArgoCD admin password
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   
   # Port-forward ArgoCD UI
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # Open: https://localhost:8080
   # Login: admin / <password from above>
   ```

2. **Setup Git Repository**:
   ```bash
   # Access Gitea for source control
   # URL provided by admin: https://your-platform-dns/gitea
   # Default credentials: giteaAdmin / mysecretgiteapassword!
   
   # Clone sample application
   git clone https://github.com/shlapolosa/idp.git sample-app
   cd sample-app
   ```

3. **Configure ArgoCD CLI**:
   ```bash
   # Login to ArgoCD
   argocd login localhost:8080 --username admin --password <argocd-password> --insecure
   
   # List applications
   argocd app list
   ```

### Step 3: Deploy Your First Application

1. **Create Kubernetes Manifests**:
   ```bash
   mkdir -p k8s-manifests
   cat > k8s-manifests/deployment.yaml << EOF
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: sample-app
     namespace: default
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: sample-app
     template:
       metadata:
         labels:
           app: sample-app
       spec:
         containers:
         - name: sample-app
           image: nginx:latest
           ports:
           - containerPort: 80
           resources:
             requests:
               cpu: 50m
               memory: 64Mi
             limits:
               cpu: 100m
               memory: 128Mi
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: sample-app-service
     namespace: default
   spec:
     selector:
       app: sample-app
     ports:
     - port: 80
       targetPort: 80
     type: ClusterIP
   EOF
   ```

2. **Deploy to Development**:
   ```bash
   # Switch to dev vCluster
   dev
   
   # Apply manifests directly
   kubectl apply -f k8s-manifests/
   
   # Verify deployment
   kubectl get pods
   kubectl get svc
   ```

3. **Setup GitOps with ArgoCD**:
   ```bash
   # Push to Gitea
   git add .
   git commit -m "Add sample application manifests"
   git push origin main
   
   # Switch to management for ArgoCD
   mgmt
   
   # Create ArgoCD application
   argocd app create sample-app \
     --repo https://your-gitea-url/username/sample-app.git \
     --path k8s-manifests \
     --dest-server https://kubernetes.default.svc \
     --dest-namespace default
   
   # Sync application
   argocd app sync sample-app
   ```

### Step 4: Environment Promotion Workflow

1. **Deploy to Development**:
   ```bash
   # Create dev-specific configuration
   mkdir -p environments/dev
   cp k8s-manifests/* environments/dev/
   
   # Modify for dev (e.g., reduce replicas)
   sed -i 's/replicas: 2/replicas: 1/' environments/dev/deployment.yaml
   
   # Create ArgoCD app for dev
   mgmt
   argocd app create sample-app-dev \
     --repo https://your-gitea-url/username/sample-app.git \
     --path environments/dev \
     --dest-server https://vcluster-modernengg-dev.default.svc \
     --dest-namespace default
   ```

2. **Promote to Production**:
   ```bash
   # Create prod configuration
   mkdir -p environments/prod
   cp k8s-manifests/* environments/prod/
   
   # Modify for prod (e.g., increase replicas, add resource limits)
   sed -i 's/replicas: 2/replicas: 3/' environments/prod/deployment.yaml
   
   # Create ArgoCD app for prod
   argocd app create sample-app-prod \
     --repo https://your-gitea-url/username/sample-app.git \
     --path environments/prod \
     --dest-server https://vcluster-modernengg-prod.default.svc \
     --dest-namespace default
   ```

### Step 5: Monitor and Debug Applications

1. **Application Monitoring**:
   ```bash
   # Check application status across environments
   dev && kubectl get pods -l app=sample-app
   prod && kubectl get pods -l app=sample-app
   
   # View application logs
   dev && kubectl logs -l app=sample-app --tail=50
   
   # Check resource usage
   kubectl top pods -l app=sample-app
   ```

2. **ArgoCD Monitoring**:
   ```bash
   # Monitor deployment status
   mgmt
   argocd app get sample-app-dev
   argocd app get sample-app-prod
   
   # View sync history
   argocd app history sample-app-dev
   ```

3. **Debug Common Issues**:
   ```bash
   # Check vCluster connectivity
   vcluster list
   
   # Verify vCluster is running
   kubectl get pods -n vcluster-modernengg-dev
   
   # Check resource quotas
   dev && kubectl describe quota
   
   # View events for troubleshooting
   kubectl get events --sort-by=.metadata.creationTimestamp
   
   # Check Claude Code status (if installed)
   claude --version
   claude mcp list
   
   # Test remote context7 connection
   curl -I https://mcp.context7.com/sse
   
   # Re-authenticate if needed
   claude auth
   ```

### Step 6: Advanced Development Patterns

1. **Feature Branch Workflow**:
   ```bash
   # Create feature branch
   git checkout -b feature/new-functionality
   
   # Modify application
   # ... make changes ...
   
   # Deploy to dev for testing
   git add . && git commit -m "Add new functionality"
   git push origin feature/new-functionality
   
   # Create temporary ArgoCD app for feature testing
   argocd app create sample-app-feature \
     --repo https://your-gitea-url/username/sample-app.git \
     --revision feature/new-functionality \
     --path environments/dev \
     --dest-server https://vcluster-modernengg-dev.default.svc \
     --dest-namespace feature-test
   ```

2. **Database Integration**:
   ```bash
   # Deploy PostgreSQL in dev
   dev
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm install postgresql bitnami/postgresql \
     --set auth.postgresPassword=devpassword \
     --set primary.resources.requests.cpu=50m \
     --set primary.resources.requests.memory=128Mi
   ```

3. **Secrets Management**:
   ```bash
   # Create development secrets
   dev
   kubectl create secret generic app-secrets \
     --from-literal=database-url="postgresql://postgres:devpassword@postgresql:5432/postgres"
   
   # Reference in deployment
   # Add to deployment.yaml:
   # env:
   # - name: DATABASE_URL
   #   valueFrom:
   #     secretKeyRef:
   #       name: app-secrets
   #       key: database-url
   ```

### Quick Reference Commands

```bash
# Context Switching
engineering  # Main physical cluster
dev          # Development vCluster  
prod         # Production vCluster
mgmt         # Management vCluster (ArgoCD)

# Status Checks
kctx         # Show current context
kctx_list    # List all contexts
kubectl get nodes  # Cluster nodes
kubectl get pods -A  # All pods

# ArgoCD Operations
argocd app list              # List applications
argocd app sync <app-name>   # Sync application
argocd app get <app-name>    # Get application details

# vCluster Operations
vcluster list                # List vClusters
vcluster connect <name> -n vcluster-<name>  # Connect to vCluster

# Claude Code Operations (if API key provided)
claude                       # Start Claude Code CLI
claude mcp list              # List configured MCP servers
claude mcp add --transport sse context7 https://mcp.context7.com/sse  # Add context7 server
claude auth                  # Authenticate with Anthropic API
```

---

## Architecture Overview

![Architecture Diagram](https://via.placeholder.com/800x600/2E3440/88C0D0?text=Auto-Scaling+Code-Server+Architecture)

### Core Components

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   CloudFront    │────│  Lambda@Edge     │────│ Auto Scaling    │
│   Distribution  │    │  (Origin Req)    │    │ Group (0-1)     │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                       │                       │
         │              ┌────────▼────────┐              │
         │              │ Instance Type   │              │
         │              │ Scaler Lambda   │              │
         │              └─────────────────┘              │
         │                       ▲                       │
         │              ┌────────┴────────┐              │
         │              │   CloudWatch    │              │
         │              │     Alarms      │              │
         │              └─────────────────┘              │
         │                                               │
         └───────────────────────────────────────────────▼
                         ┌─────────────────┐
                         │  EC2 Instance   │
                         │  (VSCode Server)│
                         └─────────────────┘
```

## CloudFormation Script Components

### 1. **Networking Infrastructure**
- **VPC**: 10.0.0.0/16 with public/private subnets
- **Security Groups**: CloudFront-only access (port 80)
- **Internet Gateway**: Public internet access

### 2. **Compute Resources**

#### Auto Scaling Group
- **Min/Max/Desired**: 0/1/0 (starts with zero instances)
- **Multi-AZ**: Spans two availability zones
- **Health Checks**: EC2 health checks with 5-minute grace period

#### Launch Templates (3 Tiers)
| Tier | Instance Type | vCPU | RAM | Use Case | Cost/Month* |
|------|---------------|------|-----|----------|-------------|
| 1 | t3.micro | 1 | 1GB | Light coding | $9 |
| 2 | t3.small | 2 | 2GB | Medium workload | $17 |
| 3 | c6a.large | 2 | 4GB | Heavy builds | $62 |

*After free tier, if running 24/7

### 3. **Scaling Logic**

#### Horizontal Scaling (0 ↔ 1 Instance)
```javascript
// Lambda@Edge triggers on CloudFront requests
if (no_instances_running) {
    scale_asg_to_1_instance();
    wait_for_instance_ready(max_3_minutes);
    route_traffic_to_instance();
}
```

#### Vertical Scaling (Instance Type)
```python
# CloudWatch Alarms trigger SNS → Lambda
if cpu_usage > 75% for 10_minutes:
    upgrade_to_next_tier()
elif cpu_usage < 20% for 30_minutes:
    downgrade_to_lower_tier()
```

#### Auto-Shutdown
```bash
# Runs every 5 minutes on instance
if no_ssh_sessions AND no_vscode_access AND cpu < 5%:
    shutdown_in_30_seconds()
```

### 4. **Content Delivery**

#### CloudFront Distribution
- **Global CDN**: Edge locations worldwide
- **Lambda@Edge**: Origin request processing
- **Security**: CloudFront prefix lists for instance access
- **Caching**: Optimized for development workflow

### 5. **Monitoring & Alerting**

#### CloudWatch Alarms
- **High CPU**: >75% for 2 evaluation periods (10 minutes)
- **Low CPU**: <20% for 6 evaluation periods (30 minutes)
- **Metrics**: CPU utilization per Auto Scaling Group

#### SNS Topics
- **High CPU Topic**: Triggers scale-up Lambda
- **Low CPU Topic**: Triggers scale-down Lambda

### 6. **Lambda Functions**

#### VSCode Scaler (Lambda@Edge)
- **Runtime**: Python 3.11
- **Timeout**: 30 seconds
- **Purpose**: Scale ASG from 0→1 and route traffic
- **Triggers**: CloudFront origin requests

#### Instance Type Scaler
- **Runtime**: Python 3.11  
- **Timeout**: 5 minutes
- **Purpose**: Change instance types based on load
- **Triggers**: CloudWatch alarms via SNS

## Scaling Behavior

### Startup Sequence (Cold Start)
1. User visits CloudFront URL
2. Lambda@Edge detects no running instances
3. Scales ASG desired capacity to 1 (Tier 1)
4. Waits up to 3 minutes for instance to be ready
5. Routes traffic to running instance
6. **Total time**: 3-5 minutes

### Scale-Up Sequence (Vertical)
1. Instance under high load (CPU >75%)
2. CloudWatch alarm triggers after 10 minutes
3. SNS notification to scaling Lambda
4. Lambda updates ASG launch template to next tier
5. Current instance terminates, new tier instance launches
6. **Downtime**: 2-3 minutes during transition

### Scale-Down Sequence (Vertical)
1. Instance under low load (CPU <20%) for 30 minutes
2. CloudWatch alarm triggers scaling Lambda
3. Lambda downgrades to lower tier
4. Instance replacement with smaller instance
5. **Downtime**: 2-3 minutes during transition

### Shutdown Sequence (Horizontal)
1. No activity detected for 5 minutes
2. Auto-shutdown script initiates 30-second countdown
3. Instance terminates
4. ASG desired capacity remains 1 (will restart on next access)
5. **Cost**: $0 while shut down

## Security Features

### Network Security
- **CloudFront Only**: Instances only accept traffic from CloudFront edge locations
- **No Direct Access**: Instances not directly accessible from internet
- **VPC Isolation**: Private networking with controlled egress

### Access Control
- **Password Protected**: Uses AWS Account ID as password
- **HTTPS Enforcement**: CloudFront provides SSL termination
- **Session Management**: VSCode server handles user sessions

### IAM Security
- **Least Privilege**: Lambda functions have minimal required permissions
- **Instance Profile**: EC2 instances have controlled AWS API access
- **Resource Isolation**: Each component has specific IAM roles

## Usage & Cost Estimates

### AWS Free Tier Eligibility
- **EC2**: 750 hours/month of t3.micro (Tier 1)
- **EBS**: 30GB storage included
- **CloudFront**: 1TB data transfer, 10M requests
- **Lambda**: 1M requests, 400K GB-seconds

### Cost Scenarios (After Free Tier)

#### Scenario 1: Light Developer (8 hours/day)
- **Usage**: ~240 hours/month, mostly Tier 1
- **Estimated Cost**: $3-5/month
- **Breakdown**: $2.40 compute + $3 storage + $0.50 CloudFront

#### Scenario 2: Heavy Developer (12 hours/day)
- **Usage**: ~360 hours/month, 70% Tier 1, 30% Tier 2
- **Estimated Cost**: $8-12/month
- **Breakdown**: $8 compute + $3 storage + $1 CloudFront

#### Scenario 3: Team Environment (24/7 with auto-scaling)
- **Usage**: 720 hours/month, mixed tiers
- **Estimated Cost**: $15-25/month
- **Breakdown**: $20 compute + $3 storage + $2 CloudFront

## Operations Guide

### Starting the Environment

#### First-Time Deployment

**Clone Repository:**
```bash
git clone https://github.com/shlapolosa/idp.git
cd idp
```

**Simple One-Command Deployment:**
```bash
# Make deployment script executable and run
chmod +x deploy.sh
./deploy.sh
```

**Deployment with Claude Code Integration:**
```bash
# Set your Anthropic API key and deploy
export ANTHROPIC_API_KEY="your-api-key-here"
chmod +x deploy.sh
./deploy.sh
```

**Validation Before Deployment:**
```bash
# Validate template and parameters without deploying
./deploy.sh --dry-run

# Deploy with custom configuration
./deploy.sh --stack-name my-dev-env --region us-east-1
```

**Karpenter + vCluster Setup (Alternative):**
```bash
# For cost-optimized multi-environment Kubernetes platform
chmod +x setup-karpenter-vclusters.sh

# AWS EKS
./setup-karpenter-vclusters.sh --cloud aws

# Azure AKS  
./setup-karpenter-vclusters.sh --cloud azure --region eastus
```

**Manual Deployment (Advanced):**
```bash
# Create S3 bucket for CloudFormation staging
templateBucket=$(aws s3api create-bucket \
    --bucket cf-templates-$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]' | cut -c1-8)-us-west-2 \
    --region us-west-2 \
    --create-bucket-configuration LocationConstraint=us-west-2 \
    --query 'Location' \
    --output text | sed 's|http://||' | sed 's|.s3.amazonaws.com/||')

# Deploy CloudFormation stack
aws cloudformation deploy \
  --stack-name modern-engineering-workshop \
  --template-file modern-engineering-workshop.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --s3-bucket $templateBucket \
  --parameter-overrides AtAnAWSEvent=false

# Get outputs
aws cloudformation describe-stacks \
  --stack-name modern-engineering-workshop \
  --query 'Stacks[0].Outputs'
```

**Why These Components Are Needed:**

1. **S3 Bucket**: CloudFormation templates >51KB must be stored in S3 (our template is ~130KB due to embedded Lambda code)
2. **CAPABILITY_NAMED_IAM**: Allows CloudFormation to create IAM roles with specific names (security requirement)
3. **Staging Process**: Large templates with inline Lambda functions require S3 staging

#### Starting After Shutdown
1. **Automatic**: Simply visit the CloudFront URL
2. **Manual**: Scale ASG desired capacity to 1
```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name code-server-env-vscode-asg \
  --desired-capacity 1
```

### Stopping the Environment

#### Immediate Shutdown
```bash
# Scale down to 0 instances
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name code-server-env-vscode-asg \
  --desired-capacity 0
```

#### Scheduled Shutdown
```bash
# Create scheduled action to shutdown at 6 PM daily
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name code-server-env-vscode-asg \
  --scheduled-action-name evening-shutdown \
  --recurrence "0 18 * * *" \
  --desired-capacity 0
```

### Monitoring & Troubleshooting

#### Check Instance Status
```bash
# View ASG instances
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names code-server-env-vscode-asg

# Check CloudWatch alarms
aws cloudwatch describe-alarms \
  --alarm-names code-server-env-HighCPU code-server-env-LowCPU
```

#### View Logs
```bash
# Lambda@Edge logs (check multiple regions)
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/us-east-1.code-server-env-vscode-scaler

# Instance logs via SSM
aws ssm start-session --target i-1234567890abcdef0
```

#### Manual Tier Override
```bash
# Force specific instance type
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name code-server-env-vscode-asg \
  --launch-template LaunchTemplateId=lt-tier3,Version='$Latest'
```

## Installed Development Tools

### Runtime Environments
- **Node.js**: v20.x with npm
- **Python**: 3.11 with pip3, virtual environment support
- **Java**: OpenJDK 8 & 17 with jenv for version management
- **Go**: Latest stable version
- **Rust**: Latest stable with Cargo
- **.NET**: SDK 8.0 with global tools

### Container & Orchestration
- **Docker**: Latest CE with Docker Compose
- **Kubernetes**: kubectl with bash completion
- **eksctl**: EKS cluster management
- **Helm**: Package manager for Kubernetes
- **Kustomize**: Kubernetes configuration management

### Cloud & Infrastructure
- **AWS CLI**: v2 with SSO support
- **CDK**: AWS Cloud Development Kit
- **Terraform**: Infrastructure as Code
- **K9s**: Kubernetes cluster management UI

### Development Tools
- **Git**: Latest with default configuration
- **VSCode Extensions**:
  - Amazon Q (AI assistant)
  - Java Extension Pack
  - Live Server for web development
  - Auto-run command on startup
- **Claude Code**: Official Anthropic CLI for AI coding assistance (if API key provided)
- **Context7**: Remote MCP server for intelligent code understanding and search
- **yq**: YAML processor
- **jq**: JSON processor (system default)

### Kubeconfig & Secret Management
- **Multi-cluster kubeconfig management** with context switching
- **HashiCorp Vault integration** for secure credential storage
- **Automated kubeconfig backup** and restoration
- **Context aliases**: `engineering`, `dev`, `prod`, `mgmt`
- **Platform secrets storage** in Vault or AWS SSM

### Code-Server Configuration
- **Port**: 3000 (internal)
- **Authentication**: Password (AWS Account ID)
- **Home Directory**: Configurable (default: /Workshop)
- **Settings**: 
  - Telemetry disabled
  - Workspace trust disabled
  - Python testing with pytest enabled
  - Auto-terminal on startup

### Nginx Configuration
- **Proxy**: code-server on port 3000
- **Additional Route**: Custom development server on configurable port
- **SSL**: Handled by CloudFront
- **Access Logs**: Used for activity monitoring

### System Services
- **code-server**: Runs as systemd service for user 'ubuntu'
- **auto-shutdown**: Custom service monitoring activity
- **docker**: Enabled and running
- **nginx**: Reverse proxy for code-server

## Architecture Benefits

### Cost Optimization
- **True Zero Cost**: No charges when not in use
- **Right-Sizing**: Automatic instance type optimization
- **Free Tier Maximization**: Starts with free-tier eligible resources

### Performance
- **Global Access**: CloudFront edge locations
- **Auto-Scaling**: Responds to load automatically  
- **Fast Startup**: 3-5 minute cold start time

### Reliability
- **Multi-AZ**: High availability across zones
- **Health Checks**: Automatic instance replacement
- **Graceful Scaling**: Minimal downtime during transitions

### Developer Experience
- **Instant Access**: Single URL, no server management
- **Full Development Environment**: All tools pre-installed
- **Persistent Storage**: EBS volumes maintain data
- **Modern IDE**: Full VSCode experience in browser

## Kubeconfig & Secret Management

### Enhanced Kubeconfig Handling

The current implementation provides sophisticated kubeconfig management that addresses the limitations of the original script:

#### **Original Script Issues:**
- Single kubeconfig file with all clusters
- Plain text storage with `chmod 777` permissions
- No encryption or secure backup
- Manual context switching with aliases

#### **Enhanced Implementation:**
- **Separate kubeconfig files** per cluster/vCluster
- **Vault integration** for encrypted storage
- **Automated backup** and restoration
- **Smart context switching** with helper functions

### Kubeconfig Structure

```bash
~/.kube/
├── config                          # Main EKS cluster
├── modern-engineering-vcluster.yaml # Management vCluster
├── modernengg-dev-vcluster.yaml    # Dev vCluster
├── modernengg-prod-vcluster.yaml   # Prod vCluster
└── backups/                        # Timestamped backups
    ├── config_20240601_120000
    └── *.yaml_20240601_120000
```

### Context Switching Commands

```bash
# Quick aliases (automatically configured)
engineering  # Main EKS cluster
dev          # Dev vCluster  
prod         # Prod vCluster
mgmt         # Management vCluster

# Function-based switching
use_main                              # Main cluster
use_vcluster modernengg-dev          # Dev vCluster
use_vcluster modernengg-prod         # Prod vCluster
use_vcluster modern-engineering      # Management vCluster

# Context information
kctx         # Show current context
kctx_list    # List all available contexts
```

### Vault Integration

#### **Setup Vault (Optional)**
```bash
# Enable Vault integration
export VAULT_ENABLED=true
export VAULT_ADDR="https://vault.example.com"
export VAULT_TOKEN="your-vault-token"

# Initialize Vault storage
./kubeconfig-vault-manager.sh setup
```

#### **Vault Storage Structure**
```
secret/kubeconfigs/
├── modern-engineering              # Main cluster config
├── vcluster-modern-engineering     # Management vCluster
├── vcluster-modernengg-dev        # Dev vCluster
└── vcluster-modernengg-prod       # Prod vCluster

secret/platform/
├── urls/                          # Service URLs
│   ├── argocd
│   ├── gitea
│   ├── keycloak
│   └── backstage
└── credentials/                   # Platform passwords
    ├── argocd_admin_password
    ├── gitea_admin_password
    └── keycloak_admin_password
```

#### **Vault Operations**
```bash
# Store kubeconfig in Vault
./kubeconfig-vault-manager.sh store modern-engineering ~/.kube/config

# Retrieve from Vault
./kubeconfig-vault-manager.sh retrieve modern-engineering

# List stored configs
./kubeconfig-vault-manager.sh list

# Restore from Vault in shell
restore_from_vault modern-engineering
```

### Security Improvements

1. **File Permissions**: `600` (owner read/write only)
2. **Encrypted Storage**: Base64 + Vault encryption at rest
3. **Automated Backup**: Timestamped backups before changes
4. **Access Control**: Vault RBAC and token-based access
5. **Audit Trail**: Vault audit logs for all access

### Migration from Original Script

The enhanced system automatically:
1. **Backs up existing** kubeconfigs
2. **Migrates contexts** to separate files
3. **Creates switching functions** for compatibility
4. **Stores in Vault** if enabled

### Platform Secret Management

#### **AWS SSM (Default)**
```bash
# URLs stored in SSM Parameters
aws ssm get-parameter --name "ArgoCDURL"
aws ssm get-parameter --name "GiteaURL"
aws ssm get-parameter --name "KeycloakURL"

# Passwords stored securely
aws ssm get-parameter --name "ArgoCDPW" --with-decryption
```

#### **Vault (Enhanced)**
```bash
# Retrieve platform URLs
vault kv get secret/platform/urls

# Retrieve credentials
vault kv get secret/platform/credentials
```

## Customization Options

### Instance Configuration
- Modify `InstanceVolumeSize` parameter (default: 30GB)
- Change scaling thresholds in CloudWatch alarms
- Adjust auto-shutdown timing in user data

### Development Environment
- Add tools to launch template user data
- Configure additional VSCode extensions
- Set up custom development server routes

### Scaling Behavior
- Modify CPU thresholds for tier changes
- Add memory-based scaling triggers
- Implement custom scaling metrics

### Kubeconfig Management
- Enable/disable Vault integration with `VAULT_ENABLED`
- Customize Vault paths with `VAULT_PATH_PREFIX`
- Configure backup retention in `BACKUP_DIR`

### Claude Code Integration
- Set `ANTHROPIC_API_KEY` environment variable before deployment
- Claude Code automatically installed and configured if API key is provided
- Access via terminal: `claude` command available
- Official Anthropic Claude Code CLI with authentication
- Uses Claude 3.5 Sonnet model for coding assistance

### Context7 Remote MCP Server Integration
- Manual configuration required after Claude Code installation
- Uses remote context7 server at `https://mcp.context7.com/sse`
- No local installation required - connects to hosted service
- Configure with: `claude mcp add --transport sse context7 https://mcp.context7.com/sse`
- Integrates with Claude via MCP (Model Context Protocol) using SSE transport
- Features include:
  - **Code Search**: Semantic search across your codebase
  - **File Analysis**: Deep understanding of file relationships
  - **Context Extraction**: Intelligent code context for Claude
  - **Project Mapping**: Automatic project structure analysis
  - **Remote Processing**: Leverages cloud-based analysis for better performance

This architecture provides a production-ready, cost-effective development environment that scales automatically based on usage patterns while maintaining the developer experience of a full-featured IDE and enterprise-grade secret management.