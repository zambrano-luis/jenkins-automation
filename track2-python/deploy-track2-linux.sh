#!/usr/bin/env bash
# =============================================================================
# Jenkins Automation - Linux CloudFormation Deploy Script
# =============================================================================
# Usage: ./deploy-linux.sh [stack-name] [region]
# =============================================================================

set -euo pipefail

STACK_NAME="${1:-jenkins-linux-demo}"
REGION="${2:-us-west-2}"
TEMPLATE="aws-demo-cf-templates/jenkins-linux.yaml"
KEY_FILE="jenkins-demo.pem"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
RESET='\033[0m'

step() { echo -e "\n${YELLOW}==> $1${RESET}"; }
ok()   { echo -e "    ${GREEN}OK  $1${RESET}"; }
info() { echo -e "    ${GRAY}->  $1${RESET}"; }
err()  { echo -e "\n${RED}ERROR: $1${RESET}" >&2; exit 1; }

# --- STEP 0: Validate AWS session ---------------------------------------------
step "Step 0/6 - Validating AWS session..."
IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
    echo -e "${RED}ERROR: AWS session is not active or has expired.${RESET}"
    echo -e "${YELLOW}If using SSO run: aws sso login${RESET}"
    echo -e "${YELLOW}If using access keys ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set.${RESET}"
    exit 1
}
ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ok "Authenticated - AWS Account: $ACCOUNT"

# --- STEP 1: Get deployer IP --------------------------------------------------
step "Step 1/6 - Detecting your public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
[ -z "$MY_IP" ] && err "Could not detect public IP. Check internet connectivity."
ok "Deployer IP: $MY_IP"

# --- STEP 2: Deploy stack -----------------------------------------------------
step "Step 2/6 - Deploying CloudFormation stack..."
info "Stack:    $STACK_NAME"
info "Region:   $REGION"
info "Template: $TEMPLATE"

aws cloudformation deploy \
    --template-file "$TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --parameter-overrides DeployerIP="$MY_IP/32"

ok "Stack deployed"

# --- STEP 3: Get outputs ------------------------------------------------------
step "Step 3/6 - Retrieving stack outputs..."
OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs" \
    --output json)

PUBLIC_IP=$(echo "$OUTPUTS"      | python3 -c "import sys,json; o=json.load(sys.stdin); print(next(x['OutputValue'] for x in o if x['OutputKey']=='PublicIP'))")
JENKINS_URL=$(echo "$OUTPUTS"    | python3 -c "import sys,json; o=json.load(sys.stdin); print(next(x['OutputValue'] for x in o if x['OutputKey']=='JenkinsURL'))")
KEY_PAIR_ID=$(echo "$OUTPUTS"    | python3 -c "import sys,json; o=json.load(sys.stdin); print(next(x['OutputValue'] for x in o if x['OutputKey']=='KeyPairID'))")
KEY_PAIR_SSM=$(echo "$OUTPUTS"   | python3 -c "import sys,json; o=json.load(sys.stdin); print(next(x['OutputValue'] for x in o if x['OutputKey']=='KeyPairSSMPath'))")

ok "Public IP:    $PUBLIC_IP"
ok "Jenkins URL:  $JENKINS_URL"
ok "Key Pair ID:  $KEY_PAIR_ID"
ok "SSM Path:     $KEY_PAIR_SSM"

# --- STEP 4: Retrieve private key from SSM ------------------------------------
step "Step 4/6 - Retrieving private key from SSM Parameter Store..."
[ -f "$KEY_FILE" ] && rm -f "$KEY_FILE"

aws ssm get-parameter \
    --name "$KEY_PAIR_SSM" \
    --with-decryption \
    --region "$REGION" \
    --query "Parameter.Value" \
    --output text > "$KEY_FILE"

ok "Private key saved to $KEY_FILE"

# --- STEP 5: Fix key permissions ----------------------------------------------
step "Step 5/6 - Setting key file permissions..."
chmod 600 "$KEY_FILE"
ok "Permissions set (600)"

# --- STEP 6: Summary ----------------------------------------------------------
step "Step 6/6 - Deploy complete"
echo ""
echo -e "  ${CYAN}Jenkins URL:   $JENKINS_URL${RESET}"
echo -e "  ${CYAN}SSH Command:   ssh -i ./$KEY_FILE ubuntu@$PUBLIC_IP${RESET}"
echo ""
echo -e "  ${GRAY}Allow 2-3 minutes for Jenkins to fully initialize after stack creation.${RESET}"
echo -e "  ${GRAY}Jenkins is ready when the URL returns HTTP 403 (auth required).${RESET}"
echo ""
