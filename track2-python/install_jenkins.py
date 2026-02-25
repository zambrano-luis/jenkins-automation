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
JENKINS_KEY_URL    = "https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key"
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
    log_step("Step 2/7 — Adding Jenkins apt repository")

    # GPG key — skip only if file exists AND contains the correct key header
    key_valid = False
    if os.path.isfile(JENKINS_KEYRING):
        with open(JENKINS_KEYRING, "rb") as f:
            header = f.read(50)
        # Valid ASCII-armored key starts with -----BEGIN PGP PUBLIC KEY BLOCK-----
        if b"BEGIN PGP PUBLIC KEY BLOCK" in header:
            key_valid = True

    if key_valid:
        log_skip("Jenkins GPG key already present and valid")
    else:
        if os.path.isfile(JENKINS_KEYRING):
            log_info("Jenkins GPG key exists but is invalid — reimporting...")
        else:
            log_info("Importing Jenkins GPG key...")
        run(f"curl -fsSL {JENKINS_KEY_URL} | tee {JENKINS_KEYRING} > /dev/null")
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
    log_step("Step 3/7 — Installing Jenkins LTS")

    if is_package_installed(JENKINS_PACKAGE):
        log_skip("Jenkins is already installed")
        return

    log_info("Installing Jenkins (this may take a minute)...")
    run(f"apt-get install -y -qq {JENKINS_PACKAGE}")
    log_ok("Jenkins installed")


def step_configure_port():
    """
    Step 4 — Configure Jenkins to listen on port 8000.
    Idempotent: only writes if HTTP_PORT is not already set to 8000.
    Satisfies Requirement C — Jenkins JVM itself binds to 8000.
    Returns True if config was changed, False if already correct.
    """
    log_step(f"Step 4/7 — Configuring Jenkins to listen on port {JENKINS_PORT}")

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
        return False

    # Replace existing HTTP_PORT line if present, otherwise append
    if default_line in content:
        log_info(f"Replacing HTTP_PORT=8080 with HTTP_PORT={JENKINS_PORT}")
        content = content.replace(default_line, target_line)
    elif "HTTP_PORT=" in content:
        import re
        log_info(f"Replacing existing HTTP_PORT value with {JENKINS_PORT}")
        content = re.sub(r"HTTP_PORT=\d+", target_line, content)
    else:
        log_info(f"Appending HTTP_PORT={JENKINS_PORT} to config")
        content += f"\n{target_line}\n"

    with open(JENKINS_CONFIG, "w") as f:
        f.write(content)

    log_ok(f"Jenkins configured to listen on port {JENKINS_PORT}")
    return True


def step_disable_wizard():
    """
    Step 5 — Disable the Jenkins setup wizard via systemd drop-in override.
    Newer Jenkins reads JAVA_OPTS from the systemd unit Environment directive,
    not from JAVA_ARGS in /etc/default/jenkins. A drop-in override is used so
    the change survives Jenkins package upgrades without touching the unit file.
    Idempotent: skips if override already contains the wizard disable flag.
    Returns True if config was written, False if already at desired state.
    """
    log_step("Step 5/7 — Disabling Jenkins setup wizard")

    wizard_flag   = "-Djenkins.install.runSetupWizard=false"
    override_dir  = "/etc/systemd/system/jenkins.service.d"
    override_file = f"{override_dir}/override.conf"
    override_content = (
        "[Service]\n"
        f'Environment="JAVA_OPTS=-Djava.awt.headless=true {wizard_flag}"\n'
    )

    # Idempotency check — skip writing if flag already present in override
    if os.path.isfile(override_file) and file_contains(override_file, wizard_flag):
        # Check if systemd has actually loaded this override
        result = run("systemctl show jenkins --property=Environment", check=False)
        if wizard_flag in result.stdout:
            run("systemctl daemon-reload")
            log_skip("Setup wizard already disabled via systemd override")
            return False
        else:
            # Override file exists but systemd hasn't loaded it yet — reload needed
            log_info("Override file present but not loaded by systemd — reloading...")
            run("systemctl daemon-reload")
            return True

    log_info("Writing systemd drop-in override to disable setup wizard...")
    os.makedirs(override_dir, exist_ok=True)
    with open(override_file, "w") as f:
        f.write(override_content)

    run("systemctl daemon-reload")
    log_ok("Setup wizard disabled via systemd override")
    return True


def step_enable_and_restart(restart_required):
    """
    Step 6 — Enable Jenkins on boot and restart only if needed.
    restart_required is True only when port or wizard config was not already
    at desired state and was written during this run.
    """
    log_step("Step 6/7 — Enabling and starting Jenkins service")

    # Enable on boot
    if service_is_enabled(JENKINS_PACKAGE):
        log_skip("Jenkins already enabled on boot")
    else:
        log_info("Enabling Jenkins service...")
        run("systemctl enable jenkins")
        log_ok("Jenkins enabled on boot")

    # Only restart if desired state was not already met
    if restart_required:
        log_info("Configuration was updated — restarting Jenkins to apply changes...")
        run("systemctl restart jenkins")
        log_ok("Jenkins service restarted")
    elif not service_is_active(JENKINS_PACKAGE):
        log_info("Jenkins is not running — starting service...")
        run("systemctl start jenkins")
        log_ok("Jenkins service started")
    else:
        log_skip("Jenkins already running on port 8000 with correct config — no restart needed")


def step_validate():
    """
    Step 7 — Validate Jenkins is running and responding on port 8000.
    Polls up to 60 seconds for Jenkins to become ready.
    """
    log_step(f"Step 7/7 — Validating Jenkins is responding on port {JENKINS_PORT}")

    import time
    import urllib.request
    import urllib.error

    max_wait  = 120
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
    port_needs_restart   = step_configure_port()
    wizard_needs_restart = step_disable_wizard()
    step_enable_and_restart(restart_required=port_needs_restart or wizard_needs_restart)
    step_validate()

    log_summary()


if __name__ == "__main__":
    main()