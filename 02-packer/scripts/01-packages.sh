#!/bin/bash
set -euo pipefail

# ================================================================================
# Base Packages
# ================================================================================
#
# Removes snap (conflicts with XRDP) and installs base packages needed by
# later provisioner scripts and the running system.
#
# ================================================================================

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# apt retry helper -- installed first, used by every later build script
# ------------------------------------------------------------------------------
# security.ubuntu.com is a pool of servers that are briefly out of step while a
# security update is being published. If `apt-get update` reads the new index
# from one and `apt-get install` asks another for the .deb, the install dies
# with "404 Not Found" -- randomly, and only during that window.
#
# Acquire::Retries covers transient network errors. The helper covers the 404:
# on failure it waits, re-reads the index (which then matches what the server
# actually has), and tries again.
echo "NOTE: [packages] configuring apt retries"
cat > /etc/apt/apt.conf.d/80-retries <<'APTCONF'
Acquire::Retries "5";
APTCONF

cat > /usr/local/sbin/apt-install-retry <<'HELPER'
#!/bin/bash
# Usage: apt-install-retry -y pkg... (same arguments as apt-get install)
set -uo pipefail
attempts=4
for i in $(seq 1 "${attempts}"); do
  if apt-get install "$@"; then
    exit 0
  fi
  if [ "${i}" -lt "${attempts}" ]; then
    echo "WARNING: [apt] install failed (attempt ${i}/${attempts})," \
         "refreshing the index and retrying in $((i * 15))s"
    sleep $((i * 15))
    apt-get update -y || true
  fi
done
echo "ERROR: [apt] install failed after ${attempts} attempts: $*"
exit 1
HELPER
chmod 755 /usr/local/sbin/apt-install-retry

echo "NOTE: [packages] removing snap"
systemctl stop snapd.service 2>/dev/null || true
snap remove --purge lxd 2>/dev/null || true
snap remove --purge core22 2>/dev/null || true
snap remove --purge snapd 2>/dev/null || true
apt-get purge -y snapd 2>/dev/null || true
echo -e "Package: snapd\nPin: release *\nPin-Priority: -10" \
  | tee /etc/apt/preferences.d/nosnap.pref
echo "NOTE: [packages] snap removed"

echo "NOTE: [packages] installing base packages"
apt-get update -y
apt-install-retry -y \
  curl \
  ca-certificates \
  jq \
  libnotify-bin \
  unzip \
  wget \
  python3-venv \
  python3-pip
echo "NOTE: [packages] done"

echo "NOTE: [packages] removing LibreOffice"
apt-get purge -y libreoffice* liblibreoffice* || true
apt-get autoremove -y
echo "NOTE: [packages] LibreOffice removed"

echo "NOTE: [packages] disabling update notifications"
apt-get purge -y update-notifier update-notifier-common || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
echo 'APT::Periodic::Update-Package-Lists "0";' > /etc/apt/apt.conf.d/99disable-auto-updates
echo 'APT::Periodic::Unattended-Upgrade "0";'  >> /etc/apt/apt.conf.d/99disable-auto-updates
echo "NOTE: [packages] update notifications disabled"

echo "NOTE: [packages] disabling apport crash reporting"
systemctl disable apport.service 2>/dev/null || true
systemctl mask apport.service 2>/dev/null || true
echo "enabled=0" > /etc/default/apport
echo "NOTE: [packages] apport disabled"
