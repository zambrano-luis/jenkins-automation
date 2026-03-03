# =============================================================================
# Track 1A - Windows Bootstrap: Puppet Agent + DSC Lite
# Installs Puppet, installs puppetlabs-dsc_lite, then runs puppet apply.
# All Jenkins configuration is handled declaratively inside the manifest.
# =============================================================================

$ErrorActionPreference = "Stop"

# --- Config ------------------------------------------------------------------
$PuppetVersion  = "8.10.0"
$PuppetMsiUrl   = "https://downloads.puppet.com/windows/puppet8/puppet-agent-$PuppetVersion-x64.msi"
$PuppetMsiPath  = "C:\Windows\Temp\puppet-agent.msi"
$PuppetBin      = "C:\Program Files\Puppet Labs\Puppet\bin"

function Write-Step($n, $total, $msg) {
    Write-Host ""
    Write-Host "==> Step $n/$total - $msg" -ForegroundColor Cyan
}

function Write-Skip($msg) {
    Write-Host "    [SKIP] $msg already satisfied" -ForegroundColor DarkGray
}

function Write-Done($msg) {
    Write-Host "    [OK]   $msg" -ForegroundColor Green
}

# --- Step 1: Check / Install Puppet ------------------------------------------
Write-Step 1 6 "Puppet Agent"

$puppetExe = "$PuppetBin\puppet.bat"
if (Test-Path $puppetExe) {
    Write-Skip "Puppet agent"
} else {
    Write-Host "    Downloading Puppet $PuppetVersion..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $PuppetMsiUrl -OutFile $PuppetMsiPath -UseBasicParsing

    Write-Host "    Installing Puppet silently..." -ForegroundColor Yellow
    $result = Start-Process msiexec.exe -ArgumentList "/i `"$PuppetMsiPath`" /qn /norestart INSTALLDIR=`"C:\Program Files\Puppet Labs\Puppet`"" -Wait -PassThru
    if ($result.ExitCode -notin @(0, 1641, 3010)) {
        throw "Puppet MSI install failed with exit code $($result.ExitCode)"
    }
    Write-Done "Puppet agent installed"
}

# Add Puppet bin to PATH for this session
if ($env:PATH -notlike "*Puppet Labs*") {
    $env:PATH = "$PuppetBin;$env:PATH"
}

# --- Step 2: Install puppetlabs-dsc_lite -------------------------------------
Write-Step 2 6 "puppetlabs-dsc_lite module"

$moduleCheck = & "$puppetExe" module list 2>&1 | Select-String "dsc_lite"
if ($moduleCheck) {
    Write-Skip "puppetlabs-dsc_lite"
} else {
    Write-Host "    Installing puppetlabs-dsc_lite..." -ForegroundColor Yellow
    & "$puppetExe" module install puppetlabs-dsc_lite
    if ($LASTEXITCODE -ne 0) { throw "Module install failed" }
    Write-Done "puppetlabs-dsc_lite installed"
}

# --- Step 3: Install puppetlabs-stdlib (dsc_lite dependency) ----------------
Write-Step 3 6 "puppetlabs-stdlib module"

$stdlibCheck = & "$puppetExe" module list 2>&1 | Select-String "stdlib"
if ($stdlibCheck) {
    Write-Skip "puppetlabs-stdlib"
} else {
    Write-Host "    Installing puppetlabs-stdlib..." -ForegroundColor Yellow
    & "$puppetExe" module install puppetlabs-stdlib
    if ($LASTEXITCODE -ne 0) { throw "stdlib install failed" }
    Write-Done "puppetlabs-stdlib installed"
}

# --- Step 4: Download manifest -----------------------------------------------
Write-Step 4 6 "Downloading Jenkins manifest"

$ManifestUrl  = "https://raw.githubusercontent.com/zambrano-luis/jenkins-automation/main/track1-puppet/manifests/jenkins-windows.pp"
$ManifestPath = "C:\jenkins-windows.pp"

if (Test-Path $ManifestPath) {
    Write-Skip "Manifest already present at $ManifestPath"
} else {
    Write-Host "    Downloading jenkins-windows.pp..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $ManifestPath -UseBasicParsing
    if (-not (Test-Path $ManifestPath)) { throw "Manifest download failed" }
    Write-Done "Manifest saved to $ManifestPath"
}

# --- Step 5: Set Java in system PATH -----------------------------------------
Write-Step 5 6 "Setting Java in system PATH"

$JavaBin  = "C:\Program Files\Eclipse Adoptium\jdk-17.0.11.9-hotspot\bin"
$SysPath  = [Environment]::GetEnvironmentVariable("Path", "Machine")

if ($SysPath -like "*Adoptium*") {
    Write-Skip "Java already in system PATH"
} else {
    [Environment]::SetEnvironmentVariable("Path", "$SysPath;$JavaBin", "Machine")
    $env:Path = "$env:Path;$JavaBin"
    Write-Done "Java added to system PATH"
}

# --- Step 6: Apply manifest --------------------------------------------------
Write-Step 6 6 "puppet apply $ManifestPath"

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found at $ManifestPath"
}

& "$puppetExe" apply $ManifestPath --detailed-exitcodes
$puppetExit = $LASTEXITCODE

# puppet apply exit codes:
#   0 = success, no changes
#   2 = success, changes applied
#   4 = failures
#   6 = changes + failures
if ($puppetExit -in @(0, 2)) {
    Write-Host ""
    Write-Host "==> Manifest applied successfully (exit $puppetExit)" -ForegroundColor Green
    Write-Host ""
    Write-Host "    Verifying Jenkins on port 8000..." -ForegroundColor Cyan
    Start-Sleep -Seconds 10
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8000" -UseBasicParsing -TimeoutSec 15
        Write-Host "    Jenkins responded: HTTP $($response.StatusCode)" -ForegroundColor Green
    } catch {
        # 403 comes through as an exception in PowerShell
        if ($_.Exception.Response.StatusCode.value__ -eq 403) {
            Write-Host "    Jenkins responded: HTTP 403 - running and requiring auth. SUCCESS." -ForegroundColor Green
        } else {
            Write-Host "    Jenkins may still be starting. Check: curl http://localhost:8000" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "==> puppet apply exited with code $puppetExit - review output above" -ForegroundColor Red
    exit $puppetExit
}