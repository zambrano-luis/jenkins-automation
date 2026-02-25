# Jenkins Automation

Automated installation and configuration of Jenkins CI server across multiple platforms and toolchains. 
This repository is a practice to demonstrate infrastructure automation, idempotency, and cross-platform provisioning.

Jenkins is configured to listen natively on **port 8000** in all tracks — not via port forwarding, proxy, or NAT.

---

## Requirements

Every track in this repository satisfies the same four requirements:

| Req | Description |
|-----|-------------|
| **A** | Runs on a clean OS installation without errors |
| **B** | Jenkins and prerequisites install without manual intervention |
| **C** | Jenkins itself listens on port 8000 — not a proxy or forward |
| **D** | Re-running produces no failures and no duplicate configuration |

---

## Repository Structure

```
jenkins-automation/
├── README.md
├── Vagrantfile                          # Local Linux replication (Track 1B + Track 2)
├── track1-puppet/
│   ├── manifests/
│   │   └── jenkins.pp                  # Puppet manifest (shared across both OS targets)
│   ├── install_jenkins_puppet.py       # Linux bootstrap — Python → puppet apply
│   └── install_jenkins_puppet.ps1      # Windows bootstrap — PowerShell → puppet apply
├── track2-python/
│   └── install_jenkins.py              # Pure Python — Ubuntu 20.04+ LTS
└── aws-demo-cf-templates/
    ├── jenkins-linux.yaml              # CloudFormation — Ubuntu EC2
    └── jenkins-windows.yaml            # CloudFormation — Windows Server 2022 EC2
```

---

## Tracks

### Track 1 — Python / PowerShell + Puppet (Masterless)

The bootstrap layer installs Puppet agent silently, then runs `puppet apply` against the shared manifest. The manifest is OS-agnostic — only the bootstrap differs between platforms.

**Track 1B — Linux (Ubuntu 22.04 LTS)**

```bash
sudo python3 track1-puppet/install_jenkins_puppet.py
```

**Track 1A — Windows (Windows Server 2022)**

```powershell
powershell.exe -ExecutionPolicy Bypass -File track1-puppet\install_jenkins_puppet.ps1
```

---

### Track 2 — Pure Python

Single self-contained script. No dependencies beyond Python 3 stdlib. Designed for Ubuntu 20.04+ LTS where Python 3 ships by default.

```bash
sudo python3 track2-python/install_jenkins.py
```

---

### AWS Demo — CloudFormation Templates

Provisions an EC2 instance, configures the security group to expose port 8000, and runs the appropriate script via UserData on first boot. The instance pulls the provisioning script directly from this repository.

**Linux (Ubuntu 22.04 LTS):**

Deploy via AWS Console — upload `aws-demo-cf-templates/jenkins-linux.yaml`

Or via CLI:
```bash
aws cloudformation deploy \
  --template-file aws-demo-cf-templates/jenkins-linux.yaml \
  --stack-name jenkins-linux \
  --capabilities CAPABILITY_IAM
```

**Windows (Windows Server 2022):**

```bash
aws cloudformation deploy \
  --template-file aws-demo-cf-templates/jenkins-windows.yaml \
  --stack-name jenkins-windows \
  --capabilities CAPABILITY_IAM
```

> **Note:** Windows track validated on AWS EC2 Windows Server 2022. Scripts are provided for replication in any licensed Windows Server environment. AWS handles the Windows Server license through the AMI.

---

## Local Replication (Linux)

Replicate the Linux tracks locally using Vagrant and VirtualBox — no cloud account required.

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

Expected response: `HTTP/1.1 403 Forbidden` — this confirms Jenkins is running and responding on port 8000. The 403 is expected because Jenkins requires authentication; it is not an error.

---

## Idempotency

All tracks are safe to re-run. Each step checks current state before acting:

- Package installations check `dpkg -l` status before calling apt
- Config file edits check for existing values before writing
- Puppet's declarative model converges to desired state natively
- Service restarts only apply config changes — they do not re-install

Re-running any script against an already-provisioned system will skip completed steps and exit cleanly.

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
- Windows scripts must be run in an elevated PowerShell session
- Internet access is required to download Jenkins packages and the Puppet agent
- AWS CLI must be configured with appropriate permissions to deploy CloudFormation stacks

---

## Author

Luis Zambrano — [github.com/zambrano-luis](https://github.com/zambrano-luis)
