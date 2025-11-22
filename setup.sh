#!/usr/bin/env bash
set -euo pipefail

# Directories & logging
mkdir -p Resources/AWS

mkdir -p Resources/AWS/Logs
touch Resources/AWS/Logs/setup.log

LOGFILE="Resources/AWS/Logs/setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

# Colors & formatting
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
NC="\e[0m"
DIVIDER="------------------------------------------------------------"

section() {
    local title="$1"
    echo -e "\n${YELLOW}=============== $title ===============${NC}"
}

# Load environment (.env)
source .env 

# Install Dependencies
section "Install Dependencies"

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${BLUE}jq not found. Installing...${NC}"
    sudo apt update -y >/dev/null 2>&1
    sudo apt install -y jq >/dev/null 2>&1
    echo -e "${GREEN}jq installed.${NC}"
else
    echo -e "${GREEN}jq already installed.${NC}" # used for parsing JSON (AMI IDs, Instance IDs, IPs)"
fi

########################################
# 1. AWS Profile
########################################
section "AWS Profile"

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$PROFILE_NAME"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$PROFILE_NAME"
aws configure set region "$AWS_REGION" --profile "$PROFILE_NAME"

export AWS_PROFILE="$PROFILE_NAME"
export AWS_REGION=$AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

echo -e "${BLUE}Using AWS profile: ${NC}$AWS_PROFILE"
echo -e "${BLUE}Using AWS region : ${NC}$AWS_REGION"

########################################
# 2. Create a key pair if not available
########################################
section "Key Pair Setup"

KEY_NAME="k3s-ec2-helm-prom-key"
KEY_FILE="${KEY_NAME}.pem"
KEY="Resources/AWS/${KEY_NAME}.pem"

echo -e "${BLUE}Checking if key pair exists in AWS...${NC}\n"

aws ec2 describe-key-pairs \
--key-names "$KEY_NAME" \
--output text >/dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Key pair already exists in AWS.${NC}\n"
else
    echo -e "${RED}Key pair does not exist.${NC} Creating a new one...\n"

    aws ec2 create-key-pair \
        --key-name k3s-ec2-helm-prom-key \
        --key-type rsa \
        --query "KeyMaterial" \
        --output text > Resources/AWS/k3s-ec2-helm-prom-key.pem

    echo -e "${GREEN}Key pair $KEY_NAME created in region $AWS_REGION.${NC}\n"

    # chmod 400 k3s-ec2-helm-prom-key.pem
 fi

 
echo -e "${BLUE}Key Name: ${NC}$KEY_NAME"
echo -e "${BLUE}Region:   ${NC}$AWS_REGION"
echo -e "${BLUE}Details File : ${NC}Resources/AWS/k3s-ec2-helm-prom-key.pem\n"

########################################
# 3. Security Group
########################################

section "Security Group Creation"

SG_NAME="k3s-nginx-sg"
MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

echo -e "${BLUE}Getting vpc-id of a default VPC...${NC}\n"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default, Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

if [ "$EXISTING_SG" != "None" ] && [ -n "$EXISTING_SG" ]; then
  echo -e "${GREEN}Security Group already exists.${NC}"
else
  echo -e "${BLUE}Creating Security Group...${NC}"

  aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group to allow SSH and HTTP access" \
    --vpc-id "$VPC_ID" \
    --output json > Resources/AWS/security_group_details.json

  SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

  if [ $? -eq 0 ]; then
      echo -e "${GREEN}Security group ${SG_ID} created successfully.${NC}\n"
  else
      echo -e "${RED}Security group creation failed. Cannot proceed.${NC}\n"
      exit 1
  fi

  echo -e "${BLUE}Adding inbound rules to allow SSH and HTTP access...${NC}"

  # Allow SSH from your IP only
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$MY_IP" \
    --output json > Resources/AWS/security_group_rules.txt

  # Allow HTTP from everywhere
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr "0.0.0.0/0" \
    --output json >> Resources/AWS/security_group_rules.txt

  # Allow NGINX web server from everywhere
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 30080 \
    --cidr "0.0.0.0/0" \
    --output json >> Resources/AWS/security_group_rules.txt
  
  # Allow Prometheus web server from everywhere
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 30090 \
    --cidr "0.0.0.0/0" \
    --output json >> Resources/AWS/security_group_rules.txt

  echo -e "${GREEN}Inbound rules added successfully.${NC}"
fi

########################################
# 4. EC2 creation
########################################

section "EC2 Instance Creation"
INSTANCE_NAME="k3s-ec2-helm-prom"

echo -e "${BLUE}Checking if EC2 instance exists in AWS...${NC}\n"

EXISTING_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null)


if [ "$EXISTING_INSTANCE_ID" != "None" ] && [ -n "$EXISTING_INSTANCE_ID" ]; then
    echo -e "${GREEN}EC2 instance already exists in AWS."
    echo -e "${BLUE}Skipping EC2 creation.${NC}\n"
else
    echo -e "${RED}No existing EC2 found. ${BLUE}Creating one...${NC}\n"

    echo -e "${BLUE}Getting AMI ID for Ubuntu 22.04...${NC}\n"

    AMI_ID=$(aws ec2 describe-images \
    --region ca-central-1 \
    --owners amazon \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server*' \
    --query 'reverse(sort_by(Images, &CreationDate))[:1] | [0].ImageId' \
    --output text)

    echo -e "${BLUE}Using AMI ${GREEN}${AMI_ID} ${BLUE}to create EC2 instance...${NC}\n"

    aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t2.small \
    --key-name "$KEY_NAME" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --security-group-ids "$SG_ID" \
    --region $AWS_REGION \
    --output json > Resources/AWS/ec2_details.json

fi

INSTANCE_ID=$(jq -r '.Instances[0].InstanceId' Resources/AWS/ec2_details.json)
AMI_USED=$(jq -r '.Instances[0].ImageId' Resources/AWS/ec2_details.json)
INSTANCE_TYPE=$(jq -r '.Instances[0].InstanceType' Resources/AWS/ec2_details.json)

echo -e "${BLUE}Instance Name : ${NC}$INSTANCE_NAME"
echo -e "${BLUE}Instance ID : ${NC}$INSTANCE_ID"
echo -e "${BLUE}Instance Type: ${NC}$INSTANCE_TYPE"
echo -e "${BLUE}AMI Used     : ${NC}$AMI_USED"
echo -e "${BLUE}Details File : ${NC}Resources/AWS/ec2_details.json\n"

echo -e "${BLUE}Waiting for EC2 instance to enter 'running' state...${NC}"

aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

echo -e "${GREEN}EC2 Instance is now running.${NC}"

########################################
# 5. SSH into instance
########################################

section "Logging into EC2 instance via SSH"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo -e "${BLUE}Public IP: ${NC}$PUBLIC_IP\n"

chmod 400 $KEY

REMOTE_SCRIPT="remote_script.sh"

echo -e "${YELLOW}Attempting SSH login...${NC}\n"

echo -e "${BLUE}Remote script to be executed:${NC}\n"
cat "$REMOTE_SCRIPT"

echo -e "\n${BLUE}Sending remote_script.sh to EC2 and executing it...${NC}"

ssh -o StrictHostKeyChecking=no -i "$KEY" ubuntu@"$PUBLIC_IP" < "$REMOTE_SCRIPT"
