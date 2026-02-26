# =============================================================================
# Jenkins Automation — Track 1A: Puppet Manifest (Windows)
# =============================================================================
# Declares the desired state for a Jenkins CI server on Windows Server 2022.
# Applied via: puppet apply manifests\jenkins-windows.pp
#
# Requirements satisfied:
#   A) Runs on a clean OS — all dependencies declared and managed by Puppet
#   B) Fully unattended — no prompts, no wizard, silent MSI install
#   C) Jenkins listens on port 8000 natively via MSI PORT parameter
#   D) Idempotent — Puppet converges to desired state on every run
#
# External modules required:
#   puppetlabs-registry — manages Windows registry values
#
# Author: Luis Zambrano
# =============================================================================

class jenkins_windows {

  # ---------------------------------------------------------------------------
  # STEP 1 — Install Java 17
  # ---------------------------------------------------------------------------
  # Downloads and installs OpenJDK 17 from Microsoft's build.
  # Idempotent: checks registry for existing Java 17 installation before acting.
  # The exec only runs if Java 17 is not already installed.
  # ---------------------------------------------------------------------------
  $java_installer = 'C:\Windows\Temp\openjdk17.msi'
  $java_url       = 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.msi'

  exec { 'download-java':
    command  => "Invoke-WebRequest -Uri '${java_url}' -OutFile '${java_installer}' -UseBasicParsing",
    provider => powershell,
    creates  => $java_installer,
  }

  exec { 'install-java':
    command  => "Start-Process msiexec.exe -ArgumentList '/i ${java_installer} /qn /norestart ADDLOCAL=FeatureMain' -Wait -PassThru",
    provider => powershell,
    require  => Exec['download-java'],
    unless   => 'if (Get-Command java -ErrorAction SilentlyContinue) { java -version 2>&1 | Select-String "17\." } else { exit 1 }',
  }

  # ---------------------------------------------------------------------------
  # STEP 2 — Download Jenkins MSI (latest LTS)
  # ---------------------------------------------------------------------------
  # Queries the Jenkins update center for the current LTS version number,
  # constructs the MSI download URL dynamically, and downloads it.
  # Idempotent: only downloads if the MSI file does not already exist.
  # ---------------------------------------------------------------------------
  $jenkins_msi = 'C:\Windows\Temp\jenkins.msi'

  exec { 'download-jenkins':
    command  => @("POWERSHELL")
      $json    = Invoke-RestMethod -Uri 'https://updates.jenkins.io/stable/update-center.actual.json' -UseBasicParsing
      $version = $json.core.version
      $url     = "https://get.jenkins.io/windows-stable/$version/jenkins.msi"
      Invoke-WebRequest -Uri $url -OutFile '${jenkins_msi}' -UseBasicParsing
      | POWERSHELL
    ,
    provider => powershell,
    creates  => $jenkins_msi,
    require  => Exec['install-java'],
  }

  # ---------------------------------------------------------------------------
  # STEP 3 — Install Jenkins
  # ---------------------------------------------------------------------------
  # Installs Jenkins silently via MSI with PORT=8000 set at install time.
  # This satisfies Req C natively — no post-install config needed for the port.
  # Idempotent: only runs if the Jenkins service does not already exist.
  # ---------------------------------------------------------------------------
  exec { 'install-jenkins':
    command  => "Start-Process msiexec.exe -ArgumentList '/i ${jenkins_msi} /qn /norestart PORT=8000 JENKINSDIR=\"C:\\Program Files\\Jenkins\"' -Wait",
    provider => powershell,
    require  => Exec['download-jenkins'],
    unless   => 'if (Get-Service jenkins -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }',
  }

  # ---------------------------------------------------------------------------
  # STEP 4 — Disable Setup Wizard
  # ---------------------------------------------------------------------------
  # Sets JAVA_OPTS in the Windows registry to disable the setup wizard.
  # The registry key is read by the Jenkins Windows service wrapper on startup.
  # Idempotent: registry_value ensures the key exists with the correct value.
  # If already set correctly Puppet skips this resource entirely.
  #
  # Key difference from Linux: no systemd override needed — Windows uses
  # the registry to pass environment variables to services.
  # ---------------------------------------------------------------------------
  registry_value { 'HKLM\SYSTEM\CurrentControlSet\Services\Jenkins\Parameters\JAVA_OPTS':
    ensure => present,
    type   => string,
    data   => '-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false',
    require => Exec['install-jenkins'],
  }

  # ---------------------------------------------------------------------------
  # STEP 5 — Ensure Jenkins service is running and enabled
  # ---------------------------------------------------------------------------
  # Puppet's service resource works identically on Windows and Linux.
  # enable => true sets the service to Automatic start.
  # ensure => running starts it if stopped.
  # subscribe means Puppet restarts Jenkins if the registry value changes.
  # ---------------------------------------------------------------------------
  service { 'jenkins':
    ensure    => running,
    enable    => true,
    require   => Exec['install-jenkins'],
    subscribe => Registry_value['HKLM\SYSTEM\CurrentControlSet\Services\Jenkins\Parameters\JAVA_OPTS'],
  }

}

# Apply the class
include jenkins_windows