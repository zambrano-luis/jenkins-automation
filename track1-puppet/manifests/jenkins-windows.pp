# =============================================================================
# jenkins-windows.pp
# Track 1A - Jenkins on Windows Server 2022 via Puppet + DSC Lite
#
# Uses puppetlabs-dsc_lite to delegate all Windows-native operations
# to DSC resources. No exec blocks. All resources carry proper
# Test/Set/Get blocks for native idempotency.
#
# Requirements satisfied:
#   Req A - Unattended clean install
#   Req B - No manual intervention (wizard disabled)
#   Req C - Jenkins binds to port 8000
#   Req D - Idempotent (DSC test blocks check current state before acting)
# =============================================================================

# --- Variables ---------------------------------------------------------------
$java_url     = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.11%2B9/OpenJDK17U-jdk_x64_windows_hotspot_17.0.11_9.msi'
$java_msi     = 'C:\Windows\Temp\java17.msi'
$java_reg_key = 'HKLM:\SOFTWARE\Eclipse Adoptium\JDK\17'

$jenkins_url  = 'https://get.jenkins.io/windows/latest'
$jenkins_msi  = 'C:\Windows\Temp\jenkins.msi'
$jenkins_xml  = 'C:\Program Files\Jenkins\jenkins.xml'
$jenkins_port = '8000'

# =============================================================================
# RESOURCE 1 - Download Java 17 MSI
# Test: MSI file already on disk
# Set:  Invoke-WebRequest to download it
# =============================================================================
dsc { 'download_java':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "C:\Windows\Temp\java17.msi").ToString() }',
    testscript => 'return (Test-Path "C:\Windows\Temp\java17.msi")',
    setscript  => @("
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Write-Verbose 'Downloading Java 17 MSI...'
      Invoke-WebRequest -Uri '${java_url}' -OutFile '${java_msi}' -UseBasicParsing
      Write-Verbose 'Java 17 MSI downloaded.'
    "~),
  },
}

# =============================================================================
# RESOURCE 2 - Install Java 17
# Test: Registry key for Adoptium JDK 17 exists
# Set:  Run MSI silently, wait for completion
# =============================================================================
dsc { 'install_java':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "HKLM:\SOFTWARE\Eclipse Adoptium\JDK\17").ToString() }',
    testscript => 'return (Test-Path "HKLM:\SOFTWARE\Eclipse Adoptium\JDK\17")',
    setscript  => @("
      Write-Verbose 'Installing Java 17...'
      \$result = Start-Process msiexec.exe -ArgumentList '/i', '${java_msi}', '/qn', '/norestart' -Wait -PassThru
      if (\$result.ExitCode -notin @(0, 1641, 3010)) {
        throw \"Java MSI install failed with exit code \$(\$result.ExitCode)\"
      }
      Write-Verbose 'Java 17 installed.'
    "~),
  },
  require       => Dsc['download_java'],
}

# =============================================================================
# RESOURCE 3 - Download Jenkins MSI
# Test: MSI file already on disk
# Set:  Invoke-WebRequest to download it
# =============================================================================
dsc { 'download_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "C:\Windows\Temp\jenkins.msi").ToString() }',
    testscript => 'return (Test-Path "C:\Windows\Temp\jenkins.msi")',
    setscript  => @("
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Write-Verbose 'Downloading Jenkins MSI...'
      Invoke-WebRequest -Uri '${jenkins_url}' -OutFile '${jenkins_msi}' -UseBasicParsing
      if ((Get-Item '${jenkins_msi}').Length -lt 1MB) {
        throw 'Jenkins MSI download appears corrupt - file too small'
      }
      Write-Verbose 'Jenkins MSI downloaded.'
    "~),
  },
  require       => Dsc['install_java'],
}

# =============================================================================
# RESOURCE 4 - Install Jenkins
# Test: Jenkins Windows service exists
# Set:  Run MSI silently, wait for completion
# =============================================================================
dsc { 'install_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null).ToString() }',
    testscript => 'return ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null)',
    setscript  => @("
      Write-Verbose 'Installing Jenkins...'
      \$result = Start-Process msiexec.exe -ArgumentList '/i', '${jenkins_msi}', '/qn', '/norestart' -Wait -PassThru
      if (\$result.ExitCode -notin @(0, 1641, 3010)) {
        throw \"Jenkins MSI install failed with exit code \$(\$result.ExitCode)\"
      }
      Write-Verbose 'Jenkins installed.'
    "~),
  },
  require       => Dsc['download_jenkins'],
}

# =============================================================================
# RESOURCE 5 - Stop Jenkins before config changes
# DSC native service resource - no script needed
# =============================================================================
dsc { 'jenkins_stopped_for_config':
  resource_name => 'Service',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name   => 'jenkins',
    ensure => 'stopped',
    state  => 'stopped',
  },
  require       => Dsc['install_jenkins'],
}

# =============================================================================
# RESOURCE 6 - Configure jenkins.xml
# Test: jenkins.xml already contains correct port and wizard flag
# Set:  Regex replace httpPort and inject runSetupWizard=false into JAVA_ARGS
#
# jenkins.xml stores the service arguments on one line inside <arguments>.
# We replace --httpPort=#### with --httpPort=8000 and add the wizard flag
# if not already present. File is owned by Jenkins MSI install.
# =============================================================================
dsc { 'configure_jenkins_xml':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => @("
      \$xml = Get-Content '${jenkins_xml}' -Raw
      \$portOk   = \$xml -match '--httpPort=${jenkins_port}'
      \$wizardOk = \$xml -match 'runSetupWizard=false'
      return @{ Result = (\$portOk -and \$wizardOk).ToString() }
    "~),
    testscript => @("
      \$xml = Get-Content '${jenkins_xml}' -Raw
      \$portOk   = \$xml -match '--httpPort=${jenkins_port}'
      \$wizardOk = \$xml -match 'runSetupWizard=false'
      return (\$portOk -and \$wizardOk)
    "~),
    setscript  => @("
      Write-Verbose 'Configuring jenkins.xml...'
      \$xml = Get-Content '${jenkins_xml}' -Raw

      # Replace whatever httpPort value is present with 8000
      \$xml = \$xml -replace '--httpPort=\d+', '--httpPort=${jenkins_port}'

      # Inject wizard flag into arguments line if not already present
      if (\$xml -notmatch 'runSetupWizard=false') {
        \$xml = \$xml -replace '(<arguments>[^<]+)(</arguments>)', '\$1 -Djenkins.install.runSetupWizard=false\$2'
      }

      Set-Content -Path '${jenkins_xml}' -Value \$xml -Encoding UTF8
      Write-Verbose 'jenkins.xml updated: port ${jenkins_port}, wizard disabled.'
    "~),
  },
  require       => Dsc['jenkins_stopped_for_config'],
}

# =============================================================================
# RESOURCE 7 - Ensure Jenkins service is running
# DSC native service resource
# Depends on config being applied first
# =============================================================================
dsc { 'jenkins_running':
  resource_name => 'Service',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name        => 'jenkins',
    ensure      => 'running',
    state       => 'running',
    startuptype => 'Automatic',
  },
  require       => Dsc['configure_jenkins_xml'],
}
