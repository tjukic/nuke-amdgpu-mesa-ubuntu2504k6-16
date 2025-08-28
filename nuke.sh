#!/usr/bin/env bash
# reset-amd-ubuntu2504.sh
# Fully wipe third-party AMD GPU drivers (AMDGPU-PRO/ROCm/PPAs) and reinstall Ubuntu defaults.
# Tested target: Ubuntu 25.04; assumes systemd + apt.
# Usage: sudo bash reset-amd-ubuntu2504.sh [--auto-reboot]

set -euo pipefail

AUTO_REBOOT="no"
[[ "${1:-}" == "--auto-reboot" ]] && AUTO_REBOOT="yes"

LOG="/var/log/amd-reset-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== AMD GPU stack factory-reset for Ubuntu 25.04 ==="
echo "Log: $LOG"

# --- Safety checks ---
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"; exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found. This script is for Debian/Ubuntu systems."; exit 1
fi

UBU_REL="$(. /etc/os-release; echo "${VERSION_ID:-unknown}")"
if [[ "$UBU_REL" != "25.04" ]]; then
  echo "Warning: Detected Ubuntu $UBU_REL (expected 25.04). Proceeding anyway in 10s..."
  sleep 10
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef)

# --- Helper ---
apt_clean_update() {
  apt-get "${APT_FLAGS[@]}" autoremove --purge -y || true
  apt-get "${APT_FLAGS[@]}" autoclean || true
  apt-get update
}

# --- 1) Backup APT sources ---
echo "Backing up APT sources to /etc/apt/sources.list.d.bak-$(date +%s)"
mkdir -p /etc/apt/sources.list.d.bak
cp -a /etc/apt/sources.list /etc/apt/sources.list.bak-"$(date +%s)" || true
cp -a /etc/apt/sources.list.d/* /etc/apt/sources.list.d.bak/ 2>/dev/null || true

# --- 2) Remove external AMD/graphics repos & pins ---
echo "Removing AMDGPU-PRO/ROCm and Mesa PPAs from APT sources..."
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.list; do
  if grep -Eiq '(repo\.radeon\.com|rocm|oibaf|kisak|graphics-drivers)' "$f"; then
    echo "Disabling repo: $f"
    mv -f "$f" "${f}.disabled.$(date +%s)"
  fi
done
for p in /etc/apt/preferences.d/*; do
  if grep -Eiq '(amdgpu|rocm|radeon)' "$p"; then
    echo "Removing APT pin: $p"
    mv -f "$p" "${p}.disabled.$(date +%s)"
  fi
done
rm -f /etc/apt/trusted.gpg.d/*amdgpu* /etc/apt/trusted.gpg.d/*rocm* 2>/dev/null || true
apt_clean_update

# --- 3) Collect & purge third-party AMD/ROCm packages ---
echo "Searching for AMDGPU-PRO/ROCm packages to purge..."
PKG_PATTERNS=(
  '^amdgpu(-.*)?$'
  '^amdgpu-pro(-.*)?$'
  '^opencl-amdgpu(-.*)?$'
  '^ocl-icd-amdgpu(-.*)?$'
  '^vulkan-amdgpu(-.*)?$'
  '^hip(-.*)?$' '^hipblas(-.*)?$' '^hipfft(-.*)?$' '^hiprand(-.*)?$' '^hipsparse(-.*)?$'
  '^hsa(-.*)?$' '^hsakmt-roct(-.*)?$' '^hsa-rocr(-.*)?$'
  '^roc(-.*)?$' '^rocm(-.*)?$' '^rocr(-.*)?$' '^roct(-.*)?$'
  '^amf(-.*)?$'
)
PURGE_LIST=()
while read -r name state; do
  for pat in "${PKG_PATTERNS[@]}"; do
    if [[ "$name" =~ $pat ]]; then
      PURGE_LIST+=("$name")
      break
    fi
  done
done < <(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | awk '$2=="installed"{print $1" "$2}')

if ((${#PURGE_LIST[@]})); then
  echo "Purging: ${PURGE_LIST[*]}"
  apt-get "${APT_FLAGS[@]}" purge "${PURGE_LIST[@]}" || true
else
  echo "No matching third-party AMD/ROCm packages found."
fi

# --- 4) Remove AMD DKMS modules (from AMDGPU-PRO) ---
echo "Removing AMD DKMS modules (if any)..."
if command -v dkms >/dev/null 2>&1; then
  dkms status || true
  # Remove any dkms modules that look AMD-related
  while read -r mod ver rest; do
    m="${mod%%,*}"
    v="${ver%%,*}"
    if [[ "$m" =~ ^(amdgpu|amf|rocm|roc.*|hsa.*)$ ]]; then
      echo "dkms remove -m $m -v $v --all"
      dkms remove -m "$m" -v "$v" --all || true
    fi
  done < <(dkms status 2>/dev/null | sed 's/, /,/g' | awk '{print $1" "$2" "$0}')
fi

# --- 5) Clean leftovers ---
echo "Cleaning leftover directories and modprobe config..."
rm -rf /opt/amdgpu /opt/amdgpu-pro /opt/rocm* 2>/dev/null || true
find /etc/modprobe.d -maxdepth 1 -type f -iname '*amdgpu*.conf' -exec mv -f {} {}.disabled.$(date +%s) \; 2>/dev/null || true
find /etc/modprobe.d -maxdepth 1 -type f -iname '*radeon*.conf' -exec mv -f {} {}.disabled.$(date +%s) \; 2>/dev/null || true

# --- 6) Refresh package state ---
apt_clean_update
apt-get "${APT_FLAGS[@]}" -o APT::Get::AutomaticRemove=true autoremove --purge || true

# --- 7) (Re)install stock Ubuntu graphics/kernel stack ---
echo "Installing stock Ubuntu AMD stack and kernel meta..."
# Kernel meta for 25.04 is typically linux-generic
apt-get "${APT_FLAGS[@]}" install \
  linux-generic linux-headers-generic linux-image-generic \
  linux-firmware \
  xserver-xorg-video-amdgpu \
  libdrm2 libdrm-amdgpu1 \
  mesa-vulkan-drivers libgl1-mesa-dri \
  mesa-opencl-icd \
  vulkan-tools \
  pciutils initramfs-tools || true

# Ensure headers match running kernel (helps DKMS-less builds and tools)
KREL="$(uname -r || true)"
apt-get "${APT_FLAGS[@]}" install "linux-headers-$KREL" || true

# --- 8) Regenerate initramfs & update GRUB ---
echo "Rebuilding initramfs and updating GRUB..."
update-initramfs -c -k all || update-initramfs -u -k all
update-grub || true

# --- 9) Enable amdgpu and basic sanity checks ---
echo "Ensuring amdgpu module preference..."
# Prefer amdgpu over radeon (modern GPUs)
printf 'options amdgpu si_support=1 cik_support=1\noptions radeon si_support=0 cik_support=0\n' > /etc/modprobe.d/10-amdgpu-prefer.conf || true

echo "Attempting to load amdgpu (may fail until reboot if X is using it)..."
modprobe amdgpu || true

echo "=== Done. ==="
echo "Recommended: reboot to load the clean, stock stack."

if [[ "$AUTO_REBOOT" == "yes" ]]; then
  echo "Auto-rebooting in 10 seconds... (Ctrl+C to cancel)"
  sleep 10
  systemctl reboot
else
  echo "Run: sudo reboot"
fi
