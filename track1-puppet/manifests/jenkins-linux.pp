# =============================================================================
# Jenkins Automation — Track 1: Puppet Manifest (Masterless)
# =============================================================================
# Declares the desired state for a Jenkins CI server on Ubuntu 22.04 LTS.
# Applied via: puppet apply manifests/jenkins.pp
#
# Requirements satisfied:
#   A) Runs on a clean OS — all dependencies declared and managed by Puppet
#   B) Fully unattended — no prompts, no wizard, no manual steps
#   C) Jenkins listens on port 8000 natively via systemd override
#   D) Idempotent — Puppet converges to desired state on every run
#
# External modules required:
#   puppetlabs-apt — manages GPG keys and apt sources
#
# Author: Luis Zambrano
# =============================================================================

class jenkins {

  # ---------------------------------------------------------------------------
  # Initialize the apt class — required before using apt::key or apt::source
  # ---------------------------------------------------------------------------
  class { 'apt': }

  # ---------------------------------------------------------------------------
  # STEP 1 — Jenkins GPG Key
  # ---------------------------------------------------------------------------
  # Puppet manages the key file directly using apt::key.
  # Idempotency: Puppet checks the key ID against the keyring on every run.
  # If the key is already present it is skipped entirely.
  # ---------------------------------------------------------------------------
  apt::key { 'jenkins':
    id     => 'FCEF32E745F2C3D5084B4C51B8C18D2E447CC5E3',
    source => 'https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key',
    server => 'keyserver.ubuntu.com',
  }

  # ---------------------------------------------------------------------------
  # STEP 2 — Jenkins apt Repository
  # ---------------------------------------------------------------------------
  # apt::source declares the Jenkins Debian repo. Puppet writes the source
  # file and runs apt-get update automatically when the source changes.
  # Idempotency: Puppet compares the file content on every run and skips
  # if already correct.
  # ---------------------------------------------------------------------------
  apt::source { 'jenkins':
    location => 'https://pkg.jenkins.io/debian-stable',
    repos    => 'binary/',
    release  => ' ',
    key      => {
      id     => 'FCEF32E745F2C3D5084B4C51B8C18D2E447CC5E3',
      source => 'https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key',
    },
    require  => Apt::Key['jenkins'],
  }

  # ---------------------------------------------------------------------------
  # STEP 3 — Java 17
  # ---------------------------------------------------------------------------
  # Jenkins requires Java 17+. Puppet's package resource checks dpkg state
  # before acting — if already installed the resource is skipped.
  # ---------------------------------------------------------------------------
  package { 'openjdk-17-jdk':
    ensure  => installed,
    require => Apt::Source['jenkins'],
  }

  # ---------------------------------------------------------------------------
  # STEP 4 — Jenkins Package
  # ---------------------------------------------------------------------------
  # Depends on Java and the apt source being present first.
  # Idempotency: package ensure => installed is a no-op if already installed.
  # ---------------------------------------------------------------------------
  package { 'jenkins':
    ensure  => installed,
    require => [Package['openjdk-17-jdk'], Apt::Source['jenkins']],
  }

  # ---------------------------------------------------------------------------
  # STEP 5 — systemd Drop-in Override Directory
  # ---------------------------------------------------------------------------
  # Ensures the override directory exists before writing the override file.
  # ---------------------------------------------------------------------------
  file { '/etc/systemd/system/jenkins.service.d':
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    require => Package['jenkins'],
  }

  # ---------------------------------------------------------------------------
  # STEP 6 — systemd Override (Port 8000 + Wizard Disable)
  # ---------------------------------------------------------------------------
  # A single drop-in file sets both JENKINS_PORT=8000 (Req C) and disables
  # the setup wizard (Req B). Puppet uses the ~> notify arrow to the service
  # below — if this file changes Puppet automatically restarts Jenkins.
  # If the file is already correct no restart occurs.
  #
  # This is the key difference from Track 2 — in Python we had to manually
  # track return values and conditionally restart. Here Puppet's notify
  # relationship handles that automatically and declaratively.
  # ---------------------------------------------------------------------------
  file { '/etc/systemd/system/jenkins.service.d/override.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "[Service]\nEnvironment=\"JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false\"\nEnvironment=\"JENKINS_PORT=8000\"\n",
    require => File['/etc/systemd/system/jenkins.service.d'],
  }

  # ---------------------------------------------------------------------------
  # STEP 7 — Reload systemd after override change
  # ---------------------------------------------------------------------------
  # Runs systemctl daemon-reload when the override file changes.
  # The refreshonly => true means this exec ONLY runs when notified by a
  # resource change — never on a clean re-run where nothing changed.
  # ---------------------------------------------------------------------------
  exec { 'systemd-daemon-reload':
    command     => '/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/jenkins.service.d/override.conf'],
  }

  # ---------------------------------------------------------------------------
  # STEP 8 — Jenkins Service
  # ---------------------------------------------------------------------------
  # Declares Jenkins should be running and enabled on boot.
  # The ~> notify relationship from the override file means Puppet will
  # restart Jenkins automatically if the override changes.
  # On a clean re-run where nothing changed, no restart occurs.
  # ---------------------------------------------------------------------------
  service { 'jenkins':
    ensure    => running,
    enable    => true,
    require   => [
      Package['jenkins'],
      Exec['systemd-daemon-reload'],
    ],
    subscribe => File['/etc/systemd/system/jenkins.service.d/override.conf'],
  }

}

# Apply the class
include jenkins