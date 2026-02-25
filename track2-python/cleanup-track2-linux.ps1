# =============================================================================
# Jenkins Automation - Linux Stack Cleanup Script
# =============================================================================
# Usage: .\cleanup-linux.ps1
# Deletes the CloudFormation stack and all associated resources including
# the EC2 instance, security group, and key pair.
# =============================================================================

param(
    [string]$StackName = "jenkins-linux-demo",
    [string]$Region    = "us-west-2"
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Yellow }
function Write-Ok   { param($msg) Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "    ->  $msg" -ForegroundColor Gray }

# --- STEP 0: Validate AWS session ---------------------------------------------
Write-Step "Step 0/4 - Validating AWS session..."
$identity = aws sts get-caller-identity --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AWS session is not active or has expired." -ForegroundColor Red
    Write-Host "If using SSO run: aws sso login" -ForegroundColor Yellow
    Write-Host "If using access keys ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set." -ForegroundColor Yellow
    exit 1
}
$Account = ($identity | ConvertFrom-Json).Account
Write-Ok "Authenticated - AWS Account: $Account"

# --- STEP 1: Confirm deletion -------------------------------------------------
Write-Step "Step 1/4 - Confirm deletion"
Write-Host ""
Write-Host "  Stack:   $StackName" -ForegroundColor Cyan
Write-Host "  Region:  $Region" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This will permanently delete:" -ForegroundColor Red
Write-Host "    - EC2 instance" -ForegroundColor Red
Write-Host "    - Security group" -ForegroundColor Red
Write-Host "    - Key pair (private key will be unrecoverable)" -ForegroundColor Red
Write-Host ""
$confirm = Read-Host "Type YES to confirm"
if ($confirm -ne "YES") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# --- STEP 2: Delete stack -----------------------------------------------------
Write-Step "Step 2/4 - Deleting CloudFormation stack..."
aws cloudformation delete-stack `
    --stack-name $StackName `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to initiate stack deletion." -ForegroundColor Red
    exit 1
}
Write-Ok "Stack deletion initiated"

# --- STEP 3: Wait for deletion ------------------------------------------------
Write-Step "Step 3/4 - Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete `
    --stack-name $StackName `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Stack deletion failed or timed out. Check AWS Console." -ForegroundColor Red
    exit 1
}
Write-Ok "Stack deleted"

# --- STEP 4: Clean up local key file ------------------------------------------
Write-Step "Step 4/4 - Cleaning up local key file..."
if (Test-Path .\jenkins-demo.pem) {
    icacls .\jenkins-demo.pem /grant "$($env:USERNAME):(F)" | Out-Null
    Remove-Item .\jenkins-demo.pem -Force
    Write-Ok "jenkins-demo.pem removed"
} else {
    Write-Info "No local key file found - nothing to clean up"
}

Write-Host ""
Write-Host "  Cleanup complete. All stack resources have been deleted." -ForegroundColor Green
Write-Host ""
