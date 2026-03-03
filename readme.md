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
