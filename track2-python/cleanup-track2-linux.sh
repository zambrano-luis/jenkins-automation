#!/usr/bin/env bash
# =============================================================================
# Jenkins Automation - Linux Stack Cleanup Script
# =============================================================================
# Usage: ./cleanup-linux.sh [stack-name] [region]
# =============================================================================

set -euo pipefail

STACK_NAME="${1:-jenkins-linux-demo}"
REGION="${2:-us-west-2}"
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

# --- STEP 0: Validate AWS session ---------------------------------------------
step "Step 0/4 - Validating AWS session..."
IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
    echo -e "${RED}ERROR: AWS session is not active or has expired.${RESET}"
    echo -e "${YELLOW}If using SSO run: aws sso login${RESET}"
    exit 1
}
ACCOUNT=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
ok "Authenticated - AWS Account: $ACCOUNT"

# --- STEP 1: Confirm deletion -------------------------------------------------
step "Step 1/4 - Confirm deletion"
echo ""
echo -e "  ${CYAN}Stack:   $STACK_NAME${RESET}"
echo -e "  ${CYAN}Region:  $REGION${RESET}"
echo ""
echo -e "  ${RED}This will permanently delete:${RESET}"
echo -e "  ${RED}  - EC2 instance${RESET}"
echo -e "  ${RED}  - Security group${RESET}"
echo -e "  ${RED}  - Key pair (private key will be unrecoverable)${RESET}"
echo ""
read -rp "Type YES to confirm: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo -e "${YELLOW}Cancelled.${RESET}"
    exit 0
fi

# --- STEP 2: Delete stack -----------------------------------------------------
step "Step 2/4 - Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION"
ok "Stack deletion initiated"

# --- STEP 3: Wait for deletion ------------------------------------------------
step "Step 3/4 - Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"
ok "Stack deleted"

# --- STEP 4: Clean up local key file ------------------------------------------
step "Step 4/4 - Cleaning up local key file..."
if [ -f "$KEY_FILE" ]; then
    rm -f "$KEY_FILE"
    ok "$KEY_FILE removed"
else
    info "No local key file found - nothing to clean up"
fi

echo ""
echo -e "  ${GREEN}Cleanup complete. All stack resources have been deleted.${RESET}"
echo ""
