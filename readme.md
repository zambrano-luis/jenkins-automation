# Jenkins Automation

Automated installation and configuration of Jenkins CI server across multiple platforms and toolchains. This repository is a technical assessment submission demonstrating infrastructure automation, idempotency, and cross-platform provisioning.

Jenkins is configured to listen natively on **port 8000** in all tracks - not via port forwarding, proxy, or NAT.

---

## Requirements

Every track in this repository satisfies the same four requirements:

| Req | Description |
|-----|-------------|
| **A** | Runs on a clean OS installation without errors |
| **B** | Jenkins and prerequisites install without manual intervention |
| **C** | Jenkins itself listens on port 8000 - not a proxy or forward |
| **D** | Re-running produces no failures and no duplicate configuration |

---

## Repository Structure

```
jenkins-automation/
├── README.md
├── track1-puppet/
│   ├── manifests/
│   │   ├── jenkins-linux.pp                      # Puppet manifest - Linux (Track 1B)
│   │   └── jenkins-windows.pp                    # Puppet manifest - Windows DSC (Track 1A)
│   ├── install_jenkins_puppet.py                 # Track 1B bootstrap - Python -> puppet apply
│   ├── install_jenkins_puppet_dsc.ps1            # Track 1A bootstrap - PowerShell -> puppet apply
│   ├── deploy-track1-linux.ps1                   # AWS deploy script - Linux EC2
│   └── deploy-track1-windows.ps1                 # AWS deploy script - Windows EC2
├── track2-python/
│   ├── install_jenkins.py                        # Pure Python installer - Ubuntu 22.04 LTS
│   ├── deploy-track2-linux.ps1                   # PowerShell deploy script (Windows host)
│   ├── deploy-track2-linux.sh                    # Bash deploy script (Linux/macOS host)
│   ├── cleanup-track2-linux.ps1                  # PowerShell cleanup script
│   └── cleanup-track2-linux.sh                   # Bash cleanup script
└── aws-demo-cf-templates/
    ├── jenkins-linux-puppet.yaml                 # CloudFormation - Ubuntu EC2 (Track 1B)
    ├── jenkins-linux.yaml                        # CloudFormation - Ubuntu EC2 (Track 2)
    └── jenkins-windows-puppet.yaml               # CloudFormation - Windows Server 2022 EC2 (Track 1A)
```

---

## Tracks

### Track 1B - Python + Puppet (Linux)

The Python bootstrap installs Puppet agent silently, installs required modules, then runs `puppet apply` against the Linux manifest. The manifest uses native Puppet resource types (`package`, `service`, `file_line`) for clean declarative configuration.

**Validated on:** Ubuntu 22.04 LTS, AWS EC2 t3.medium

```bash
sudo python3 track1-puppet/install_jenkins_puppet.py
```

---

### Track 1A - PowerShell + Puppet + DSC (Windows)

The PowerShell bootstrap installs Puppet agent, installs `puppetlabs-dsc_lite` and `puppetlabs-stdlib`, sets `JAVA_HOME` and `PATH` for Java, downloads the manifest, then runs `puppet apply`. The manifest delegates all Windows-native operations to DSC resources — no exec blocks.

**Validated on:** Windows Server 2022, AWS EC2 t3.medium

> **Note:** The Windows manifest uses DSC resources and diverges significantly from the Linux manifest. Windows requires explicit Java path management, MSI-based package installation, service wrapper configuration, and Windows Firewall rules. A shared cross-OS manifest was attempted but proved impractical — the bootstraps differ, the package managers differ, and the config file paths differ.

```powershell
powershell.exe -ExecutionPolicy Bypass -File track1-puppet\install_jenkins_puppet_dsc.ps1
```

---

### Track 2 - Pure Python (Linux)

Single self-contained script. No dependencies beyond Python 3 stdlib. Designed for Ubuntu 20.04+ LTS where Python 3 ships by default.

**Validated on:** Ubuntu 22.04 LTS, AWS EC2 t3.medium

```bash
sudo python3 track2-python/install_jenkins.py
```

---

## AWS Demo - CloudFormation

Provisions a fully self-contained EC2 environment including VPC security group, IAM role, and SSH/RDP key pair. The instance pulls the provisioning script directly from this repository via UserData on first boot.

The key pair is created by the stack and stored in AWS SSM Parameter Store. Retrieved automatically by the deploy scripts. Deleted when the stack is deleted.

**Prerequisites:**
- AWS CLI installed and configured
- Active AWS session (SSO, access keys, or instance profile)

---

### Track 1B - Linux (Puppet)

```powershell
powershell.exe -ExecutionPolicy Bypass -File track1-puppet\deploy-track1-linux.ps1
```

Optional parameters:
```powershell
... -StackName my-stack -Region us-east-1
```

The deploy script handles the full flow automatically:
1. Validate AWS session
2. Detect your public IP and lock the security group to it
3. Deploy the CloudFormation stack
4. Retrieve stack outputs
5. Pull the private key from SSM Parameter Store
6. Set correct key file permissions
7. Print Jenkins URL and SSH command

---

### Track 1A - Windows (Puppet + DSC)

```powershell
powershell.exe -ExecutionPolicy Bypass -File track1-puppet\deploy-track1-windows.ps1
```

The deploy script polls for the Administrator RDP password and decrypts it using the private key. Credentials are printed to the console once available — allow 4-10 minutes after stack creation.

> **Note:** The CloudFormation stack creates a named IAM role. The `CAPABILITY_NAMED_IAM` flag is required and passed automatically by the deploy script.

---

### Track 2 - Linux (Pure Python)

**Deploy - Windows (PowerShell):**
```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\deploy-track2-linux.ps1
```

**Deploy - Linux / macOS (Bash):**
```bash
chmod +x track2-python/*.sh
./track2-python/deploy-track2-linux.sh
```

**Cleanup:**
```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\cleanup-track2-linux.ps1
```
```bash
./track2-python/cleanup-track2-linux.sh
```

---

## Validating Jenkins is Running

After any track completes, confirm Jenkins is running on port 8000:

**Linux:**
```bash
curl -I http://localhost:8000
```

**Windows:**
```powershell
(Invoke-WebRequest -Uri "http://localhost:8000" -UseBasicParsing).StatusCode
```

Expected response: `HTTP 403 Forbidden` — Jenkins is running and requiring authentication. 403 is not an error.

---

## Idempotency

All tracks are safe to re-run. Each step checks current state before acting:

- **Track 2 (Python):** Explicit guard checks before every step — package installations check `dpkg` status, config edits check for existing values, service restarts only triggered if config changed
- **Track 1B (Puppet Linux):** Puppet's declarative model converges to desired state natively — resources only apply if current state differs from desired state
- **Track 1A (Puppet + DSC Windows):** DSC resources use Get/Test/Set pattern. The final `configure_and_start_jenkins` resource checks all conditions in a single test: service running, port 8000 listening, `jenkins.xml` correct, wizard disabled, firewall rule present. Jenkins is only stopped and reconfigured if any one condition fails.

Re-running any script against an already-provisioned system skips all completed steps and exits cleanly.

---

## Windows Track - Known Challenges

The Windows track required significantly more engineering effort than Linux due to platform-specific constraints:

- Jenkins MSI requires `JAVA_HOME` and Java in system `PATH` before the service installer runs — environment variables set mid-session are not inherited by the MSI's service start process
- `jenkins.exe` is a WinSW service wrapper — the `<executable>` in `jenkins.xml` must point directly to `java.exe`, not back to `jenkins.exe`
- Setup wizard requires explicit state files (`jenkins.install.InstallUtil.lastExecVersion`) in addition to the `-Djenkins.install.runSetupWizard=false` JVM flag
- Windows Firewall must be opened separately from the AWS security group
- DSC sessions run as SYSTEM in isolation — changes made in one DSC resource are not guaranteed to be visible to subsequent resources

These challenges are documented in the assessment presentation (slide 08) as part of the "what I'd do differently" reflection.

---

## Minimum Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 2 GB | 4 GB |
| CPU | 1 core | 2 cores |
| Disk | 10 GB | 20 GB |
| OS (Linux) | Ubuntu 20.04 LTS | Ubuntu 22.04 LTS |
| OS (Windows) | Windows Server 2019 | Windows Server 2022 |
| AWS Instance | t3.small | t3.medium |

---

## Assumptions

- Linux tracks assume a Debian-based distribution (Ubuntu 20.04+)
- Scripts must be run as root (`sudo`) on Linux
- Windows scripts must be run with `-ExecutionPolicy Bypass` or from an elevated session
- Internet access is required to download Jenkins, Java, and the Puppet agent
- AWS CLI must be configured with appropriate permissions to deploy CloudFormation stacks
- AWS deploy scripts default to `us-west-2` — pass `-Region` to override

---

## Author

Luis Zambrano - [github.com/zambrano-luis](https://github.com/zambrano-luis)

---

## Appendix > Windows Lessons Learned

This section documents every issue encountered implementing Track 1A on Windows Server 2022. The Linux track ran cleanly on first attempt. The Windows track required seven distinct debugging cycles. Each issue includes the original assumption, what actually happened, and the specific code change that fixed it.

---

### Why We Switched to DSC

The original Track 1A manifest used the same `exec`-based approach as Linux — wrapping shell commands in Puppet `exec` resources. This worked on Linux but failed on Windows because:

- `exec` on Windows spawns `cmd.exe`, which has different quoting rules, path handling, and environment inheritance than PowerShell
- Windows package management (MSI) has no clean Puppet native type equivalent
- Service lifecycle on Windows requires registry and environment state that `exec` cannot manage cleanly

The switch to `puppetlabs-dsc_lite` delegates all Windows operations to **DSC (Desired State Configuration)** — Microsoft's own declarative automation layer. Every resource becomes a `dsc {}` block with three PowerShell scriptblocks: `getscript`, `testscript`, and `setscript`. Puppet calls `testscript` first and only runs `setscript` if the test returns false — exactly how Puppet's native resources work.

**Before (exec-based approach — failed):**
```puppet
exec { 'install_jenkins':
  command  => 'msiexec /i C:\jenkins.msi /qn',
  provider => 'windows',
  unless   => 'sc query jenkins',
}
```

**After (DSC approach — working):**
```puppet
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
```

The bootstrap script (`install_jenkins_puppet_dsc.ps1`) installs the required modules before running the manifest:

```powershell
puppet module install puppetlabs-dsc_lite
puppet module install puppetlabs-stdlib
```

---

### Issue 1 — Puppet Module Version Range Syntax

**Wrong assumption:** Version range syntax from Puppet Forge docs would work in PowerShell.

```powershell
# BROKE - nested quoting mangled by PowerShell -> Puppet argument parser
puppet module install puppetlabs-dsc_lite --version "'>= 1.0.0 < 2.0.0'"
# Error: Unparsable version range: "'>= 1.0.0 < 2.0.0'"
```

**Fix in `install_jenkins_puppet_dsc.ps1`:** Remove the version constraint entirely.

```powershell
# WORKS - install latest compatible version
puppet module install puppetlabs-dsc_lite
puppet module install puppetlabs-stdlib
```

---

### Issue 2 — Jenkins MSI Download URL Redirect

**Wrong assumption:** The canonical Jenkins "latest" URL would download the MSI directly.

```puppet
# BROKE - URL returns HTTP 308, WebClient does not follow 308 redirects
setscript => '(New-Object System.Net.WebClient).DownloadFile(
  "https://get.jenkins.io/windows/latest",
  "C:\\Windows\\Temp\\jenkins.msi")',
```

The download appeared to succeed but produced a tiny HTML redirect page instead of the MSI.

**Fix in `jenkins-windows.pp`:** Hardcode a direct URL to the specific LTS release and add a size check.

```puppet
setscript => '(New-Object System.Net.WebClient).DownloadFile(
  "https://get.jenkins.io/windows-stable/2.528.2/jenkins.msi",
  "C:\\Windows\\Temp\\jenkins.msi");
  if ((Get-Item "C:\\Windows\\Temp\\jenkins.msi").Length -lt 1MB) {
    throw "Jenkins MSI corrupt"
  }',
```

---

### Issue 3 — Jenkins MSI Fails at Service Start (Error 1920)

**Wrong assumption:** Setting `$env:Path` or adding Java to the system PATH before calling msiexec would be sufficient for the service to find Java during installation.

```puppet
# BROKE - PATH set in DSC session, not visible to SCM spawned by MSI
setscript => '$env:Path = "$env:Path;C:\\Program Files\\Eclipse Adoptium\\...\\bin";
  Start-Process msiexec.exe -ArgumentList @("/i","C:\\Windows\\Temp\\jenkins.msi","/qn") -Wait',
# Error 1920: Service 'Jenkins' (Jenkins) failed to start.
```

The Jenkins MSI starts the service during installation via the Windows Service Control Manager. The SCM reads system environment at that moment — `$env:Path` changes in the DSC session were not visible to it.

**Fix in `jenkins-windows.pp`:** Add a dedicated `set_java_home` resource that persists `JAVA_HOME` to the registry before the install resource runs. The Jenkins service wrapper reads `JAVA_HOME` — not `PATH` — to locate `java.exe`.

```puppet
# RESOURCE 3 - Set JAVA_HOME (persisted to registry, visible to SCM)
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
```

**Also added in `install_jenkins_puppet_dsc.ps1`:** Step 5 now sets both `JAVA_HOME` and `PATH` at the system level before puppet apply runs, ensuring they are available even if the DSC Environment resources haven't run yet on a fresh instance.

```powershell
$JavaHome = "C:\Program Files\Eclipse Adoptium\jdk-17.0.11.9-hotspot"
[Environment]::SetEnvironmentVariable("JAVA_HOME", $JavaHome, "Machine")
[Environment]::SetEnvironmentVariable("Path",
  [Environment]::GetEnvironmentVariable("Path","Machine") + ";$JavaHome\bin", "Machine")
```

---

### Issue 4 — DSC Environment Resource Does Not Support `target` Property

**Wrong assumption:** The DSC Environment resource accepted a `target` property to explicitly scope the variable to `Machine` level.

```puppet
# BROKE - 'target' is not a valid property for this DSC resource version
dsc { 'set_java_path':
  properties => {
    name   => 'Path',
    value  => 'C:\...\bin',
    path   => true,
    target => ['Machine'],   # Error: Undefined property target
  },
}
```

**Fix in `jenkins-windows.pp`:** Remove `target`. DSC Environment resources run as SYSTEM and default to machine scope.

```puppet
dsc { 'set_java_path':
  properties => {
    name   => 'Path',
    value  => 'C:\Program Files\Eclipse Adoptium\jdk-17.0.11.9-hotspot\bin',
    ensure => 'present',
    path   => true,
  },
}
```

---

### Issue 5 — jenkins.exe Is a Service Wrapper, Not the JVM

**Wrong assumption:** `jenkins.exe` is the Jenkins process — passing JVM flags and `--httpPort` to it would work the same as `java -jar jenkins.war` on Linux.

The event log showed:
```
Starting C:\Program Files\Jenkins\jenkins.exe -Xrs -Xmx256m ... --httpPort=8000
Child process finished with -1
```

Running it directly confirmed:
```
> jenkins.exe --httpPort=8000
Unknown command: --httpPort=8000
Available commands: install, uninstall, start, stop, status...
```

`jenkins.exe` is **WinSW** (Windows Service Wrapper) — a service control shim. It reads `jenkins.xml` to determine what to actually launch. Passing application arguments to it directly fails.

**Fix in `jenkins-windows.pp`:** Change `<executable>` in `jenkins.xml` to point directly to `java.exe`. Move all JVM flags and Jenkins arguments into `<arguments>`.

```puppet
# setscript in configure_and_start_jenkins now writes:
$java = "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.11.9-hotspot\\bin\\java.exe"
$war  = "C:\\Program Files\\Jenkins\\jenkins.war"
$xml  = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<service>
  <id>Jenkins</id>
  <executable>$java</executable>
  <arguments>-Xrs -Xmx256m -Dhudson.lifecycle=hudson.lifecycle.WindowsServiceLifecycle
    -jar `"$war`" --httpPort=8000 --webroot=`"%LocalAppData%\Jenkins\war`"
    -Djenkins.install.runSetupWizard=false</arguments>
  <logmode>rotate</logmode>
</service>"
```

---

### Issue 6 — jenkins.xml Version 1.1 Not Supported

**Wrong assumption:** Writing `<?xml version="1.1"` in a generated `jenkins.xml` would be accepted by the Jenkins service wrapper.

```
> jenkins.exe status
The configuration file could not be loaded.
Version number '1.1' is invalid. Line 1, position 16.
```

WinSW's embedded XML parser only supports XML version 1.0.

**Fix in `jenkins-windows.pp`:** The `setscript` in `configure_and_start_jenkins` now always writes `version="1.0"` and also patches existing files that may have been written with `1.1`.

```puppet
# Always write version 1.0 in both new and existing jenkins.xml
$xml = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>..."
```

---

### Issue 7 — Setup Wizard Not Disabled by JVM Flag Alone

**Wrong assumption:** `-Djenkins.install.runSetupWizard=false` in the JVM arguments would fully disable the setup wizard.

Jenkins showed the unlock screen despite the flag being present in `jenkins.xml`. Jenkins checks for install state files in `JENKINS_HOME` to determine whether initial setup has been completed. If the files are absent it shows the wizard regardless of the JVM flag.

**Fix in `jenkins-windows.pp`:** The `setscript` in `configure_and_start_jenkins` now creates both required state files in the Jenkins home directory.

```puppet
$d = "C:\\Windows\\system32\\config\\systemprofile\\.jenkins"
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force }
Set-Content -Path "$d\jenkins.install.InstallUtil.lastExecVersion" -Value "2.528.2"
Set-Content -Path "$d\jenkins.install.UpgradeWizard.state" -Value "2.528.2"
```

The `testscript` also checks for the presence of these files so the resource re-runs if they are ever deleted.

---

### Issue 8 — Windows Firewall Blocking External Access

**Wrong assumption:** Opening port 8000 in the AWS security group was sufficient for external access, same as Linux.

Jenkins was confirmed running (`netstat -an` showed `0.0.0.0:8000 LISTENING`) and the AWS security group had the correct inbound rule — but external connections timed out. Windows Server 2022 has Windows Firewall enabled by default. The AWS security group operates at the hypervisor layer; Windows Firewall operates independently at the OS layer. Both must allow the traffic.

**Fix in `jenkins-windows.pp`:** The `setscript` in `configure_and_start_jenkins` creates a firewall rule if it does not already exist. The `testscript` checks for it as one of the five conditions that must all be true before Puppet considers the resource satisfied.

```puppet
# In testscript - firewall check is one of five conditions
$fwOk = ((Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue) -ne $null)
return ($running -and $port -and $xmlOk -and $wizardOk -and $fwOk)

# In setscript - create rule if absent
if (-not (Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "Jenkins-8000" -Direction Inbound `
    -Protocol TCP -LocalPort 8000 -Action Allow -Profile Any
}
```

**Also required in `jenkins-windows-puppet.yaml`:** The CloudFormation template's security group opens port 8000 at the AWS network layer. This is a prerequisite — the Windows Firewall rule handles the OS layer.

```yaml
SecurityGroupIngress:
  - IpProtocol: tcp
    FromPort: 8000
    ToPort: 8000
    CidrIp: !Sub "${DeployerIP}/32"
    Description: Jenkins UI - deployer IP only
```

---

### Final State of `configure_and_start_jenkins`

After all fixes, the seventh and final resource in `jenkins-windows.pp` consolidates all configuration and runtime checks into a single idempotent resource. The `testscript` checks all five conditions simultaneously — Jenkins only stops and restarts if something is actually wrong.

```puppet
dsc { 'configure_and_start_jenkins':
  resource_name => 'Script',
  module        => 'PSDesiredStateConfiguration',
  properties    => {
    testscript => '
      $svc      = (Get-Service jenkins -ErrorAction SilentlyContinue)
      $running  = ($svc -ne $null -and $svc.Status -eq "Running")
      $port     = (netstat -an | Select-String ":8000.*LISTENING") -ne $null
      $p        = "C:\\Program Files\\Jenkins\\jenkins.xml"
      $xmlOk    = (Test-Path $p) -and
                  ((Get-Content $p -Raw) -match "--httpPort=8000") -and
                  ((Get-Content $p -Raw) -match "java.exe") -and
                  ((Get-Content $p -Raw) -match "runSetupWizard=false")
      $wizardOk = (Test-Path "C:\\Windows\\system32\\config\\systemprofile\\.jenkins\\jenkins.install.InstallUtil.lastExecVersion")
      $fwOk     = ((Get-NetFirewallRule -DisplayName "Jenkins-8000" -ErrorAction SilentlyContinue) -ne $null)
      return ($running -and $port -and $xmlOk -and $wizardOk -and $fwOk)
    ',
    # setscript: stop service, rewrite jenkins.xml, create wizard files,
    #            add firewall rule, start service
  },
  require => Dsc['install_jenkins'],
}
```

