# Build

## Build The Bootc Container Image

The build has two stages: the clawx runtime container image and the bootc OS
image. Build and push the runtime image first; the bootc image references it
via `--build-arg`.

```text
tank-claw-os/
├── bootc/
│   ├── Containerfile          ← bootc OS image
│   ├── clawx-runtime/
│   │   └── Containerfile      ← clawx runtime container image
│   └── rootfs/
└── docs/
```

### 1. Build the clawx runtime image

```bash
podman build \
  --platform linux/arm64 \
  -t <your-registry>/clawx-runtime:latest \
  bootc/clawx-runtime
podman push <your-registry>/clawx-runtime:latest
```

### 2. Build the bootc OS image

Build the bootc image from the repo root. In these commands, the final `bootc`
argument is the build context directory in this repo:

For Apple Silicon:

```bash
podman build \
  --platform linux/arm64 \
  --build-arg CLAWX_RUNTIME_IMAGE=<your-registry>/clawx-runtime \
  --build-arg CLAWX_RUNTIME_REF=latest \
  -t localhost/tank-claw-os:latest \
  -f bootc/Containerfile \
  bootc
```

For x86_64:

```bash
podman build \
  --platform linux/amd64 \
  --build-arg CLAWX_RUNTIME_IMAGE=<your-registry>/clawx-runtime \
  --build-arg CLAWX_RUNTIME_REF=latest \
  -t localhost/tank-claw-os:latest \
  -f bootc/Containerfile \
  bootc
```

The default base is `quay.io/fedora/fedora-bootc:latest`. `claw-code` is built
from source using the pinned build args in `bootc/Containerfile`:

```env
CLAW_CODE_REPO=https://github.com/ultraworkers/claw-code.git
CLAW_CODE_REF=41b769fc5aba3a1a35e8220dd44d53d1de028ad2
```

If `CLAWX_RUNTIME_IMAGE` and `CLAWX_RUNTIME_REF` are omitted, the Quadlet uses
the unmodified `quay.io/fedora/fedora:44` base image (no development tools).

## Build A Disk Image With Podman Desktop

The Podman Desktop BootC extension can build a VM disk image from
`localhost/tank-claw-os:latest`.

Recommended local test settings:

- Bootc image: `localhost/tank-claw-os:latest`
- Disk image type: `qcow2`
- Target architecture: `arm64`, `aarch64`, or `amd64`
- Root filesystem: `xfs`
- User: `clawx`
- SSH public key: your public key
- Groups: `wheel` *(local dev only — remove for production deployments)*
- Password: leave empty

## Build A Disk Image Manually

Create an output directory:

```bash
mkdir -p out-tank-claw-os
```

Optionally create a bootc-image-builder config to inject a local SSH key. Do not
put private keys or long-lived secrets here.

> **Dev only:** `"groups": ["wheel"]` grants unrestricted sudo and is intentional
> for local VMs where the operator writes `/etc/clawx/proxy.env` manually. Remove
> it for production deployments that provision via cloud-init.

```bash
cat > out-tank-claw-os/config.json <<'EOF'
{
  "customizations": {
    "user": [
      {
        "name": "clawx",
        "key": "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-claw-os",
        "groups": ["wheel"]
      }
    ]
  }
}
EOF
```

Build the QCOW2 with bootc-image-builder:

```bash
podman --connection podman-machine-default-root run \
  --rm \
  --name tank-claw-os-bootc-image-builder \
  --tty \
  --privileged \
  --security-opt label=type:unconfined_t \
  -v "$PWD/out-tank-claw-os:/output/" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/out-tank-claw-os/config.json:/config.json:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  localhost/tank-claw-os:latest \
  --output /output/ \
  --local \
  --progress verbose \
  --type qcow2 \
  --target-arch arm64 \
  --rootfs xfs
```

The resulting disk image is:

```text
out-tank-claw-os/qcow2/disk.qcow2
```

## What The Image Installs

The image creates a `clawx` login user with UID/GID 1000, enables linger for
that user, installs a pinned `/usr/local/bin/claw`, and installs a rootless
Quadlet at:

```text
/etc/containers/systemd/users/1000/clawx.container
```

Mutable state lives at:

```text
/var/home/clawx/.clawx
/var/home/clawx/workspaces
```

## Upgrade A Running VM

All three pinned components share the same update path: edit the relevant
`ARG` in `bootc/Containerfile`, rebuild and push the image, then apply it
to the running VM. No VM teardown is needed — disk state (`/var/home/clawx`,
Podman secrets, workspaces) survives every upgrade.

| Component | ARG to change | Where it lives |
|---|---|---|
| `claw-code` | `CLAW_CODE_REF` | compiled into bootc image, mounted read-only into `clawx` container |
| `service-gator` | `SERVICE_GATOR_REF` | digest substituted into Quadlet at build time |
| clawx runtime | `CLAWX_RUNTIME_IMAGE` / `CLAWX_RUNTIME_REF` | pulled by rootless Podman from registry on first start |
| Fedora / OS base | `FEDORA_BOOTC_REF` | bootc image layer |

After pushing a new bootc image, switch the VM to the registry ref:

```bash
sudo bootc status
sudo bootc switch --apply <registry>/<namespace>/tank-claw-os:latest
```

After the reboot, future updates against the same tracked tag can use:

```bash
sudo bootc upgrade --apply
```

To roll back the OS to the previous deployment:

```bash
sudo bootc rollback
```

Downgrades work the same way as upgrades — reference an older image tag or
build with an older `ARG` value.

### Example: updating claw-code

1. Find the new commit hash:

   ```bash
   git ls-remote https://github.com/ultraworkers/claw-code.git HEAD
   ```

2. Update the pin in `bootc/Containerfile`:

   ```diff
   -ARG CLAW_CODE_REF=41b769fc5aba3a1a35e8220dd44d53d1de028ad2
   +ARG CLAW_CODE_REF=<new-commit-hash>
   ```

3. Rebuild and push — only the `cargo build` layer is invalidated, all others are cached:

   ```bash
   podman build --platform linux/amd64 \
     -t <your-registry>/tank-claw-os:latest \
     -f bootc/Containerfile bootc
   podman push <your-registry>/tank-claw-os:latest
   ```

4. Apply on the running VM:

   ```bash
   ssh clawx@<vm-ip>
   sudo bootc upgrade --apply
   ```

   After reboot, `/usr/local/bin/claw` on the host is the new binary. The `clawx`
   container mounts it read-only, so it picks up the new version on the next
   `systemctl --user restart clawx.service`.

### When a full VM rebuild is needed

`rebuild-vm.sh` (which destroys and recreates the VM) is only required when
cloud-init provisioning state needs to change — SSH keys, static IP, proxy
config written by `write_files`, or secrets injected at first boot. It is
never required for component version changes.
