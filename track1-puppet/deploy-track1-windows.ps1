# =============================================================================
# Jenkins Automation - Track 1A Windows (Puppet) CloudFormation Deploy Script
# =============================================================================
# Usage: powershell.exe -ExecutionPolicy Bypass -File deploy-track1-windows.ps1
# =============================================================================

param(
    [string]$StackName = "jenkins-windows-puppet-demo",
    [string]$Region    = "us-west-2",
    [string]$Template  = "..\aws-demo-cf-templates\jenkins-windows-puppet.yaml"
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Yellow }
function Write-Ok   { param($msg) Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info { param($msg) Write-Host "    ->  $msg" -ForegroundColor Gray }

# --- STEP 0: Validate AWS session ---------------------------------------------
Write-Step "Step 0/6 - Validating AWS session..."
$identity = aws sts get-caller-identity --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: AWS session is not active or has expired." -ForegroundColor Red
    Write-Host "Run: aws sso login  |  Or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY" -ForegroundColor Yellow
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
    --parameter-overrides DeployerIP="$MY_IP/32" `
    --capabilities CAPABILITY_NAMED_IAM

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
$RDPConnection  = ($Outputs | Where-Object { $_.OutputKey -eq "RDPConnection" }).OutputValue
$InstanceID     = ($Outputs | Where-Object { $_.OutputKey -eq "InstanceID" }).OutputValue

Write-Ok "Public IP:      $PublicIP"
Write-Ok "Jenkins URL:    $JenkinsURL"
Write-Ok "RDP Connection: $RDPConnection"
Write-Ok "Instance ID:    $InstanceID"

# --- STEP 4: Retrieve private key from SSM ------------------------------------
Write-Step "Step 4/6 - Retrieving private key from SSM Parameter Store..."
if (Test-Path .\jenkins-puppet-windows.pem) {
    Write-Info "Existing key file found - removing before overwrite..."
    icacls .\jenkins-puppet-windows.pem /grant "$($env:USERNAME):(F)" | Out-Null
    Remove-Item .\jenkins-puppet-windows.pem -Force
}
aws ssm get-parameter `
    --name $KeyPairSSMPath `
    --with-decryption `
    --region $Region `
    --query "Parameter.Value" `
    --output text | Out-File -FilePath jenkins-puppet-windows.pem -Encoding ascii

if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Failed to retrieve key from SSM." -ForegroundColor Red; exit 1 }
Write-Ok "Private key saved to jenkins-puppet-windows.pem"

# --- STEP 5: Fix key permissions ----------------------------------------------
Write-Step "Step 5/6 - Setting key file permissions..."
icacls .\jenkins-puppet-windows.pem /inheritance:r | Out-Null
icacls .\jenkins-puppet-windows.pem /grant:r "$($env:USERNAME):(R)" | Out-Null
icacls .\jenkins-puppet-windows.pem /remove "NT AUTHORITY\Authenticated Users" | Out-Null
icacls .\jenkins-puppet-windows.pem /remove "BUILTIN\Users" | Out-Null
Write-Ok "Permissions set"

# --- STEP 6: Extract Administrator password ----------------------------------
Write-Step "Step 6/6 - Retrieving Administrator password (polling - up to 10 min)..."

if (-not $InstanceID) {
    Write-Host "    WARN: InstanceID not in stack outputs - skipping password retrieval." -ForegroundColor Yellow
    Write-Host "    Retrieve manually: EC2 Console -> Instance -> Get Windows Password" -ForegroundColor Gray
} else {
    $AdminPassword = $null
    $MaxAttempts   = 40
    $WaitSeconds   = 15

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Write-Host "    Attempt $i/$MaxAttempts - waiting for password data..." -ForegroundColor Gray
        $PasswordData = aws ec2 get-password-data `
            --instance-id $InstanceID `
            --priv-launch-key .\jenkins-puppet-windows.pem `
            --region $Region `
            --query "PasswordData" `
            --output text 2>&1

        if ($LASTEXITCODE -eq 0 -and $PasswordData -and $PasswordData -ne "None" -and $PasswordData.Trim() -ne "") {
            $AdminPassword = $PasswordData.Trim()
            break
        }
        Start-Sleep -Seconds $WaitSeconds
    }

    if ($AdminPassword) {
        Write-Ok "Administrator password retrieved"
        Write-Host ""
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  RDP Credentials" -ForegroundColor Cyan
        Write-Host "    Host:     $RDPConnection" -ForegroundColor White
        Write-Host "    User:     Administrator" -ForegroundColor White
        Write-Host "    Password: $AdminPassword" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    } else {
        Write-Host "    Password not available after $MaxAttempts attempts." -ForegroundColor Yellow
        Write-Host "    Windows may still be initializing. Retrieve manually:" -ForegroundColor Gray
        Write-Host "    aws ec2 get-password-data --instance-id $InstanceID --priv-launch-key .\jenkins-puppet-windows.pem --region $Region --query PasswordData --output text" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "  Jenkins URL: $JenkinsURL" -ForegroundColor Cyan
Write-Host "  Allow 5-10 min for Windows + Jenkins to fully initialize." -ForegroundColor Gray
Write-Host "  Jenkins is ready when the URL returns HTTP 403." -ForegroundColor Gray
Write-Host ""