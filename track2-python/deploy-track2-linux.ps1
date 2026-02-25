# =============================================================================
# Jenkins Automation - Linux CloudFormation Deploy Script
# =============================================================================
# Usage: .\deploy-linux.ps1
# =============================================================================

param(
    [string]$StackName = "jenkins-linux-demo",
    [string]$Region = "us-west-2",
    [string]$Template = "..\aws-demo-cf-templates\jenkins-linux.yaml"
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Yellow }
function Write-Ok   { param($msg) Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "    ->  $msg" -ForegroundColor Gray }

# --- STEP 0: Validate AWS SSO session -----------------------------------------
Write-Step "Step 0/6 - Validating AWS session..."
$identity = aws sts get-caller-identity --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AWS SSO session is not active or has expired." -ForegroundColor Red
    Write-Host "Run: aws sso login" -ForegroundColor Yellow
    exit 1
}
$Account = ($identity | ConvertFrom-Json).Account
Write-Ok "Authenticated - AWS Account: $Account"

# --- STEP 1: Get deployer IP --------------------------------------------------
Write-Step "Step 1/6 - Detecting your public IP..."
$MY_IP = (curl.exe -s https://checkip.amazonaws.com).Trim()
if (-not $MY_IP) {
    Write-Host "ERROR: Could not detect public IP. Check internet connectivity." -ForegroundColor Red
    exit 1
}
Write-Ok "Deployer IP: $MY_IP"

# --- STEP 2: Deploy stack -----------------------------------------------------
Write-Step "Step 2/6 - Deploying CloudFormation stack..."
Write-Info "Stack:    $StackName"
Write-Info "Region:   $Region"
Write-Info "Template: $Template"

aws cloudformation deploy `
    --template-file $Template `
    --stack-name $StackName `
    --region $Region `
    --parameter-overrides DeployerIP="$MY_IP/32"

if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Stack deploy failed." -ForegroundColor Red; exit 1 }
Write-Ok "Stack deployed"

# --- STEP 3: Get outputs ------------------------------------------------------
Write-Step "Step 3/6 - Retrieving stack outputs..."
$Outputs = aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --query "Stacks[0].Outputs" `
    --output json | ConvertFrom-Json

$PublicIP       = ($Outputs | Where-Object { $_.OutputKey -eq "PublicIP" }).OutputValue
$JenkinsURL     = ($Outputs | Where-Object { $_.OutputKey -eq "JenkinsURL" }).OutputValue
$KeyPairID      = ($Outputs | Where-Object { $_.OutputKey -eq "KeyPairID" }).OutputValue
$KeyPairSSMPath = ($Outputs | Where-Object { $_.OutputKey -eq "KeyPairSSMPath" }).OutputValue

Write-Ok "Public IP:    $PublicIP"
Write-Ok "Jenkins URL:  $JenkinsURL"
Write-Ok "Key Pair ID:  $KeyPairID"
Write-Ok "SSM Path:     $KeyPairSSMPath"

# --- STEP 4: Retrieve private key from SSM ------------------------------------
Write-Step "Step 4/6 - Retrieving private key from SSM Parameter Store..."
if (Test-Path .\jenkins-demo.pem) {
    Write-Info "Existing key file found - removing before overwrite..."
    icacls .\jenkins-demo.pem /grant "$($env:USERNAME):(F)" | Out-Null
    Remove-Item .\jenkins-demo.pem -Force
}
aws ssm get-parameter `
    --name $KeyPairSSMPath `
    --with-decryption `
    --region $Region `
    --query "Parameter.Value" `
    --output text | Out-File -FilePath jenkins-demo.pem -Encoding ascii

if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Failed to retrieve key from SSM." -ForegroundColor Red; exit 1 }
Write-Ok "Private key saved to jenkins-demo.pem"

# --- STEP 5: Fix key permissions ----------------------------------------------
Write-Step "Step 5/6 - Setting key file permissions..."
icacls .\jenkins-demo.pem /inheritance:r | Out-Null
icacls .\jenkins-demo.pem /grant:r "$($env:USERNAME):(R)" | Out-Null
icacls .\jenkins-demo.pem /remove "NT AUTHORITY\Authenticated Users" | Out-Null
icacls .\jenkins-demo.pem /remove "BUILTIN\Users" | Out-Null
Write-Ok "Permissions set"

# --- STEP 6: Summary ----------------------------------------------------------
Write-Step "Step 6/6 - Deploy complete"
Write-Host ""
Write-Host "  Jenkins URL:   $JenkinsURL" -ForegroundColor Cyan
Write-Host "  SSH Command:   ssh -i .\jenkins-demo.pem ubuntu@$PublicIP" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Allow 2-3 minutes for Jenkins to fully initialize after stack creation." -ForegroundColor Gray
Write-Host "  Jenkins is ready when the URL returns HTTP 403 (auth required)." -ForegroundColor Gray
Write-Host ""