#\!/bin/bash

# Create a simple EC2 instance to test the cluster setup
aws ec2 run-instances \
  --image-id ami-0c02fb55956c7d316 \
  --instance-type t3.medium \
  --key-name ws-default-keypair \
  --security-group-ids $(aws ec2 describe-security-groups --filters "Name=group-name,Values=*modern-engineering*" --query 'SecurityGroups[0].GroupId' --output text --region us-east-1) \
  --subnet-id $(aws ec2 describe-subnets --filters "Name=tag:Name,Values=*Public*" --query 'Subnets[0].SubnetId' --output text --region us-east-1) \
  --region us-east-1 \
  --user-data '#\!/bin/bash
apt update
apt install -y git curl unzip
cd /home/ubuntu
git clone https://github.com/shlapolosa/idp idp-setup
cd idp-setup
chmod +x setup-karpenter-vclusters.sh
echo "Ready to test\! SSH in and run: ./setup-karpenter-vclusters.sh --cloud aws"
  ' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=test-cluster-setup}]'
