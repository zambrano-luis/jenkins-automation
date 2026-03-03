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
    getscript  => 'return @{ Result = (Test-Path "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe").ToString() }',
    testscript => 'return (Test-Path "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe")',
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
    setscript  => '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object System.Net.WebClient).DownloadFile("https://get.jenkins.io/windows-stable/2.528.2/jenkins.msi","C:\\Windows\\Temp\\jenkins.msi"); if ((Get-Item "C:\\Windows\\Temp\\jenkins.msi").Length -lt 1MB) { throw "Jenkins MSI corrupt" }',
  },
  require => Dsc['install_java'],
}

# RESOURCE 4 - Set JAVA_HOME system environment variable
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

# RESOURCE 5 - Add Java bin to system PATH
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

# RESOURCE 6 - Install Jenkins
dsc { 'install_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => 'return @{ Result = ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null).ToString() }',
    testscript => 'return ((Get-Service -Name jenkins -ErrorAction SilentlyContinue) -ne $null)',
    setscript  => '$r = Start-Process msiexec.exe -ArgumentList @("/i","C:\\Windows\\Temp\\jenkins.msi","/qn","/norestart") -Wait -PassThru; if ($r.ExitCode -notin @(0,1641,3010)) { throw "Jenkins MSI failed: $($r.ExitCode)" }',
  },
  require => Dsc['set_java_path'],
}
# RESOURCE 7 - Stop Jenkins before config changes
dsc { 'jenkins_stopped_for_config':
  resource_name => 'Service',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    name  => 'jenkins',
    state => 'stopped',
  },
  require => Dsc['install_jenkins'],
}

# RESOURCE 8 - Configure jenkins.xml (port 8000 + disable wizard, create if missing)
dsc { 'configure_jenkins_xml':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    getscript  => '$p = "C:\\Program Files\\Jenkins\\jenkins.xml"; if (-not (Test-Path $p)) { return @{ Result = "False" } }; $xml = Get-Content $p -Raw; return @{ Result = (($xml -match "--httpPort=8000") -and ($xml -match "runSetupWizard=false") -and ($xml -notmatch "version=.1\.1.")).ToString() }',
    testscript => '$p = "C:\\Program Files\\Jenkins\\jenkins.xml"; if (-not (Test-Path $p)) { return $false }; $xml = Get-Content $p -Raw; return (($xml -match "--httpPort=8000") -and ($xml -match "runSetupWizard=false") -and ($xml -notmatch "version=.1\.1."))',
    setscript  => '$p = "C:\\Program Files\\Jenkins\\jenkins.xml"; $args = "-Xrs -Xmx256m -Dhudson.lifecycle=hudson.lifecycle.WindowsServiceLifecycle -jar `"C:\\Program Files\\Jenkins\\jenkins.war`" --httpPort=8000 --webroot=`"%LocalAppData%\\Jenkins\\war`" -Djenkins.install.runSetupWizard=false"; if (Test-Path $p) { $xml = Get-Content $p -Raw; $xml = $xml -replace "version=`"1.1`"","version=`"1.0`""; $xml = [regex]::Replace($xml,"(?s)<jvmOptions>.*?</jvmOptions>\r?\n\s*",""); $xml = [regex]::Replace($xml,"(?s)<arguments>.*?</arguments>","<arguments>$args</arguments>"); Set-Content -Path $p -Value $xml -Encoding UTF8 } else { $template = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<service>`r`n  <id>Jenkins</id>`r`n  <name>Jenkins</name>`r`n  <description>Jenkins Automation Server</description>`r`n  <executable>%BASE%\\jenkins.exe</executable>`r`n  <arguments>$args</arguments>`r`n  <logmode>rotate</logmode>`r`n</service>"; Set-Content -Path $p -Value $template -Encoding UTF8 }',
  },
  require => Dsc['jenkins_stopped_for_config'],
}

# RESOURCE 9 - Ensure Jenkins is running
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