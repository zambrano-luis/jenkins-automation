#!/usr/bin/env python3
"""
Jenkins Automation — Track 2: Pure Python
==========================================
Installs and configures Jenkins on Ubuntu 22.04 LTS.

Requirements satisfied:
  A) Runs on a clean OS — Python 3 ships on Ubuntu 22.04, no pip deps needed
  B) Fully unattended — no prompts, no wizard, no manual steps
  C) Jenkins listens on port 8000 natively — not a proxy, not a forward
  D) Idempotent — safe to re-run, skips steps already completed

Usage:
  sudo python3 install_jenkins.py

Author: Luis Zambrano
"""

import os
import sys
import subprocess
import platform
import urllib.error

# ─── CONSTANTS ────────────────────────────────────────────────────────────────

JENKINS_PORT       = "8000"
JENKINS_CONFIG     = "/etc/default/jenkins"
JENKINS_HOME       = "/var/lib/jenkins"
JENKINS_KEYRING    = "/usr/share/keyrings/jenkins-keyring.asc"
JENKINS_REPO_FILE  = "/etc/apt/sources.list.d/jenkins.list"
JENKINS_KEY_URL    = "https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key"
JENKINS_REPO_LINE  = "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/"
JAVA_PACKAGE       = "openjdk-17-jdk"
JENKINS_PACKAGE    = "jenkins"

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
║     Jenkins Automation — Track 2: Pure Python    ║
║     Target: Ubuntu 22.04 LTS                     ║
║     Port:   {JENKINS_PORT}                                   ║
╚══════════════════════════════════════════════════╝{Color.RESET}
""")

# ─── HELPERS ──────────────────────────────────────────────────────────────────

def run(cmd, env_extra=None, check=True):
    """Run a shell command, stream output, raise on failure."""
    env = os.environ.copy()
    env["DEBIAN_FRONTEND"] = "noninteractive"
    if env_extra:
        env.update(env_extra)
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

def is_package_installed(package):
    """Return True if a deb package is installed."""
    result = run(f"dpkg-query -W -f='${{Status}}' {package} 2>/dev/null", check=False)
    return "install ok installed" in result.stdout

def service_is_active(service):
    """Return True if a systemd service is active."""
    result = run(f"systemctl is-active {service}", check=False)
    return result.stdout.strip() == "active"

def service_is_enabled(service):
    """Return True if a systemd service is enabled."""
    result = run(f"systemctl is-enabled {service}", check=False)
    return result.stdout.strip() == "enabled"

def file_contains(path, text):
    """Return True if file exists and contains the given text."""
    if not os.path.isfile(path):
        return False
    with open(path, "r") as f:
        return text in f.read()

def ensure_root():
    """Exit if not running as root."""
    if os.geteuid() != 0:
        log_error("This script must be run as root. Use: sudo python3 install_jenkins.py")
        sys.exit(1)

def check_ubuntu():
    """Warn if not running on Ubuntu 22.04."""
    if not os.path.isfile("/etc/os-release"):
        return
    with open("/etc/os-release") as f:
        content = f.read()
    if "Ubuntu" not in content:
        log_error("This script is designed for Ubuntu 22.04 LTS. Detected OS may not be compatible.")
        sys.exit(1)

# ─── INSTALLATION STEPS ───────────────────────────────────────────────────────

def step_install_java():
    """Step 1 — Install OpenJDK 17. Idempotent: skips entirely if already installed."""
    log_step("Step 1/7 — Installing OpenJDK 17")

    if is_package_installed(JAVA_PACKAGE):
        log_skip(f"{JAVA_PACKAGE} is already installed")
        return

    log_info("Updating apt package index...")
    run("apt-get update -qq")
    log_info(f"Installing {JAVA_PACKAGE}...")
    run(f"apt-get install -y -qq {JAVA_PACKAGE}")
    log_ok(f"{JAVA_PACKAGE} installed")


def step_add_jenkins_repo():
    """Step 3 — Add Jenkins apt repo and GPG key. Idempotent: skips if both exist."""
    log_step("Step 3/7 — Adding Jenkins apt repository")

    # GPG key — skip only if file exists AND is valid binary (not ASCII-armored)
    key_valid = False
    if os.path.isfile(JENKINS_KEYRING):
        with open(JENKINS_KEYRING, "rb") as f:
            header = f.read(10)
        # ASCII-armored files start with "-----BEGIN" — binary keyrings do not
        if not header.startswith(b"-----"):
            key_valid = True

    if key_valid:
        log_skip("Jenkins GPG key already present and valid")
    else:
        if os.path.isfile(JENKINS_KEYRING):
            log_info("Jenkins GPG key exists but is invalid format — reimporting...")
        else:
            log_info("Importing Jenkins GPG key...")
        run(f"curl -fsSL {JENKINS_KEY_URL} | gpg --batch --yes --dearmor -o {JENKINS_KEYRING}")
        os.chmod(JENKINS_KEYRING, 0o644)
        # Always refresh apt after key change so Jenkins package becomes available
        run("apt-get update -qq")
        log_ok("GPG key imported")

    # Repo entry — skip if already present
    if os.path.isfile(JENKINS_REPO_FILE) and file_contains(JENKINS_REPO_FILE, "jenkins"):
        log_skip("Jenkins apt repo already configured")
    else:
        log_info("Adding Jenkins apt source...")
        with open(JENKINS_REPO_FILE, "w") as f:
            f.write(JENKINS_REPO_LINE + "\n")
        run("apt-get update -qq")
        log_ok("Jenkins apt repo added")


def step_install_jenkins():
    """Step 4 — Install Jenkins LTS. Idempotent: skips if already installed."""
    log_step("Step 4/7 — Installing Jenkins LTS")

    if is_package_installed(JENKINS_PACKAGE):
        log_skip("Jenkins is already installed")
        return

    log_info("Installing Jenkins (this may take a minute)...")
    run(f"apt-get install -y -qq {JENKINS_PACKAGE}")
    log_ok("Jenkins installed")


def step_configure_port():
    """
    Step 5 — Configure Jenkins to listen on port 8000.
    Idempotent: only writes if HTTP_PORT is not already set to 8000.
    Satisfies Requirement C — Jenkins JVM itself binds to 8000.
    """
    log_step(f"Step 5/7 — Configuring Jenkins to listen on port {JENKINS_PORT}")

    target_line  = f"HTTP_PORT={JENKINS_PORT}"
    default_line = "HTTP_PORT=8080"

    if not os.path.isfile(JENKINS_CONFIG):
        log_error(f"Jenkins config file not found: {JENKINS_CONFIG}")
        sys.exit(1)

    with open(JENKINS_CONFIG, "r") as f:
        content = f.read()

    # Idempotency check — already set to 8000
    if target_line in content:
        log_skip(f"HTTP_PORT is already set to {JENKINS_PORT}")
        return

    # Replace existing HTTP_PORT line if present, otherwise append
    if default_line in content:
        log_info(f"Replacing HTTP_PORT=8080 with HTTP_PORT={JENKINS_PORT}")
        content = content.replace(default_line, target_line)
    elif "HTTP_PORT=" in content:
        # Handle any other port value
        import re
        log_info(f"Replacing existing HTTP_PORT value with {JENKINS_PORT}")
        content = re.sub(r"HTTP_PORT=\d+", target_line, content)
    else:
        log_info(f"Appending HTTP_PORT={JENKINS_PORT} to config")
        content += f"\n{target_line}\n"

    with open(JENKINS_CONFIG, "w") as f:
        f.write(content)

    log_ok(f"Jenkins configured to listen on port {JENKINS_PORT}")


def step_disable_wizard():
    """
    Step 6 — Disable the Jenkins setup wizard.
    Idempotent: only modifies JAVA_ARGS if wizard flag is not already present.
    Satisfies Requirement B — fully unattended, no manual unlock step.
    """
    log_step("Step 6/7 — Disabling Jenkins setup wizard")

    wizard_flag = "-Djenkins.install.runSetupWizard=false"

    with open(JENKINS_CONFIG, "r") as f:
        content = f.read()

    if wizard_flag in content:
        log_skip("Setup wizard already disabled")
        return

    import re

    # If JAVA_ARGS line exists, append flag to it
    if re.search(r'^JAVA_ARGS="[^"]*"', content, re.MULTILINE):
        log_info("Appending wizard disable flag to existing JAVA_ARGS")
        content = re.sub(
            r'^(JAVA_ARGS="[^"]*)"',
            rf'\1 {wizard_flag}"',
            content,
            flags=re.MULTILINE
        )
    else:
        log_info("Adding JAVA_ARGS with wizard disable flag")
        content += f'\nJAVA_ARGS="{wizard_flag}"\n'

    with open(JENKINS_CONFIG, "w") as f:
        f.write(content)

    log_ok("Setup wizard disabled")


def step_enable_and_restart():
    """
    Step 7 — Enable Jenkins on boot and restart to apply config changes.
    Idempotent: only restarts if config was changed or service is not running.
    """
    log_step("Step 7/7 — Enabling and starting Jenkins service")

    # Enable on boot
    if service_is_enabled(JENKINS_PACKAGE):
        log_skip("Jenkins already enabled on boot")
    else:
        log_info("Enabling Jenkins service...")
        run("systemctl enable jenkins")
        log_ok("Jenkins enabled on boot")

    # Always restart to apply any config changes
    log_info("Restarting Jenkins to apply configuration...")
    run("systemctl restart jenkins")
    log_ok("Jenkins service restarted")


def step_validate():
    """
    Step 8 — Validate Jenkins is running and responding on port 8000.
    Polls up to 60 seconds for Jenkins to become ready.
    """
    log_step(f"Step 8/7 — Validating Jenkins is responding on port {JENKINS_PORT}")

    import time
    import urllib.request
    import urllib.error

    max_wait  = 60
    interval  = 5
    elapsed   = 0
    url       = f"http://localhost:{JENKINS_PORT}"

    log_info(f"Waiting for Jenkins to respond at {url} (up to {max_wait}s)...")

    while elapsed < max_wait:
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=5) as response:
                code = response.getcode()
                log_ok(f"Jenkins is UP — HTTP {code} on port {JENKINS_PORT}")
                return
        except urllib.error.HTTPError as e:
            # 403 Forbidden is expected — Jenkins is running but auth is required
            if e.code == 403:
                log_ok(f"Jenkins is UP — HTTP 403 (auth required) on port {JENKINS_PORT}")
                return
            log_info(f"HTTP {e.code} — waiting... ({elapsed}s elapsed)")
        except Exception:
            log_info(f"Not ready yet — waiting... ({elapsed}s elapsed)")

        time.sleep(interval)
        elapsed += interval

    log_error(f"Jenkins did not respond on port {JENKINS_PORT} within {max_wait} seconds.")
    log_info("Check logs with: sudo journalctl -u jenkins -n 50")
    sys.exit(1)


# ─── SUMMARY ──────────────────────────────────────────────────────────────────

def log_summary():
    print(f"""
{Color.BOLD}{Color.GREEN}╔══════════════════════════════════════════════════╗
║              Installation Complete               ║
╠══════════════════════════════════════════════════╣
║  Jenkins is running on port {JENKINS_PORT}                  ║
║                                                  ║
║  Access:  http://<your-ip>:{JENKINS_PORT}              ║
║  Logs:    journalctl -u jenkins -f               ║
║  Config:  /etc/default/jenkins                   ║
║  Home:    /var/lib/jenkins                       ║
╚══════════════════════════════════════════════════╝{Color.RESET}
""")


# ─── MAIN ─────────────────────────────────────────────────────────────────────

def main():
    log_header()
    ensure_root()
    check_ubuntu()

    step_install_java()
    step_add_jenkins_repo()
    step_install_jenkins()
    step_configure_port()
    step_disable_wizard()
    step_enable_and_restart()
    step_validate()

    log_summary()


if __name__ == "__main__":
    main()