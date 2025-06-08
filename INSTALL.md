# IDP Installation Guide

## 🚀 Choose Your Track

This guide provides quick installation steps. For comprehensive step-by-step instructions, see the **[Getting Started Guide in README.md](README.md#getting-started-guide)**:

- **[👨‍💼 Admin Track](README.md#admin-track)** - Infrastructure setup, platform management
- **[👩‍💻 Developer Track](README.md#developer-track)** - Development workflow, GitOps with ArgoCD

## Quick Start

```bash
# Clone the repository
git clone https://github.com/shlapolosa/idp.git
cd idp

# Option 1: Auto-scaling Code-Server (recommended for individual developers)
chmod +x deploy.sh
./deploy.sh

# Option 1a: Validate before deploying
./deploy.sh --dry-run

# Option 1b: With Claude Code Integration
export ANTHROPIC_API_KEY="your-api-key-here"
./deploy.sh --stack-name modern-engineering-workshop --region us-east-1

# Option 2: Karpenter + vCluster Platform (recommended for teams)
chmod +x setup-karpenter-vclusters.sh
./setup-karpenter-vclusters.sh --cloud aws
```

## Architecture Options

### Option 1: Auto-Scaling Code-Server

**Best for**: Individual developers, learning, small projects

**Features**:
- VSCode in browser with auto-scaling EC2 instances
- Scale to zero when idle (no cost when not in use)
- Auto-scales instance types based on CPU usage
- CloudFront distribution for global access
- Claude Code with remote context7 MCP server (if API key provided)

**Cost**: $0 when idle, $3-25/month when used (depending on usage)

### Option 2: Karpenter + vCluster Platform  

**Best for**: Teams, multi-environment development, production workloads

**Features**:
- Single EKS cluster with 3 virtual clusters (dev/staging/prod)
- Karpenter for intelligent node scaling (scale to zero)
- Full platform tools: ArgoCD, Gitea, Keycloak, Backstage
- 89% cost reduction vs separate clusters

**Cost**: $72/month control plane + compute costs (scales to zero)

## Prerequisites

### Common Requirements
- AWS CLI installed and configured
- Git installed

### Option 1 (Code-Server) Requirements
```bash
aws --version
git --version
```

### Option 2 (Karpenter) Additional Requirements
```bash
kubectl version --client
helm version
eksctl version  # for AWS
az version     # for Azure
```

## Installation Steps

### Auto-Scaling Code-Server

1. **Deploy Infrastructure**:
   ```bash
   ./deploy.sh
   ```

2. **Wait for Completion** (30-60 minutes):
   - CloudFormation stack creation
   - Instance initialization
   - Tool installation

3. **Access VSCode**:
   - URL provided in deployment output
   - Password: Your AWS Account ID

### Karpenter + vCluster Platform

1. **Deploy Cluster**:
   ```bash
   ./setup-karpenter-vclusters.sh --cloud aws
   ```

2. **Wait for Completion** (45-90 minutes):
   - EKS cluster creation
   - Karpenter installation
   - vCluster setup
   - Application deployment

3. **Access Services**:
   ```bash
   # Connect to vClusters
   vcluster connect modern-engineering -n vcluster-modern-engineering
   vcluster connect modernengg-dev -n vcluster-modernengg-dev
   vcluster connect modernengg-prod -n vcluster-modernengg-prod
   ```

## Configuration Options

### Environment Variables

```bash
# Code-Server options
export STACK_NAME="my-code-server"
export REGION="us-west-2"

# Claude Code integration (optional)
export ANTHROPIC_API_KEY="your-api-key-here"

# Karpenter options  
export CLUSTER_NAME="my-platform"
export CLOUD_PROVIDER="aws"  # or "azure"
export KARPENTER_VERSION="1.0.6"
```

### Custom Parameters

```bash
# Code-Server with custom instance type
./deploy.sh --stack-name dev-environment

# Karpenter with custom region
./setup-karpenter-vclusters.sh --cloud aws --region us-east-1 --cluster-name team-platform
```

## Verification

### Code-Server Health Check
```bash
# Check CloudFormation stack
aws cloudformation describe-stacks --stack-name modern-engineering-workshop

# Check Auto Scaling Group
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names modern-engineering-workshop-vscode-asg

# Verify Claude Code and Context7 (if API key was provided)
# SSH into instance and check:
claude --version
claude mcp list
curl -I https://mcp.context7.com/sse
```

### Karpenter Platform Health Check
```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Check vClusters
vcluster list

# Check Karpenter
kubectl get nodepool
kubectl get ec2nodeclass
```

## Troubleshooting

### Common Issues

1. **AWS CLI not configured**:
   ```bash
   aws configure
   # or
   aws configure sso
   ```

2. **Insufficient permissions**:
   - Attach `PowerUserAccess` policy to your IAM user
   - Or use `AdministratorAccess` for full access

3. **CloudFormation template too large**:
   - Script automatically handles S3 bucket creation
   - Ensure you have S3 permissions

4. **Karpenter installation fails**:
   ```bash
   # Check prerequisites
   eksctl version
   helm version
   
   # Verify cluster access
   kubectl get nodes
   ```

### Getting Help

1. **Check logs**:
   ```bash
   # CloudFormation events
   aws cloudformation describe-stack-events --stack-name modern-engineering-workshop
   
   # SSM execution logs
   aws ssm describe-instance-information
   ```

2. **GitHub Issues**:
   - Report issues: https://github.com/shlapolosa/idp/issues
   - Check existing solutions

3. **AWS Documentation**:
   - [Karpenter Getting Started](https://karpenter.sh/docs/getting-started/)
   - [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)

## Cleanup

### Code-Server Cleanup
```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name modern-engineering-workshop

# Delete S3 bucket (if needed)
aws s3 rb s3://your-bucket-name --force
```

### Karpenter Platform Cleanup
```bash
# Delete vClusters
vcluster delete modern-engineering -n vcluster-modern-engineering
vcluster delete modernengg-dev -n vcluster-modernengg-dev  
vcluster delete modernengg-prod -n vcluster-modernengg-prod

# Delete EKS cluster
eksctl delete cluster --name modern-engineering

# Delete CloudFormation stack (if created)
aws cloudformation delete-stack --stack-name Karpenter-modern-engineering
```

## Next Steps

After successful installation:

1. **Configure your development environment**
2. **Set up CI/CD pipelines** (if using Karpenter platform)
3. **Customize applications** in vClusters
4. **Monitor costs** with AWS Cost Explorer
5. **Set up monitoring** and alerting

For detailed architecture information, see [README.md](README.md).