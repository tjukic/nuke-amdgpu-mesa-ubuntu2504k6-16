#!/usr/bin/env bash
# reset-mesa-vulkan-ubuntu2504.sh
# Reset ONLY the Mesa/Vulkan/OpenGL stack on Ubuntu 25.04 back to distro defaults.
# No kernel changes. Non-interactive.
# Usage: sudo bash reset-mesa-vulkan-ubuntu2504.sh

set -euo pipefail

LOG="/var/log/mesa-reset-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Mesa/Vulkan stack reset for Ubuntu 25.04 ==="
echo "Log: $LOG"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"; exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get not found."; exit 1
fi

UBU_REL="$(. /etc/os-release; echo "${VERSION_ID:-unknown}")"
if [[ "$UBU_REL" != "25.04" ]]; then
  echo "Warning: Detected Ubuntu $UBU_REL (expected 25.04). Proceeding in 5s..."
  sleep 5
fi

export DEBIAN_FRONTEND=noninteractive
APT_FLAGS=(-y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef)

apt_update() {
  apt-get update
}

echo "[1/7] Backing up APT sources and disabling graphics PPAs..."
mkdir -p /etc/apt/sources.list.d.bak
cp -a /etc/apt/sources.list /etc/apt/sources.list.bak-"$(date +%s)" || true
for f in /etc/apt/sources.list.d/*.list 2>/dev/null; do
  if grep -Eiq '(oibaf|kisak|llvm-toolchain|repo\.radeon\.com|rocm|graphics-drivers)' "$f"; then
    echo "Disabling $f"
    mv -f "$f" "${f}.disabled.$(date +%s)"
  fi
done

apt_update

echo "[2/7] Ensure i386 architecture is enabled (for Steam/32-bit OpenGL/Vulkan)..."
if ! dpkg --print-foreign-architectures | grep -qx i386; then
  dpkg --add-architecture i386
  apt_update
fi

echo "[3/7] Remove obvious third-party Vulkan/OpenCL bits (keeps kernel untouched)..."
# These are safe to remove if present; they often override Mesa.
apt-get "${APT_FLAGS[@]}" purge \
  amdvlk vulkan-amdgpu-pro* opencl-amdgpu* ocl-icd-amdgpu* 2>/dev/null || true

echo "[4/7] Reinstall stock Ubuntu Mesa/DRM/Vulkan (amd64 + i386)..."
# Core runtime
apt-get "${APT_FLAGS[@]}" install --reinstall \
  libdrm2 libdrm-amdgpu1 libdrm-common \
  libgl1 libglx0 libegl1 libgbm1 \
  libgl1-mesa-dri libglx-mesa0 mesa-vulkan-drivers \
  libvulkan1 vulkan-tools mesa-utils \
  xserver-xorg-video-amdgpu

# 32-bit userspace (helps Proton/Steam)
apt-get "${APT_FLAGS[@]}" install --reinstall \
  libdrm2:i386 libdrm-amdgpu1:i386 \
  libgl1:i386 libglx0:i386 libegl1:i386 libgbm1:i386 \
  libgl1-mesa-dri:i386 libglx-mesa0:i386 mesa-vulkan-drivers:i386 \
  libvulkan1:i386

echo "[5/7] Reset GL alternatives to Mesa (if alternatives exist)..."
if update-alternatives --list x86_64-linux-gnu_gl_conf >/dev/null 2>&1; then
  # Typical Mesa ld.so.conf
  if [[ -f /usr/lib/x86_64-linux-gnu/mesa/ld.so.conf ]]; then
    update-alternatives --set x86_64-linux-gnu_gl_conf /usr/lib/x86_64-linux-gnu/mesa/ld.so.conf || true
  else
    update-alternatives --auto x86_64-linux-gnu_gl_conf || true
  fi
  ldconfig
fi
if update-alternatives --list i386-linux-gnu_gl_conf >/dev/null 2>&1; then
  if [[ -f /usr/lib/i386-linux-gnu/mesa/ld.so.conf ]]; then
    update-alternatives --set i386-linux-gnu_gl_conf /usr/lib/i386-linux-gnu/mesa/ld.so.conf || true
  else
    update-alternatives --auto i386-linux-gnu_gl_conf || true
  fi
  ldconfig
fi

echo "[6/7] Clean up ICDs and shader caches..."
# Vulkan ICDs: keep Mesa RADV; quarantine other AMD ICDs that may override Mesa.
mkdir -p /var/backups/vulkan-icd-bak
shopt -s nullglob
for j in /etc/vulkan/icd.d/*.json; do
  if ! grep -Eq '"library_path".*radv' "$j"; then
    echo "Quarantining ICD: $j"
    mv -f "$j" "/var/backups/vulkan-icd-bak/$(basename "$j").disabled.$(date +%s)"
  fi
done

# OpenCL vendors: keep ocl-icd default; move amdocl if present
mkdir -p /var/backups/opencl-vendors-bak
for v in /etc/OpenCL/vendors/*.icd 2>/dev/null; do
  if grep -Eiq '(amdocl|rocm|amdgpu)' "$v"; then
    echo "Quarantining OpenCL ICD: $v"
    mv -f "$v" "/var/backups/opencl-vendors-bak/$(basename "$v").disabled.$(date +%s)"
  fi
done

# Shader caches (all users)
for home in /home/*; do
  rm -rf "$home/.cache/mesa_shader_cache" 2>/dev/null || true
done
# root's cache
rm -rf /root/.cache/mesa_shader_cache 2>/dev/null || true

echo "[7/7] Final tidy & basic diagnostics..."
apt-get "${APT_FLAGS[@]}" -o APT::Get::AutomaticRemove=true autoremove --purge || true
apt-get "${APT_FLAGS[@]}" autoclean || true
ldconfig

echo
echo "=== Reset complete. ==="
echo "Quick checks (non-fatal if they fail now):"
echo " - glxinfo -B | grep -E 'OpenGL renderer|OpenGL core profile'   (from mesa-utils)"
echo " - vulkaninfo | grep -E 'GPU id|driverName|apiVersion'          (from vulkan-tools)"
echo
echo "If you were in a running X/Wayland session, a reboot or full logout/login is recommended."
