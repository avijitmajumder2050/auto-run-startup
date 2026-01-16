#!/bin/bash

# ==============================
# EC2 Auto Setup - DHAN Jobs
# Amazon Linux 2023
# ==============================

set -e

REGION="ap-south-1"
ACCOUNT_ID=$(aws ssm get-parameter \
  --name "/dhan/aws/account-id" \
  --region $REGION \
  --query "Parameter.Value" \
  --output text)

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Using ECR registry: $ECR_REGISTRY"

echo "==== Updating system ===="
sudo yum update -y

echo "==== Installing Docker and utilities ===="
sudo yum install -y docker awscli

echo "==== Enable Docker ===="
sudo systemctl enable docker
sudo systemctl start docker

echo "==== Add ec2-user to docker group ===="
sudo usermod -aG docker ec2-user

echo "==== Create logs folder ===="
mkdir -p /home/ec2-user/logs
chown ec2-user:ec2-user /home/ec2-user/logs

echo "==== Switch to docker group and run jobs ===="

newgrp docker <<EOF
set -e

echo "==== Login to AWS ECR ===="
aws ecr get-login-password --region ${REGION} \
| docker login --username AWS --password-stdin ${ECR_REGISTRY}

echo "==== Pull DHAN Docker images ===="
docker pull ${ECR_REGISTRY}/dhan-token-refresh:latest
docker pull ${ECR_REGISTRY}/dhan-ohlc-job:latest

export PATH=/usr/local/bin:/usr/bin:/bin
export HOME=/home/ec2-user

echo "==== Token refresh job ===="
docker run --rm \
${ECR_REGISTRY}/dhan-token-refresh:latest \
>> /home/ec2-user/logs/token.log 2>&1

sleep 180

echo "==== OHLC job ===="
docker run --rm \
${ECR_REGISTRY}/dhan-ohlc-job:latest \
>> /home/ec2-user/logs/ohlc.log 2>&1

echo "==== Docker jobs completed ===="
EOF

echo "==== SCRIPT FINISHED SUCCESSFULLY ===="

sleep 120

echo "==== Initiating shutdown ===="
sudo shutdown -h now
