#!/usr/bin/env bash
# Rebuild a tank-agent-os agent VM on Proxmox VE.
#
# Usage:
#   rebuild-vm.sh <VMID> [options]
#
# Options:
#   --image IMAGE     Container image to deploy (required, or set TANK_IMAGE env var)
#   --storage POOL    Proxmox storage pool for the VM disk (default: local-lvm)
#   --bridge BRIDGE   Network bridge to attach to (default: vmbr1)
#   --memory MB       RAM in MB (default: 6144)
#   --balloon MB      Balloon floor in MB. 0 disables ballooning (default: 3072)
#   --ip IPV4         Static IPv4 the seed ISO wires onto ens18 (default: 10.10.10.2).
#                     Gateway 10.10.10.1 is the leash proxy and is fixed.
#   --cores N         CPU cores (default: 2)
#   --disk-size SIZE  Disk size, passed to qm resize (default: 30G)
#   --user-data FILE  Path to cloud-init user-data file (required)
#   --vendor-data FILE  Optional cloud-init vendor-data file. When supplied,
#                       it is placed on the NoCloud seed ISO alongside
#                       user-data; cloud-init merges them at boot (vendor
#                       runs first, user overrides per merge_how rules).
#                       Used to keep a single agent-agnostic base file and
#                       a small per-agent overlay.
#
# Example — build two agents on the same host:
#   rebuild-vm.sh 300
#   rebuild-vm.sh 301 --bridge vmbr2
#
# The seed ISO is rebuilt on every run with a fresh instance-id so
# cloud-init always re-runs after a VM rebuild.
set -euo pipefail

# ── defaults ───────────────────────────────────────────────────────────────────
IMAGE=""  # required: set via --image or TANK_IMAGE env var
STORAGE="local-lvm"
BRIDGE="vmbr1"
MEMORY=6144
BALLOON=3072
IP="10.10.10.2"
CORES=2
DISK_SIZE="30G"
USER_DATA=""  # required: set via --user-data
VENDOR_DATA=""  # optional: set via --vendor-data

# ── argument parsing ───────────────────────────────────────────────────────────
if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
    sed -n '2,/^set -/{ /^set -/d; s/^# \{0,1\}//; p }' "$0"
    exit 0
fi

VMID="$1"; shift
IMAGE="${TANK_IMAGE:-$IMAGE}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)      IMAGE="$2";      shift 2 ;;
        --storage)    STORAGE="$2";    shift 2 ;;
        --bridge)     BRIDGE="$2";     shift 2 ;;
        --memory)     MEMORY="$2";     shift 2 ;;
        --balloon)    BALLOON="$2";    shift 2 ;;
        --ip)         IP="$2";         shift 2 ;;
        --cores)      CORES="$2";      shift 2 ;;
        --disk-size)  DISK_SIZE="$2";  shift 2 ;;
        --user-data)    USER_DATA="$2";    shift 2 ;;
        --vendor-data)  VENDOR_DATA="$2";  shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$IMAGE" ]]; then
    echo "ERROR: --image is required (or set TANK_IMAGE env var)" >&2
    exit 1
fi
if [[ -z "$USER_DATA" ]]; then
    echo "ERROR: --user-data is required" >&2
    exit 1
fi

ISO_PATH="/var/lib/vz/template/iso/tank-agent-os-seed-${VMID}.iso"
BUILD_DIR="/tmp/tank-agent-os-build-${VMID}"
CIDATA=""

# Remove the QCOW2 build dir and the cloud-init seed dir on exit: once the
# disk is imported they are no longer needed, and a mid-run failure under
# `set -e` would otherwise leave the (large) QCOW2 dir behind.
cleanup() {
    rm -rf "$BUILD_DIR"
    [[ -n "$CIDATA" ]] && rm -rf "$CIDATA"
    return 0
}
trap cleanup EXIT

# ── pull image ─────────────────────────────────────────────────────────────────
echo "==> Pulling $IMAGE ..."
podman pull "$IMAGE"

# ── build QCOW2 ───────────────────────────────────────────────────────────────
echo "==> Building QCOW2 ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$BUILD_DIR:/output" \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --rootfs xfs \
    --output /output/ \
    "$IMAGE"

# ── build seed ISO with fresh instance-id ─────────────────────────────────────
echo "==> Building seed ISO ..."
CIDATA="$(mktemp -d)"
cp "$USER_DATA" "$CIDATA/user-data"
if [[ -n "$VENDOR_DATA" ]]; then
    cp "$VENDOR_DATA" "$CIDATA/vendor-data"
fi
printf 'instance-id: clawx-%s\nlocal-hostname: clawx\n' "$(date +%s)" > "$CIDATA/meta-data"
# network-config is processed by cloud-init-local (before NetworkManager starts),
# ensuring the static IP is configured before NetworkManager-wait-online runs.
cat > "$CIDATA/network-config" <<NETCONF
version: 2
ethernets:
  id0:
    match:
      name: "en*"
    addresses:
      - ${IP}/24
    routes:
      - to: default
        via: 10.10.10.1
    nameservers:
      addresses:
        - 9.9.9.9
NETCONF
ISO_INPUTS=("$CIDATA/user-data" "$CIDATA/meta-data" "$CIDATA/network-config")
[[ -n "$VENDOR_DATA" ]] && ISO_INPUTS+=("$CIDATA/vendor-data")
genisoimage -output "$ISO_PATH" -volid cidata -joliet -rock \
    "${ISO_INPUTS[@]}" 2>/dev/null
rm -rf "$CIDATA"

# ── stop and destroy existing VM ──────────────────────────────────────────────
if qm status "$VMID" &>/dev/null; then
    echo "==> Stopping and destroying VM $VMID ..."
    qm stop "$VMID" --timeout 30 || true
    qm destroy "$VMID" --purge
fi

# `qm destroy --purge` returns 0 even when `lvremove` fails to drop one of
# the VM's logical volumes (e.g. a stale DM mapping holds it "in use").
# If we proceed, `qm importdisk` allocates `vm-${VMID}-disk-1` instead of
# disk-0 and a hardcoded `--scsi0 ...-disk-0` would silently attach the
# *old* disk to scsi0 — the VM then boots the previous deployment and the
# downstream digest check fails after a 12-minute roundtrip.
LEFTOVER="$(lvs --noheadings -o lv_name,vg_name 2>/dev/null | awk -v v="$VMID" '$1 ~ "^vm-" v "-disk-" {print $2"/"$1}')"
if [[ -n "$LEFTOVER" ]]; then
    echo "ERROR: qm destroy --purge left behind logical volumes for VM $VMID:" >&2
    echo "$LEFTOVER" >&2
    echo "Fix: stop holders / lvremove manually before re-running." >&2
    exit 1
fi

# ── create VM ─────────────────────────────────────────────────────────────────
echo "==> Creating VM $VMID ..."
qm create "$VMID" \
    --name "tank-agent-os-${VMID}" \
    --memory "$MEMORY" \
    --balloon "$BALLOON" \
    --cores "$CORES" \
    --cpu host \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --ostype l26

# Capture the imported-disk reference from `qm importdisk` output instead of
# assuming it lands as `disk-0`. Belt-and-braces companion to the leftover-LV
# check above: even if some future code path leaves a stray LV, we'll attach
# the *new* image we just imported, not whatever the old slot held.
IMPORT_LOG="$(mktemp)"
qm importdisk "$VMID" "$BUILD_DIR/qcow2/disk.qcow2" "$STORAGE" 2>&1 | tee "$IMPORT_LOG"
IMPORTED_DISK="$(grep -oE "successfully imported disk '[^']+'" "$IMPORT_LOG" | tail -1 | sed -E "s/.*'([^']+)'.*/\1/")"
rm -f "$IMPORT_LOG"
if [[ -z "$IMPORTED_DISK" ]]; then
    echo "ERROR: could not parse imported disk reference from qm importdisk output" >&2
    exit 1
fi
echo "==> Imported disk: $IMPORTED_DISK"

qm set "$VMID" \
    --scsi0 "${IMPORTED_DISK},discard=on" \
    --ide2 "local:iso/tank-agent-os-seed-${VMID}.iso,media=cdrom"

qm resize "$VMID" scsi0 "$DISK_SIZE"

# Set boot order after all devices are added — Proxmox may override it
# if devices are added in the same command or a later qm set call.
qm set "$VMID" --boot order=scsi0

qm start "$VMID"
echo ""
echo "==> VM $VMID started. Waiting for guest agent ..."
echo "    Watch console:  qm terminal $VMID"
echo "    Check IP:       qm guest cmd $VMID network-get-interfaces"
