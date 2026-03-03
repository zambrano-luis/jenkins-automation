# =============================================================================
# jenkins-windows.pp
# Track 1A - Jenkins on Windows Server 2022 via Puppet + DSC Lite
#
# Resource chain:
#   download_java -> install_java -> set_java_home -> set_java_path
#   -> download_jenkins -> install_jenkins -> configure_and_start_jenkins
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
    getscript  => 'return @{ Result = (Test-Path "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe").ToString() }',
    testscript => 'return (Test-Path "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe")',
    setscript  => '$r = Start-Process msiexec.exe -ArgumentList @("/i","C:\\Windows\\Temp\\java17.msi","/qn","/norestart") -Wait -PassThru; if ($r.ExitCode -notin @(0,1641,3010)) { throw "Java MSI failed: $($r.ExitCode)" }',
  },
  require => Dsc['download_java'],
}

# RESOURCE 3 - Set JAVA_HOME
dsc { 'set_java_home':
  resource_name => 'Environment',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name   => 'JAVA_HOME',
    value  => 'C:\Program Files\Eclipse Adoptium\jdk-17.0.11.9-hotspot',
    ensure => 'present',
  },
  require => Dsc['install_java'],
}

# RESOURCE 4 - Add Java to system PATH
dsc { 'set_java_path':
  resource_name => 'Environment',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name   => 'Path',
    value  => 'C:\Program Files\Eclipse Adoptium\jdk-17.0.11.9-hotspot\bin',
    ensure => 'present',
    path   => true,
  },
  require => Dsc['set_java_home'],
}

# RESOURCE 5 - Download Jenkins MSI
dsc { 'download_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = (Test-Path "C:\\Windows\\Temp\\jenkins.msi").ToString() }',
    testscript => 'return (Test-Path "C:\\Windows\\Temp\\jenkins.msi")',
    setscript  => '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object System.Net.WebClient).DownloadFile("https://get.jenkins.io/windows-stable/2.528.2/jenkins.msi","C:\\Windows\\Temp\\jenkins.msi"); if ((Get-Item "C:\\Windows\\Temp\\jenkins.msi").Length -lt 1MB) { throw "Jenkins MSI corrupt" }',
  },
  require => Dsc['set_java_path'],
}

# RESOURCE 6 - Install Jenkins
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

# RESOURCE 7 - Configure Jenkins and ensure it is running correctly
# testscript checks ALL conditions in one shot:
#   - Jenkins service is running
#   - Listening on port 8000
#   - jenkins.xml points to java.exe with correct args
#   - Wizard state files present
#   - Firewall rule exists
# Only runs setscript if any condition fails.
# setscript stops service, fixes everything, starts service.
dsc { 'configure_and_start_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => '
      $svc     = (Get-Service jenkins -ErrorAction SilentlyContinue)
      $running = ($svc -ne $null -and $svc.Status -eq "Running")
      $port    = (netstat -an | Select-String ":8000.*LISTENING") -ne $null
      $xmlOk   = $false
      $p = "C:\\Program Files\\Jenkins\\jenkins.xml"
      if (Test-Path $p) { $xml = Get-Content $p -Raw; $xmlOk = ($xml -match "--httpPort=8000") -and ($xml -match "java.exe") -and ($xml -match "runSetupWizard=false") }
      $wizardOk = (Test-Path "C:\\Windows\\system32\\config\\systemprofile\\.jenkins\\jenkins.install.InstallUtil.lastExecVersion")
      $fwOk    = ((Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue) -ne $null)
      return @{ Result = ($running -and $port -and $xmlOk -and $wizardOk -and $fwOk).ToString() }
    ',
    testscript => '
      $svc     = (Get-Service jenkins -ErrorAction SilentlyContinue)
      $running = ($svc -ne $null -and $svc.Status -eq "Running")
      $port    = (netstat -an | Select-String ":8000.*LISTENING") -ne $null
      $xmlOk   = $false
      $p = "C:\\Program Files\\Jenkins\\jenkins.xml"
      if (Test-Path $p) { $xml = Get-Content $p -Raw; $xmlOk = ($xml -match "--httpPort=8000") -and ($xml -match "java.exe") -and ($xml -match "runSetupWizard=false") }
      $wizardOk = (Test-Path "C:\\Windows\\system32\\config\\systemprofile\\.jenkins\\jenkins.install.InstallUtil.lastExecVersion")
      $fwOk    = ((Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue) -ne $null)
      return ($running -and $port -and $xmlOk -and $wizardOk -and $fwOk)
    ',
    setscript  => '
      Stop-Service jenkins -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 3

      $p    = "C:\\Program Files\\Jenkins\\jenkins.xml"
      $java = "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe"
      $war  = "C:\\Program Files\\Jenkins\\jenkins.war"
      $xml  = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<service>`r`n  <id>Jenkins</id>`r`n  <n>Jenkins</n>`r`n  <description>Jenkins Automation Server</description>`r`n  <executable>$java</executable>`r`n  <arguments>-Xrs -Xmx256m -Dhudson.lifecycle=hudson.lifecycle.WindowsServiceLifecycle -jar `"$war`" --httpPort=8000 --webroot=`"%LocalAppData%\\Jenkins\\war`" -Djenkins.install.runSetupWizard=false</arguments>`r`n  <logmode>rotate</logmode>`r`n</service>"
      Set-Content -Path $p -Value $xml -Encoding UTF8

      $d = "C:\\Windows\\system32\\config\\systemprofile\\.jenkins"
      if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force }
      Set-Content -Path "$d\\jenkins.install.InstallUtil.lastExecVersion" -Value "2.528.2"
      Set-Content -Path "$d\\jenkins.install.UpgradeWizard.state" -Value "2.528.2"

      if (-not (Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Jenkins-8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any
      }

      Start-Service jenkins
    ',
  },
  require => Dsc['install_jenkins'],
}