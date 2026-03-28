#!/bin/bash
# ============================================================
# Script 1: VPC & Networking Setup
# UniEvent - Assignment 1 CE 308/408 Cloud Computing
# Run this FIRST before any other scripts.
# ============================================================
set -e

AWS_REGION="us-east-1"
PROJECT="unievents"

echo "========================================"
echo " UniEvent — VPC & Network Setup"
echo "========================================"

# ── 1. Create VPC ──────────────────────────────────────────
echo "[1/8] Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region $AWS_REGION \
  --query 'Vpc.VpcId' --output text)

aws ec2 create-tags --resources $VPC_ID \
  --tags Key=Name,Value=${PROJECT}-vpc
echo "  ✅ VPC created: $VPC_ID"

# Enable DNS hostnames (required for EC2 public DNS)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

# ── 2. Internet Gateway ─────────────────────────────────────
echo "[2/8] Attaching Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 create-tags --resources $IGW_ID \
  --tags Key=Name,Value=${PROJECT}-igw
echo "  ✅ IGW: $IGW_ID"

# ── 3. Public Subnets (for ALB) ─────────────────────────────
echo "[3/8] Creating Public Subnets (ALB lives here)..."
PUB_SUB_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone ${AWS_REGION}a \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUB_1 \
  --tags Key=Name,Value=${PROJECT}-public-1a

PUB_SUB_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone ${AWS_REGION}b \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PUB_SUB_2 \
  --tags Key=Name,Value=${PROJECT}-public-1b

aws ec2 modify-subnet-attribute --subnet-id $PUB_SUB_1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUB_2 --map-public-ip-on-launch
echo "  ✅ Public Subnets: $PUB_SUB_1, $PUB_SUB_2"

# ── 4. Private Subnets (for EC2 app servers) ────────────────
echo "[4/8] Creating Private Subnets (EC2 app instances here)..."
PRIV_SUB_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.11.0/24 \
  --availability-zone ${AWS_REGION}a \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRIV_SUB_1 \
  --tags Key=Name,Value=${PROJECT}-private-1a

PRIV_SUB_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.12.0/24 \
  --availability-zone ${AWS_REGION}b \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRIV_SUB_2 \
  --tags Key=Name,Value=${PROJECT}-private-1b
echo "  ✅ Private Subnets: $PRIV_SUB_1, $PRIV_SUB_2"

# ── 5. NAT Gateway (lets private EC2s reach internet for API) ─
echo "[5/8] Allocating Elastic IP for NAT Gateway..."
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --query 'AllocationId' --output text)

echo "  Creating NAT Gateway in public subnet..."
NAT_GW=$(aws ec2 create-nat-gateway \
  --subnet-id $PUB_SUB_1 \
  --allocation-id $EIP_ALLOC \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources $NAT_GW \
  --tags Key=Name,Value=${PROJECT}-natgw
echo "  ✅ NAT Gateway: $NAT_GW (takes ~2 min to become available)"
echo "  ⏳ Waiting for NAT Gateway to be available..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW
echo "  ✅ NAT Gateway is available!"

# ── 6. Route Tables ─────────────────────────────────────────
echo "[6/8] Configuring Route Tables..."

# Public route table → Internet Gateway
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $PUB_RT \
  --tags Key=Name,Value=${PROJECT}-public-rt
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $PUB_SUB_1 --route-table-id $PUB_RT
aws ec2 associate-route-table --subnet-id $PUB_SUB_2 --route-table-id $PUB_RT

# Private route table → NAT Gateway
PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $PRIV_RT \
  --tags Key=Name,Value=${PROJECT}-private-rt
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW
aws ec2 associate-route-table --subnet-id $PRIV_SUB_1 --route-table-id $PRIV_RT
aws ec2 associate-route-table --subnet-id $PRIV_SUB_2 --route-table-id $PRIV_RT
echo "  ✅ Route tables configured"

# ── 7. Security Groups ───────────────────────────────────────
echo "[7/8] Creating Security Groups..."

# ALB Security Group — accepts HTTP from internet
ALB_SG=$(aws ec2 create-security-group \
  --group-name ${PROJECT}-alb-sg \
  --description "Allow HTTP from internet to ALB" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 create-tags --resources $ALB_SG \
  --tags Key=Name,Value=${PROJECT}-alb-sg

# EC2 App Security Group — accepts traffic ONLY from ALB
APP_SG=$(aws ec2 create-security-group \
  --group-name ${PROJECT}-app-sg \
  --description "Allow traffic from ALB only" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $APP_SG \
  --protocol tcp --port 5000 \
  --source-group $ALB_SG
aws ec2 authorize-security-group-ingress \
  --group-id $APP_SG \
  --protocol tcp --port 22 --cidr 10.0.0.0/16
aws ec2 create-tags --resources $APP_SG \
  --tags Key=Name,Value=${PROJECT}-app-sg

echo "  ✅ ALB SG: $ALB_SG"
echo "  ✅ App SG: $APP_SG"

# ── 8. Save IDs ──────────────────────────────────────────────
echo "[8/8] Saving resource IDs to vpc_ids.env ..."
cat > vpc_ids.env <<EOF
VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
PUB_SUB_1=$PUB_SUB_1
PUB_SUB_2=$PUB_SUB_2
PRIV_SUB_1=$PRIV_SUB_1
PRIV_SUB_2=$PRIV_SUB_2
NAT_GW=$NAT_GW
PUB_RT=$PUB_RT
PRIV_RT=$PRIV_RT
ALB_SG=$ALB_SG
APP_SG=$APP_SG
AWS_REGION=$AWS_REGION
EOF

echo ""
echo "========================================"
echo " ✅ VPC Setup Complete!"
echo "========================================"
echo " VPC ID:        $VPC_ID"
echo " Public subs:   $PUB_SUB_1 | $PUB_SUB_2"
echo " Private subs:  $PRIV_SUB_1 | $PRIV_SUB_2"
echo " ALB SG:        $ALB_SG"
echo " App SG:        $APP_SG"
echo ""
echo " IDs saved to vpc_ids.env — run 02_iam_setup.sh next."
echo "========================================"
