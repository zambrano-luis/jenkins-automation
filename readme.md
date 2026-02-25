# Jenkins Automation

Automated installation and configuration of Jenkins CI server across multiple platforms and toolchain. The purpose is to demonstrate infrastructure automation, idempotency, and cross-platform provisioning.

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
├── .gitignore
├── Vagrantfile                                    # Local Linux replication
├── track1-puppet/
│   ├── manifests/
│   │   └── jenkins.pp                            # Puppet manifest (shared across OS targets)
│   ├── install_jenkins_puppet.py                 # Linux bootstrap - Python -> puppet apply
│   └── install_jenkins_puppet.ps1                # Windows bootstrap - PowerShell -> puppet apply
├── track2-python/
│   ├── install_jenkins.py                        # Pure Python installer - Ubuntu 20.04+ LTS
│   ├── deploy-track2-linux.ps1                   # PowerShell deploy script (Windows)
│   ├── deploy-track2-linux.sh                    # Bash deploy script (Linux/macOS)
│   ├── cleanup-track2-linux.ps1                  # PowerShell cleanup script (Windows)
│   └── cleanup-track2-linux.sh                   # Bash cleanup script (Linux/macOS)
└── aws-demo-cf-templates/
    ├── jenkins-linux.yaml                        # CloudFormation - Ubuntu EC2
    └── jenkins-windows.yaml                      # CloudFormation - Windows Server 2022 EC2
```

---

## Tracks

### Track 1 - Python / PowerShell + Puppet (Masterless)

The bootstrap layer installs Puppet agent silently, then runs `puppet apply` against the shared manifest. The manifest is OS-agnostic - only the bootstrap differs between platforms.

**Track 1B - Linux (Ubuntu 22.04 LTS)**

```bash
sudo python3 track1-puppet/install_jenkins_puppet.py
```

**Track 1A - Windows (Windows Server 2022)**

```powershell
powershell.exe -ExecutionPolicy Bypass -File track1-puppet\install_jenkins_puppet.ps1
```

---

### Track 2 - Pure Python

Single self-contained script. No dependencies beyond Python 3 stdlib. Designed for Ubuntu 20.04+ LTS where Python 3 ships by default.

```bash
sudo python3 track2-python/install_jenkins.py
```

---

### AWS Demo - CloudFormation Templates

Provisions a fully self-contained EC2 environment including security group and SSH key pair. No pre-existing key pairs or manual setup required. The instance pulls the provisioning script directly from this repository via UserData on first boot.

The key pair is created by the stack and stored automatically in AWS SSM Parameter Store. It is deleted when the stack is deleted. Retrieve it once immediately after deploy.

**Prerequisites:**
- AWS CLI installed and configured
- Active AWS session (SSO, access keys, or instance profile)

---

#### Linux (Ubuntu 22.04 LTS)

**Deploy - Windows (PowerShell)**

> **Note:** Windows may block unsigned scripts. Use the `-ExecutionPolicy Bypass` flag:

```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\deploy-track2-linux.ps1
```

Optional parameters:
```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\deploy-track2-linux.ps1 -StackName my-stack -Region us-east-1
```

**Deploy - Linux / macOS (Bash)**

> **Note:** After cloning, make scripts executable first:

```bash
chmod +x track2-python/*.sh
```

Then deploy:

```bash
./track2-python/deploy-track2-linux.sh
```

Optional parameters:
```bash
./track2-python/deploy-track2-linux.sh my-stack us-east-1
```

Both scripts handle the full deploy flow automatically:

1. Validate AWS session
2. Detect your public IP and lock the security group to it
3. Deploy the CloudFormation stack
4. Retrieve stack outputs
5. Pull the private key from SSM Parameter Store
6. Set correct key file permissions
7. Print the Jenkins URL and SSH command

**Cleanup - Windows (PowerShell)**

```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\cleanup-track2-linux.ps1
```

**Cleanup - Linux / macOS (Bash)**

```bash
./track2-python/cleanup-track2-linux.sh
```

Cleanup deletes the stack, waits for full deletion, and removes the local `jenkins-demo.pem` file.

---

#### Local Configuration

To use a custom AWS profile or region, copy the deploy or cleanup script and modify locally:

```powershell
Copy-Item track2-python\deploy-track2-linux.ps1 track2-python\deploy-track2-linux-local.ps1
Copy-Item track2-python\cleanup-track2-linux.ps1 track2-python\cleanup-track2-linux-local.ps1
```

```bash
cp track2-python/deploy-track2-linux.sh track2-python/deploy-track2-linux-local.sh
cp track2-python/cleanup-track2-linux.sh track2-python/cleanup-track2-linux-local.sh
```

Local variants are excluded from version control via `.gitignore`.

---

#### Windows (Windows Server 2022)

```powershell
powershell.exe -ExecutionPolicy Bypass -File track2-python\deploy-track2-windows.ps1
```

> AWS handles the Windows Server license through the AMI. Scripts are also provided for replication in any licensed Windows Server environment.

---

## Local Replication (Linux)

Replicate the Linux tracks locally using Vagrant and VirtualBox - no cloud account required.

**Prerequisites:**
- [Vagrant](https://www.vagrantup.com/downloads)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)

```bash
git clone https://github.com/zambrano-luis/jenkins-automation.git
cd jenkins-automation
vagrant up
```

Vagrant will provision a clean Ubuntu 22.04 VM and automatically run Track 1B and Track 2. Jenkins will be available at `http://localhost:8000` once provisioning completes.

---

## Validating Jenkins is Running

After any track completes, confirm Jenkins is running on port 8000:

```bash
curl -I http://localhost:8000
```

Expected response: `HTTP/1.1 403 Forbidden` - this confirms Jenkins is running and responding on port 8000. The 403 is expected because Jenkins requires authentication; it is not an error.

---

## Idempotency

All tracks are safe to re-run. Each step checks current state before acting:

- Package installations check `dpkg` status before calling apt - skipped if already installed
- GPG key validated as correct format before re-importing
- Config file edits check for existing values before writing - skipped if already correct
- Jenkins service restart only triggered if config was not already at desired state
- Puppet's declarative model converges to desired state natively

Re-running any script against an already-provisioned system skips all completed steps and exits cleanly in seconds.

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
- Internet access is required to download Jenkins packages and the Puppet agent
- AWS CLI must be configured with appropriate permissions to deploy CloudFormation stacks

---

## Author

Luis Zambrano - [github.com/zambrano-luis](https://github.com/zambrano-luis)