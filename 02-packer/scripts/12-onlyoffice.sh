#!/bin/bash
set -euo pipefail

# ================================================================================
# OnlyOffice Desktop Editors
# ================================================================================

export DEBIAN_FRONTEND=noninteractive

# Pre-accept the MS core fonts EULA so ttf-mscorefonts-installer doesn't hang
# or fail due to a locked debconf database during noninteractive installs
echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula boolean true" \
  | debconf-set-selections

echo "NOTE: [onlyoffice] downloading OnlyOffice Desktop Editors"
cd /tmp
wget -q https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb

echo "NOTE: [onlyoffice] installing"
apt-get install -y ./onlyoffice-desktopeditors_amd64.deb
rm onlyoffice-desktopeditors_amd64.deb

echo "NOTE: [onlyoffice] done"
