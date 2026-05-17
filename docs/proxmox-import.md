# Proxmox Import

Steps to build a QCOW2 disk image from the bootc container image and import it
into Proxmox as a VM.

## Automated (recommended)

Use `examples/proxmox/rebuild-vm.sh`. It pulls the image, builds the QCOW2,
creates or recreates the VM, and starts it:

```bash
bash examples/proxmox/rebuild-vm.sh <vmid> \
  --image <your-registry>/<image>:latest \
  --user-data examples/cloud-init/clawx-leash-user-data.yaml
```

The script generates a fresh `instance-id` in the seed ISO on every run, so
cloud-init always re-runs after a rebuild. Run with `--help` for all options.

## Manual steps

### Prerequisites

- Proxmox host with `podman` and `genisoimage` installed
- The bootc image pushed to your container registry
- Sufficient disk space for the intermediate QCOW2 (typically 10 GB)
- **vmbr1 must not have 10.10.10.1 assigned** — that IP belongs to the leash
  proxy VM. If Proxmox has an IP on vmbr1 for management access, use a
  different address (e.g. `10.10.10.254`). An IP conflict here causes all
  agent traffic to hit the Proxmox bridge instead of the proxy.
- **CPU type must be `host` or x86-64-v2 compatible** — the service-gator
  image (RHEL UBI 10 base) requires x86-64-v2 instructions. The default
  Proxmox CPU type (`kvm64`) does not provide these; the VM will crash on
  start with `Fatal glibc error: CPU does not support x86-64-v2`.
  `rebuild-vm.sh` sets `--cpu host` automatically.

### 1. Pull the bootc image

```bash
podman login <your-registry>
podman pull <your-registry>/<image>:latest
```

### 2. Build the QCOW2

```bash
mkdir -p /tmp/tank-output
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v /tmp/tank-output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs xfs \
  --output /output/ \
  <your-registry>/<image>:latest
```

The QCOW2 is written to `/tmp/tank-output/qcow2/disk.qcow2`.

### 3. Build a seed ISO

The `instance-id` must be unique on every VM rebuild, otherwise cloud-init
skips re-running. Generate it dynamically:

```bash
tmpdir="$(mktemp -d)"
cp examples/cloud-init/clawx-leash-user-data.yaml "$tmpdir/user-data"
printf 'instance-id: clawx-%s\nlocal-hostname: clawx\n' "$(date +%s)" \
  > "$tmpdir/meta-data"
# network-config is processed in cloud-init-local (before NetworkManager starts)
# so the static IP is configured before NetworkManager-wait-online runs.
cat > "$tmpdir/network-config" <<'NETCONF'
version: 2
ethernets:
  id0:
    match:
      name: "en*"
    addresses:
      - 10.10.10.2/24
    routes:
      - to: default
        via: 10.10.10.1
    nameservers:
      addresses:
        - 9.9.9.9
NETCONF
genisoimage -output /var/lib/vz/template/iso/tank-claw-os-seed.iso \
  -volid cidata -joliet -rock "$tmpdir"
```

Upload the resulting ISO to your Proxmox ISO storage, or use its path directly
in the next step.

### 4. Create the VM

```bash
qm create <vmid> \
  --name tank-claw-os \
  --memory 8192 \
  --cores 2 \
  --cpu host \
  --net0 virtio,bridge=vmbr1 \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26

qm importdisk <vmid> /tmp/tank-output/qcow2/disk.qcow2 <storage>

qm set <vmid> \
  --scsi0 <storage>:vm-<vmid>-disk-0,discard=on \
  --ide2 <storage>:iso/tank-claw-os-seed.iso,media=cdrom

qm resize <vmid> scsi0 30G

# Set boot order after all devices are attached — Proxmox may override it
# if set in the same command as device additions.
qm set <vmid> --boot order=scsi0
```

### 5. Start the VM

```bash
qm start <vmid>
```

Check the assigned IP once the guest agent is up:

```bash
qm guest cmd <vmid> network-get-interfaces
```

Then follow [first-boot.md](first-boot.md) to configure the agent.

## Updating an existing VM

When a new image is available, use `bootc` from inside the running VM:

```bash
ssh clawx@<vm-ip>
sudo bootc switch --apply <your-registry>/<image>:latest
```

For a full rebuild (new QCOW2 from scratch), re-run `rebuild-vm.sh` or repeat
the manual steps above. The VM's cloud-init state is reset on every rebuild.
