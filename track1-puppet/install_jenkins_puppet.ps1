# =============================================================================
# Jenkins Automation - Track 1A: PowerShell + Puppet (Windows Bootstrap)
# =============================================================================
# Bootstraps Puppet agent on Windows Server 2022, installs the puppetlabs-registry
# module, downloads the Jenkins manifest from GitHub, and runs puppet apply.
#
# Puppet then takes over and declares the desired state for:
#   - Jenkins package and prerequisites
#   - Port 8000 configuration
#   - Setup wizard disabled
#   - Jenkins service running and enabled
#
# Requirements satisfied:
#   A) Runs on a clean OS - all dependencies installed from scratch
#   B) Fully unattended - no prompts at any stage
#   C) Jenkins listens on port 8000 natively
#   D) Idempotent - puppet apply converges to desired state on every run
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File install_jenkins_puppet.ps1
#
# Author: Luis Zambrano
# =============================================================================

$ErrorActionPreference = "Stop"

# --- CONSTANTS ----------------------------------------------------------------
$PuppetVersionUrl  = "https://downloads.puppet.com/puppet-agent/latest.json"
$PuppetInstallDir  = "C:\Program Files\Puppet Labs\Puppet\bin"
$PuppetBin         = "C:\Program Files\Puppet Labs\Puppet\bin\puppet.bat"
$PuppetModulePath  = "C:\ProgramData\PuppetLabs\puppet\etc\modules"
$PuppetModule      = "puppetlabs-registry"
$ManifestUrl       = "https://raw.githubusercontent.com/zambrano-luis/jenkins-automation/main/track1-puppet/manifests/jenkins-windows.pp"
$ManifestPath      = "$env:TEMP\jenkins.pp"
$MsiPath           = "$env:TEMP\puppet-agent.msi"

# --- LOGGING ------------------------------------------------------------------
function Write-Header {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  Jenkins Automation - Track 1A: Puppet Windows  ║" -ForegroundColor Yellow
    Write-Host "║  Target: Windows Server 2022                    ║" -ForegroundColor Yellow
    Write-Host "║  Port:   8000                                   ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
}

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Yellow }
function Write-Info { param($msg) Write-Host "    ->  $msg" -ForegroundColor Gray }
function Write-Skip { param($msg) Write-Host "    SKIP: $msg - already done" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }

function Write-Summary {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║             Installation Complete                ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║  Jenkins is running on port 8000                 ║" -ForegroundColor Green
    Write-Host "║                                                  ║" -ForegroundColor Green
    Write-Host "║  Access:  http://<your-ip>:8000              ║" -ForegroundColor Green
    Write-Host "║  Logs:    Get-EventLog -LogName Application      ║" -ForegroundColor Green
    Write-Host "║  Puppet:  puppet apply manifests\jenkins.pp      ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
}

# --- HELPERS ------------------------------------------------------------------
function Ensure-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Fail "This script must be run as Administrator."
    }
}

function Is-PuppetInstalled {
    return Test-Path $PuppetBin
}

# --- STEP 1: Install Puppet Agent ---------------------------------------------
function Step-InstallPuppet {
    Write-Step "Step 1/4 - Installing Puppet agent"

    if (Is-PuppetInstalled) {
        Write-Skip "Puppet agent already installed"
        return
    }

    Write-Info "Fetching latest Puppet agent version from Puppet API..."
    try {
        $response = Invoke-RestMethod -Uri $PuppetVersionUrl -UseBasicParsing
        $version  = $response.version
    } catch {
        Write-Fail "Failed to fetch latest Puppet version from $PuppetVersionUrl - $_"
    }

    $msiUrl = "https://downloads.puppet.com/windows/puppet-agent-$version-x64.msi"
    Write-Info "Latest version: $version"
    Write-Info "Downloading from: $msiUrl"

    try {
        Invoke-WebRequest -Uri $msiUrl -OutFile $MsiPath -UseBasicParsing
    } catch {
        Write-Fail "Failed to download Puppet MSI: $_"
    }

    Write-Info "Installing Puppet agent silently..."
    $install = Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" /qn /norestart" -Wait -PassThru
    if ($install.ExitCode -notin @(0, 3010)) {
        Write-Fail "Puppet MSI installation failed with exit code $($install.ExitCode)"
    }

    # Add Puppet to PATH for this session
    $env:PATH = "$PuppetInstallDir;$env:PATH"

    Write-Ok "Puppet agent $version installed"
}

# --- STEP 2: Install puppetlabs-registry module ------------------------------------
function Step-InstallModule {
    Write-Step "Step 2/4 - Installing $PuppetModule module"

    $moduleCheck = & "$PuppetBin" module list 2>&1 | Select-String $PuppetModule
    if ($moduleCheck) {
        Write-Skip "$PuppetModule already installed"
        return
    }

    Write-Info "Installing $PuppetModule..."
    & "$PuppetBin" module install $PuppetModule --target-dir $PuppetModulePath
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install $PuppetModule module"
    }

    Write-Ok "$PuppetModule installed"
}

# --- STEP 3: Download manifest ------------------------------------------------
function Step-DownloadManifest {
    Write-Step "Step 3/4 - Downloading Jenkins manifest"

    Write-Info "Fetching manifest from GitHub..."
    try {
        Invoke-WebRequest -Uri $ManifestUrl -OutFile $ManifestPath -UseBasicParsing
    } catch {
        Write-Fail "Failed to download manifest from $ManifestUrl - $_"
    }

    Write-Ok "Manifest saved to $ManifestPath"
}

# --- STEP 4: Run puppet apply -------------------------------------------------
function Step-PuppetApply {
    Write-Step "Step 4/4 - Applying Puppet manifest"

    Write-Info "Running puppet apply (this may take a few minutes)..."
    & "$PuppetBin" apply $ManifestPath --modulepath $PuppetModulePath
    
    # Puppet exit codes:
    # 0 = success, no changes
    # 2 = success, changes were made
    # 4 = failures
    # 6 = changes and failures
    if ($LASTEXITCODE -notin @(0, 2)) {
        Write-Fail "Puppet apply failed with exit code $LASTEXITCODE"
    }

    Write-Ok "Puppet apply completed successfully"
}

# --- MAIN ---------------------------------------------------------------------
Write-Header
Ensure-Admin
Step-InstallPuppet
Step-InstallModule
Step-DownloadManifest
Step-PuppetApply
Write-Summary