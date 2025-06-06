# IDP Repository Summary

## Repository Structure

```
shlapolosa/idp/
├── README.md                           # Comprehensive architecture documentation
├── INSTALL.md                          # Quick installation guide
├── deploy.sh                          # Auto-scaling code-server deployment
├── setup-karpenter-vclusters.sh       # Karpenter + vCluster multi-environment setup
├── modern-engineering-workshop.yaml   # CloudFormation template
└── SUMMARY.md                         # This file
```

## Script Interconnections

### 1. **deploy.sh** → **modern-engineering-workshop.yaml**
- `deploy.sh` automatically creates S3 bucket for CloudFormation staging
- Deploys `modern-engineering-workshop.yaml` via CloudFormation
- Handles stack creation, updates, and provides outputs

### 2. **modern-engineering-workshop.yaml** → **setup-karpenter-vclusters.sh**
- CloudFormation template references GitHub repo: `https://github.com/shlapolosa/idp`
- SSM document downloads and executes `setup-karpenter-vclusters.sh`
- Provides setup choice between legacy 3-cluster and optimized Karpenter approach

### 3. **Cross-Script References**
- All scripts reference the GitHub repository for consistency
- CloudFormation template auto-downloads scripts from the repo
- Setup choice script allows switching between deployment methods

## Deployment Architectures

### Architecture 1: Auto-Scaling Code-Server
```
User → CloudFront → Lambda@Edge → Auto Scaling Group (0-1 instances)
                                      ↓
                               VSCode Server (t3.micro → c6a.large)
```

**Triggered by**: `./deploy.sh`

### Architecture 2: Karpenter + vCluster Platform
```
Single EKS Cluster + Karpenter
├── vCluster: modern-engineering (ArgoCD, Gitea, Keycloak, Backstage)
├── vCluster: modernengg-dev (Development environment)
└── vCluster: modernengg-prod (Production environment)
```

**Triggered by**: `./setup-karpenter-vclusters.sh` or EC2 SSM document choice

## Cost Optimization Features

### Code-Server (Architecture 1)
- **Scale to 0 instances**: No cost when idle
- **Vertical scaling**: Auto-upgrades instance types based on CPU
- **Horizontal scaling**: Lambda@Edge triggers instance startup
- **Free tier eligible**: t3.micro for 750 hours/month
- **AI Integration**: Claude Code with remote context7 MCP server for intelligent code assistance

### Karpenter Platform (Architecture 2)  
- **89% cost reduction**: $72/month vs $648/month (3 separate clusters)
- **Physical node scale-to-zero**: Karpenter scales nodes based on total demand
- **vCluster sleep mode**: Virtual clusters auto-sleep after inactivity
- **Spot instance support**: Up to 80% savings on compute
- **Resource sharing**: Load balancers, storage, ingress controllers

## Multi-Cloud Support

### AWS Support
- **Code-Server**: Full CloudFormation deployment with Lambda@Edge
- **Karpenter**: EKS with official Karpenter installation
- **Services**: CloudFront, Auto Scaling Groups, Lambda, EBS

### Azure Support
- **Code-Server**: Can be adapted for Azure (currently AWS-focused)
- **Karpenter**: AKS with Node Autoprovisioning (Karpenter preview)
- **Services**: Azure Load Balancer, Virtual Machine Scale Sets

## Key Innovation Points

### 1. **Intelligent Script Selection**
- CloudFormation template provides choice between deployment methods
- Auto-detects optimal setup based on use case
- Graceful fallback for different scenarios

### 2. **True Scale-to-Zero**
- Both architectures achieve zero cost when idle
- Code-Server: Instance terminates after inactivity
- Karpenter: Physical nodes scale to zero when no workloads

### 3. **Cross-Architecture Compatibility**
- Same development environment (VSCode + tools) in both setups
- Consistent user experience regardless of underlying architecture
- Seamless migration path between architectures

### 4. **GitHub Integration**
- All scripts reference the central repository
- Auto-downloading of latest scripts during deployment
- Version control for infrastructure-as-code

## Use Case Recommendations

### Choose Code-Server Architecture When:
- Individual developer or small team
- Learning Kubernetes/cloud development
- Cost is primary concern ($0-25/month)
- Simple setup requirements
- Don't need persistent Kubernetes clusters

### Choose Karpenter Platform When:
- Team or organization (multiple developers)
- Need multiple environments (dev/staging/prod)
- Want full GitOps workflow with ArgoCD
- Need identity management (Keycloak)
- Have complex application requirements
- Cost optimization at scale ($72/month base)

## Deployment Success Metrics

### Code-Server Success Indicators
- CloudFormation stack: `CREATE_COMPLETE`
- Auto Scaling Group: Shows 0 desired instances
- CloudFront distribution: Returns 200 status
- VSCode access: Login with AWS Account ID

### Karpenter Platform Success Indicators  
- EKS cluster: `ACTIVE` status
- Karpenter: NodePool and EC2NodeClass created
- vClusters: All 3 virtual clusters running
- Applications: ArgoCD, Gitea, Keycloak accessible

## Repository Advantages

1. **Self-Contained**: All scripts and documentation in one place
2. **Cross-Referenced**: Scripts automatically find and use each other
3. **Multi-Architecture**: Supports different deployment patterns
4. **Cost-Optimized**: Focus on minimizing AWS costs
5. **Production-Ready**: Includes monitoring, scaling, and security
6. **Educational**: Comprehensive documentation and examples

This repository provides a complete IDP (Internal Developer Platform) solution that scales from individual developers to enterprise teams while maintaining cost efficiency and operational simplicity.