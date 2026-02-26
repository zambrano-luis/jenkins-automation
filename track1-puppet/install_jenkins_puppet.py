#!/usr/bin/env python3
"""
Jenkins Automation — Track 1B: Python + Puppet (Linux Bootstrap)
=================================================================
Bootstraps Puppet agent on Ubuntu 22.04 LTS, installs the puppetlabs-apt
module, downloads the Jenkins manifest from GitHub, and runs puppet apply.

Puppet then takes over and declares the desired state for:
  - Jenkins GPG key and apt repository
  - Java 17 and Jenkins packages
  - Port 8000 configuration via systemd override
  - Setup wizard disabled
  - Jenkins service running and enabled

Requirements satisfied:
  A) Runs on a clean OS — puppet-agent and module installed from scratch
  B) Fully unattended — no prompts at any stage
  C) Jenkins listens on port 8000 natively via systemd override
  D) Idempotent — puppet apply converges to desired state on every run

Usage:
  sudo python3 install_jenkins_puppet.py

Author: Luis Zambrano
"""

import os
import sys
import subprocess
import urllib.request

# ─── CONSTANTS ────────────────────────────────────────────────────────────────

PUPPET_REPO_URL    = "https://apt.puppet.com/puppet-release-jammy.deb"
PUPPET_REPO_DEB    = "/tmp/puppet-release.deb"
PUPPET_BIN         = "/opt/puppetlabs/bin/puppet"
PUPPET_MODULE      = "puppetlabs-apt"
MANIFEST_URL       = "https://raw.githubusercontent.com/zambrano-luis/jenkins-automation/main/track1-puppet/manifests/jenkins-linux.pp"
MANIFEST_PATH      = "/tmp/jenkins.pp"

# ─── LOGGING ──────────────────────────────────────────────────────────────────

class Color:
    RESET  = "\033[0m"
    BOLD   = "\033[1m"
    AMBER  = "\033[33m"
    GREEN  = "\033[32m"
    RED    = "\033[31m"
    CYAN   = "\033[36m"
    MUTED  = "\033[90m"

def log_step(msg):
    print(f"\n{Color.BOLD}{Color.AMBER}==>{Color.RESET} {Color.BOLD}{msg}{Color.RESET}")

def log_info(msg):
    print(f"    {Color.MUTED}→{Color.RESET}  {msg}")

def log_skip(msg):
    print(f"    {Color.CYAN}↷  SKIP:{Color.RESET} {msg} — already done")

def log_ok(msg):
    print(f"    {Color.GREEN}✓  {msg}{Color.RESET}")

def log_error(msg):
    print(f"\n{Color.RED}{Color.BOLD}✗  ERROR: {msg}{Color.RESET}\n", file=sys.stderr)

def log_header():
    print(f"""
{Color.BOLD}{Color.AMBER}╔══════════════════════════════════════════════════╗
║   Jenkins Automation — Track 1B: Puppet Linux   ║
║   Target: Ubuntu 22.04 LTS                      ║
║   Port:   8000                                   ║
╚══════════════════════════════════════════════════╝{Color.RESET}
""")

# ─── HELPERS ──────────────────────────────────────────────────────────────────

def run(cmd, check=True):
    """Run a shell command, stream output, raise on failure."""
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    result = subprocess.run(
        cmd, shell=True, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    if result.stdout.strip():
        for line in result.stdout.strip().splitlines():
            log_info(line)
    if check and result.returncode != 0:
        log_error(f"Command failed (exit {result.returncode}): {cmd}")
        sys.exit(result.returncode)
    return result

def ensure_root():
    if os.geteuid() != 0:
        log_error("This script must be run as root. Use: sudo python3 install_jenkins_puppet.py")
        sys.exit(1)

def is_package_installed(package):
    result = run(f"dpkg-query -W -f='${{Status}}' {package} 2>/dev/null", check=False)
    return "install ok installed" in result.stdout

def puppet_module_installed(module):
    result = run(f"{PUPPET_BIN} module list 2>/dev/null | grep {module}", check=False)
    return result.returncode == 0

# ─── BOOTSTRAP STEPS ──────────────────────────────────────────────────────────

def step_install_puppet():
    """
    Step 1 — Install Puppet agent from Puppet's official apt repo.
    Uses puppet-agent (latest stable) rather than a versioned package.
    Idempotent: skips if puppet-agent is already installed.
    """
    log_step("Step 1/4 — Installing Puppet agent")

    if os.path.isfile(PUPPET_BIN):
        log_skip("Puppet agent already installed")
        return

    log_info("Adding Puppet apt repository...")
    urllib.request.urlretrieve(PUPPET_REPO_URL, PUPPET_REPO_DEB)
    run(f"dpkg -i {PUPPET_REPO_DEB}")
    run("apt-get update -qq")

    log_info("Installing puppet-agent (latest stable)...")
    run("apt-get install -y -qq puppet-agent")
    log_ok("Puppet agent installed")

    # Add Puppet binaries to PATH for this session
    os.environ["PATH"] = f"/opt/puppetlabs/bin:{os.environ['PATH']}"


def step_install_module():
    """
    Step 2 — Install puppetlabs-apt module required by the manifest.
    Idempotent: skips if module is already installed.
    """
    log_step("Step 2/4 — Installing puppetlabs-apt module")

    if puppet_module_installed(PUPPET_MODULE):
        log_skip(f"{PUPPET_MODULE} already installed")
        return

    log_info(f"Installing {PUPPET_MODULE}...")
    run(f"{PUPPET_BIN} module install {PUPPET_MODULE} --target-dir /etc/puppetlabs/code/modules")
    log_ok(f"{PUPPET_MODULE} installed")


def step_download_manifest():
    """
    Step 3 — Download the Jenkins Puppet manifest from GitHub.
    Always downloads fresh to ensure latest version is applied.
    """
    log_step("Step 3/4 — Downloading Jenkins manifest")

    log_info(f"Fetching manifest from GitHub...")
    urllib.request.urlretrieve(MANIFEST_URL, MANIFEST_PATH)
    log_ok(f"Manifest saved to {MANIFEST_PATH}")


def step_puppet_apply():
    """
    Step 4 — Run puppet apply against the Jenkins manifest.
    Puppet handles all idempotency from this point forward.
    On re-run Puppet converges to desired state — skipping resources
    already in the correct state and only acting where drift is detected.
    """
    log_step("Step 4/4 — Applying Puppet manifest")

    log_info("Running puppet apply (this may take a few minutes)...")
    result = run(
        f"{PUPPET_BIN} apply {MANIFEST_PATH} "
        f"--modulepath /etc/puppetlabs/code/modules",
        check=False
    )

    # Puppet exit codes:
    # 0 = success, no changes
    # 2 = success, changes were made
    # 4 = failures
    # 6 = changes and failures
    if result.returncode in (0, 2):
        log_ok("Puppet apply completed successfully")
    else:
        log_error(f"Puppet apply failed with exit code {result.returncode}")
        sys.exit(result.returncode)


# ─── SUMMARY ──────────────────────────────────────────────────────────────────

def log_summary():
    print(f"""
{Color.BOLD}{Color.GREEN}╔══════════════════════════════════════════════════╗
║              Installation Complete               ║
╠══════════════════════════════════════════════════╣
║  Jenkins is running on port 8000                  ║
║                                                  ║
║  Access:  http://<your-ip>:8000              ║
║  Logs:    journalctl -u jenkins -f               ║
║  Puppet:  puppet apply manifests/jenkins.pp      ║
╚══════════════════════════════════════════════════╝{Color.RESET}
""")


# ─── MAIN ─────────────────────────────────────────────────────────────────────

def main():
    log_header()
    ensure_root()

    step_install_puppet()
    step_install_module()
    step_download_manifest()
    step_puppet_apply()

    log_summary()


if __name__ == "__main__":
    main()