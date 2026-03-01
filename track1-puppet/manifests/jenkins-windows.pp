# =============================================================================
# jenkins-windows.pp
# Track 1A - Jenkins on Windows Server 2022 via Puppet + DSC Lite
# =============================================================================

# RESOURCE 1 - Download Java 17 MSI
dsc { 'download_java':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "C:\\Windows\\Temp\\java17.msi").ToString() }',
    testscript => 'return (Test-Path "C:\\Windows\\Temp\\java17.msi")',
    setscript  => '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.11%2B9/OpenJDK17U-jdk_x64_windows_hotspot_17.0.11_9.msi" -OutFile "C:\\Windows\\Temp\\java17.msi" -UseBasicParsing',
  },
}

# RESOURCE 2 - Install Java 17
dsc { 'install_java':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "HKLM:\\SOFTWARE\\Eclipse Adoptium\\JDK\\17").ToString() }',
    testscript => 'return (Test-Path "HKLM:\\SOFTWARE\\Eclipse Adoptium\\JDK\\17")',
    setscript  => '$r = Start-Process msiexec.exe -ArgumentList @("/i","C:\\Windows\\Temp\\java17.msi","/qn","/norestart") -Wait -PassThru; if ($r.ExitCode -notin @(0,1641,3010)) { throw "Java MSI failed: $($r.ExitCode)" }',
  },
  require => Dsc['download_java'],
}

# RESOURCE 3 - Download Jenkins MSI
dsc { 'download_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "C:\\Windows\\Temp\\jenkins.msi").ToString() }',
    testscript => 'return (Test-Path "C:\\Windows\\Temp\\jenkins.msi")',
    setscript  => '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri "https://get.jenkins.io/windows/latest" -OutFile "C:\\Windows\\Temp\\jenkins.msi" -UseBasicParsing -MaximumRedirection 5; if ((Get-Item "C:\\Windows\\Temp\\jenkins.msi").Length -lt 1MB) { throw "Jenkins MSI corrupt" }',
  },
  require => Dsc['install_java'],
}

# RESOURCE 4 - Install Jenkins
dsc { 'install_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null).ToString() }',
    testscript => 'return ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null)',
    setscript  => '$r = Start-Process msiexec.exe -ArgumentList @("/i","C:\\Windows\\Temp\\jenkins.msi","/qn","/norestart") -Wait -PassThru; if ($r.ExitCode -notin @(0,1641,3010)) { throw "Jenkins MSI failed: $($r.ExitCode)" }',
  },
  require => Dsc['download_jenkins'],
}

# RESOURCE 5 - Stop Jenkins before config changes
dsc { 'jenkins_stopped_for_config':
  resource_name => 'Service',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name  => 'jenkins',
    state => 'stopped',
  },
  require => Dsc['install_jenkins'],
}

# RESOURCE 6 - Configure jenkins.xml (port 8000 + disable wizard)
dsc { 'configure_jenkins_xml':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => '$xml = Get-Content "C:\\Program Files\\Jenkins\\jenkins.xml" -Raw; return @{ Result = (($xml -match "--httpPort=8000") -and ($xml -match "runSetupWizard=false")).ToString() }',
    testscript => '$xml = Get-Content "C:\\Program Files\\Jenkins\\jenkins.xml" -Raw; return (($xml -match "--httpPort=8000") -and ($xml -match "runSetupWizard=false"))',
    setscript  => '$xml = Get-Content "C:\\Program Files\\Jenkins\\jenkins.xml" -Raw; $xml = $xml -replace "--httpPort=\\d+","--httpPort=8000"; if ($xml -notmatch "runSetupWizard=false") { $xml = $xml -replace "(<arguments>[^<]+)(</arguments>)","$1 -Djenkins.install.runSetupWizard=false`$2" }; Set-Content -Path "C:\\Program Files\\Jenkins\\jenkins.xml" -Value $xml -Encoding UTF8',
  },
  require => Dsc['jenkins_stopped_for_config'],
}

# RESOURCE 7 - Ensure Jenkins is running
dsc { 'jenkins_running':
  resource_name => 'Service',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name        => 'jenkins',
    state       => 'running',
    startuptype => 'Automatic',
  },
  require => Dsc['configure_jenkins_xml'],
}