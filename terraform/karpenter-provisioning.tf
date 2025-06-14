terraform {
  required_providers {
    aws       = { source = "hashicorp/aws", version = "~> 5.20" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">=2.10" }
    helm      = { source = "hashicorp/helm", version = ">=2.7" }
    kubectl   = { source = "gavinbunney/kubectl", version = ">=0.19" }
  }
}

variable "region" {
  type        = string
  description = "AWS region"
}
variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "azs" {}

locals {
  cidr_block    = "10.0.0.0/16"
  public_cidrs  = [for i in range(3): cidrsubnet(local.cidr_block, 8, i)]
  private_cidrs = [for i in range(3): cidrsubnet(local.cidr_block, 8, i + 4)]
  tags          = { "karpenter.sh/discovery" = var.cluster_name }
}

module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~>4.0"
  name               = var.cluster_name
  cidr               = local.cidr_block
  azs                = data.aws_availability_zones.azs.names[0:3]
  public_subnets     = local.public_cidrs
  private_subnets    = local.private_cidrs
  enable_nat_gateway = true
  single_nat_gateway = false
  tags               = local.tags
}

module "eks" {
  source             = "terraform-aws-modules/eks/aws"
  version            = "~>20.24"
  cluster_name       = var.cluster_name
  cluster_version    = "1.30"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  cluster_addons = {
    kube-proxy = {}
    vpc-cni    = {}
    coredns    = { configuration_values = jsonencode({ computeType = "fargate" }) }
  }
  fargate_profiles = {
    kube-system = { selectors = [{ namespace = "kube-system", labels = { k8s-app = "kube-dns" } }] }
    karpenter    = { selectors = [{ namespace = "karpenter" }] }
  }
  enable_irsa = true
  manage_aws_auth = true
  tags = local.tags
}

# Fargate pod execution role
resource "aws_iam_role" "fargate_exec" {
  name = "${var.cluster_name}-fargate-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}
resource "aws_iam_role_policy_attachment" "fargate_exec_attach" {
  role       = aws_iam_role.fargate_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}
resource "aws_eks_fargate_profile" "karpenter" {
  cluster_name           = module.eks.cluster_name
  fargate_profile_name   = "karpenter"
  pod_execution_role_arn = aws_iam_role.fargate_exec.arn
  subnet_ids             = module.vpc.private_subnets
  selector { namespace = "karpenter" }
}

# IRSA for Karpenter controller + EC2 node role
module "karpenter_irsa" {
  source                             = "terraform-aws-modules/eks/aws//modules/karpenter"
  version                            = "~>20.24"
  cluster_name                       = module.eks.cluster_name
  irsa_namespace_service_accounts    = ["karpenter:karpenter"]
}

# Spot termination queue
resource "aws_sqs_queue" "karpenter" {
  name = "${var.cluster_name}-karpenter-spot"
}
resource "aws_iam_role_policy" "karpenter_spot" {
  role = module.karpenter_irsa.iam_role_name
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage","sqs:GetQueueUrl","sqs:DeleteMessage","sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.karpenter.arn
    }]
  })
}

# Helm: install CRDs and Karpenter
resource "helm_release" "karpenter_crds" {
  name       = "karpenter-crds"
  repository = "oci://public.ecr.aws/karpenter/karpenter-chart"
  chart      = "karpenter-crds"
  version    = "v0.36.2"
}
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter/karpenter-chart"
  chart      = "karpenter"
  version    = "v0.36.2"
  namespace  = "karpenter"
  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "clusterEndpoint", value = module.eks.cluster_endpoint },
    { name = "aws.defaultInstanceProfile", value = module.karpenter_irsa.node_instance_profile_name },
    { name = "settings.aws.interruptionQueueName", value = aws_sqs_queue.karpenter.name },
  ]
  depends_on = [helm_release.karpenter_crds]
}

# Provisioner manifest for Step 7
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
resource "kubectl_manifest" "default_provisioner" {
  yaml_body = <<EOF
apiVersion: karpenter.sh/v1
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
  - key: "karpenter.k8s.aws/instance-category"
    operator: In
    values: ["c", "m", "r"]
  providerRef:
    name: default
  consolidation:
    enabled: true
  ttlSecondsAfterEmpty: 30
EOF
  depends_on = [helm_release.karpenter]
}
