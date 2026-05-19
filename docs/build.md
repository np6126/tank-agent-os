# Build

## Build The Bootc Container Image

The build has two stages: the clawx runtime container image and the bootc OS
image. Build and push the runtime image first; the bootc image references it
via `--build-arg`.

```text
tank-agent-os/
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

The bootc image embeds exactly one agent at build time, chosen via
`AGENT_KIND` (default `claw`). Supported values:

| `AGENT_KIND` | Agent       | Build form                                        |
|--------------|-------------|---------------------------------------------------|
| `claw`       | `claw-code` | source-build (Rust/cargo) with patches            |
| `opencode`   | `opencode`  | upstream Bun-compiled binary, SHA-pinned download |

One agent per image — no runtime switching. The host wrapper
(`/usr/local/bin/clawx`) reads `/etc/clawx/agent.kind` to know which agent's
CLI conventions to apply.

Build the bootc image from the repo root. The final `bootc` argument is the
build context directory in this repo:

For x86_64. The agent variant is encoded in the tag, not the image name:

```bash
# claw build (default)
podman build \
  --platform linux/amd64 \
  --build-arg AGENT_KIND=claw \
  --build-arg CLAWX_RUNTIME_IMAGE=<your-registry>/clawx-runtime \
  --build-arg CLAWX_RUNTIME_REF=latest \
  -t localhost/tank-agent-os:claw \
  -f bootc/Containerfile \
  bootc

# opencode build
podman build \
  --platform linux/amd64 \
  --build-arg AGENT_KIND=opencode \
  --build-arg CLAWX_RUNTIME_IMAGE=<your-registry>/clawx-runtime \
  --build-arg CLAWX_RUNTIME_REF=latest \
  -t localhost/tank-agent-os:opencode \
  -f bootc/Containerfile \
  bootc
```

The CI workflow publishes:

| Tag                              | What it points to                       |
|----------------------------------|-----------------------------------------|
| `tank-agent-os:claw`              | latest claw build                       |
| `tank-agent-os:claw-<sha>`        | pinned claw build for commit `<sha>`    |
| `tank-agent-os:opencode`          | latest opencode build                   |
| `tank-agent-os:opencode-<sha>`    | pinned opencode build for commit `<sha>`|
| `tank-agent-os:latest`            | alias for `:claw` (backwards-compat)    |
| `tank-agent-os:<sha>`             | alias for `:claw-<sha>` (backwards-compat) |

For Apple Silicon, swap `linux/amd64` for `linux/arm64`. For opencode on
arm64, also override `OPENCODE_ASSET=opencode-linux-arm64.tar.gz` and the
corresponding `OPENCODE_SHA256`.

The default base is `quay.io/fedora/fedora-bootc:latest`. Per-agent pins
live in `bootc/Containerfile`:

```env
# claw-code (source build, patches applied)
CLAW_CODE_REPO=https://github.com/ultraworkers/claw-code.git
CLAW_CODE_REF=63ce483c2788a96f470acd4625d8540292bdd16e
CLAW_CODE_SHA256=88e8b34f...        # see "Reproducible build" below

# opencode (upstream binary download)
OPENCODE_RELEASE_BASE=https://github.com/anomalyco/opencode/releases/download
OPENCODE_REF=v1.15.4
OPENCODE_ASSET=opencode-linux-x64.tar.gz
OPENCODE_SHA256=f0734928...         # see "Reproducible build" below
```

If `CLAWX_RUNTIME_IMAGE` and `CLAWX_RUNTIME_REF` are omitted, the Quadlet uses
the unmodified `quay.io/fedora/fedora:44` base image (no development tools).

### Reproducible build

The same pin-then-verify pattern applies to both agents, but the trust input
differs:

| Agent     | What is pinned             | What is verified                     |
|-----------|----------------------------|--------------------------------------|
| `claw`    | Git commit + 3 patches     | SHA-256 of the locally-built binary  |
| `opencode`| Upstream release tag + asset | SHA-256 of the downloaded tarball   |

For claw, the trust surface includes our toolchain (Fedora `rust`) and the
patches. For opencode, the trust surface is the upstream maintainer's CI —
we only verify the artifact's identity.

#### claw-code

The `claw-builder` stage compiles `claw-code` deterministically:

- `RUSTFLAGS="--remap-path-prefix=…"` — strips absolute build paths from the
  binary so the host filesystem layout does not leak into the artifact.
- `RUSTFLAGS="… -C strip=symbols"` — removes debug symbol tables that
  otherwise vary between builds.
- `cargo build --workspace --release` runs **without** `--locked`. The `sed`
  step in the same `RUN` flips `reqwest` from `rustls-tls` to
  `rustls-tls-native-roots`, which pulls `rustls-native-certs` into the
  dependency graph and forces `Cargo.lock` to expand — `--locked` would
  reject that. The `CLAW_CODE_SHA256` pin on the resulting binary is the
  primary defence against dependency drift: any change in the resolved
  dependency graph changes the binary's bytes, the SHA-256 mismatches, and
  the build fails before an image is produced.

After the build, the stage computes the SHA-256 of the produced binary,
prints a summary line, writes the hash into the builder-stage scratch dir,
and (if `CLAW_CODE_SHA256` is set) compares it. A mismatch fails the build.

#### opencode

The `opencode-builder` stage **does not compile**. It downloads the upstream
release tarball (`OPENCODE_ASSET`) from `OPENCODE_RELEASE_BASE/OPENCODE_REF`,
verifies its SHA-256 against `OPENCODE_SHA256`, extracts the single binary,
and re-hashes it for the runtime hash file.

The trust assumption is the same as for `service-gator`: we trust the
upstream maintainer's build and verify only the artifact's identity.

#### Selected binary in the final image

The final stage `COPY`es both builder outputs into `/opt/agent-candidates/`
and a `RUN` step selects the one matching `AGENT_KIND`, installs it as
`/usr/local/bin/agent`, and writes the hash file to
`/usr/local/share/tank-os/agent.sha256`. The unselected candidate is removed.
The selected agent's identity is recorded in `/etc/clawx/agent.kind` for the
host wrapper to consult.

**Recording-then-pinning workflow** (same for both agents — replace `<NAME>`
with `CLAW_CODE` or `OPENCODE`):

1. First build of a new `<NAME>_REF` — leave `<NAME>_SHA256` empty. The
   build log prints the recorded hash.
2. Pin that hash in `bootc/Containerfile`.
3. From then on, every rebuild verifies the binary against the pinned hash.

**When the hash must be re-recorded:**

- For `claw`: `CLAW_CODE_REF` bumped, a patch in `bootc/patches/` changed,
  `FEDORA_BOOTC_REF` upgraded (different `rust` package), or build target
  architecture changed.
- For `opencode`: `OPENCODE_REF` bumped or `OPENCODE_ASSET` switched (e.g.
  arm64 vs amd64). Toolchain changes upstream do not concern us since we
  download a pre-built binary.

**Runtime verification:** the hash file ships at
`/usr/local/share/tank-os/agent.sha256` (path is agent-agnostic). On a
running VM:

```bash
sudo sha256sum -c /usr/local/share/tank-os/agent.sha256
```

confirms the deployed binary still matches what the image build produced —
catches in-place tampering on the bootc filesystem regardless of which
agent variant is installed.

## CI: Built tags

`.gitea/workflows/build.yml` publishes per push to `main`:

| Tag                              | Points at                                            |
|----------------------------------|------------------------------------------------------|
| `tank-agent-os:claw`              | latest claw build                                    |
| `tank-agent-os:claw-<sha>`        | pinned claw build for that commit                    |
| `tank-agent-os:opencode`          | latest opencode build                                |
| `tank-agent-os:opencode-<sha>`    | pinned opencode build for that commit                |
| `tank-agent-os:latest`            | alias for `:claw` (backwards-compat)                 |
| `tank-agent-os:<sha>`             | alias for `:claw-<sha>` (backwards-compat)           |

## Build A Disk Image With Podman Desktop

The Podman Desktop BootC extension can build a VM disk image from
`localhost/tank-agent-os:latest`.

Recommended local test settings:

- Bootc image: `localhost/tank-agent-os:latest`
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
mkdir -p out-tank-agent-os
```

Optionally create a bootc-image-builder config to inject a local SSH key. Do not
put private keys or long-lived secrets here.

> **Dev only:** `"groups": ["wheel"]` grants unrestricted sudo and is intentional
> for local VMs where the operator writes `/etc/clawx/proxy.env` manually. Remove
> it for production deployments that provision via cloud-init.

```bash
cat > out-tank-agent-os/config.json <<'EOF'
{
  "customizations": {
    "user": [
      {
        "name": "clawx",
        "key": "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-agent-os",
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
  --name tank-agent-os-bootc-image-builder \
  --tty \
  --privileged \
  --security-opt label=type:unconfined_t \
  -v "$PWD/out-tank-agent-os:/output/" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/out-tank-agent-os/config.json:/config.json:ro" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  localhost/tank-agent-os:latest \
  --output /output/ \
  --local \
  --progress verbose \
  --type qcow2 \
  --target-arch arm64 \
  --rootfs xfs
```

The resulting disk image is:

```text
out-tank-agent-os/qcow2/disk.qcow2
```

## What The Image Installs

The image creates a `clawx` login user with UID/GID 1000, enables linger for
that user, installs a pinned `/usr/local/bin/agent` (the agent binary, either
claw-code or opencode depending on `AGENT_KIND`), and installs a rootless
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

### Pinned components

Every pinned input shares the same update path: edit the relevant `ARG` in
the Containerfile noted in the table below, rebuild and push the image,
then apply it to the running VM. No VM teardown is needed — disk state
(`/var/home/clawx`, Podman secrets, workspaces) survives every upgrade.

| Component | ARG to change | Where it lives |
|---|---|---|
| Agent selection | `AGENT_KIND` (`claw` or `opencode`) | one builder stage per agent; only the selected one is installed under `/usr/local/bin/agent` |
| `claw-code` | `CLAW_CODE_REF` + `CLAW_CODE_SHA256` | compiled into bootc image when `AGENT_KIND=claw`; binary hash verified at build time |
| `opencode` | `OPENCODE_REF` + `OPENCODE_SHA256` (+ `OPENCODE_ASSET` for arch) | downloaded into bootc image when `AGENT_KIND=opencode`; tarball + binary hashes verified at build time |
| `@opencode-ai/plugin` SDK | `OPENCODE_PLUGIN_VERSION` + `OPENCODE_PLUGIN_SHA256` in `bootc/clawx-runtime/Containerfile` | npm tarball downloaded + sha256-verified at clawx-runtime build, pre-installed into image so opencode's startup-time `bun install` finds it locally and skips the runtime npm fetch. **Must be bumped together with `OPENCODE_REF`** — opencode pins this dep internally to its own binary version, and a mismatch makes opencode treat the dep as dirty and trigger the runtime install path we are closing. |
| `service-gator` | `SERVICE_GATOR_REF` | digest substituted into Quadlet at build time |
| SearXNG | `SEARXNG_REF` | digest substituted into Quadlet at build time (opencode image auto-enables; claw image ships disabled) |
| `mcp-searxng` | `MCP_SEARXNG_VERSION` in `bootc/clawx-runtime/Containerfile` | npm version pin; installed with `--ignore-scripts` inside the clawx-runtime image, no separate OCI image |
| `docs-mcp-server` | `DOCS_MCP_REF` | digest substituted into Quadlet at build time (opencode image auto-enables; claw image ships disabled). Re-run the [MCP adoption gate](../docs/security.md#mcp-adoption-gate) when crossing major versions. |
| Agent memory persistence | `AGENT_MEMORY_PERSIST` (`true` / `false`, default `false`) | When `true`, `clawx-init` symlinks the agent's memory directory into `~/.clawx/` so notes survive container recreate. Default `false` keeps memory in the ephemeral overlay-FS. **Threat-model trade-off** documented in [memory.md](memory.md). |
| clawx runtime | `CLAWX_RUNTIME_IMAGE` / `CLAWX_RUNTIME_REF` | pulled by rootless Podman from registry on first start |
| Fedora / OS base | `FEDORA_BOOTC_REF` | bootc image layer |

After pushing a new bootc image, switch the VM to the registry ref:

```bash
sudo bootc status
sudo bootc switch --apply <registry>/<namespace>/tank-agent-os:latest
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

2. In `bootc/Containerfile`, bump `CLAW_CODE_REF` and clear `CLAW_CODE_SHA256`
   (the new commit will produce a new binary hash).
3. Rebuild — read the new SHA from the build summary and pin it.
4. Rebuild a second time to confirm the pin verifies, then push.
5. Apply on the running VM with `sudo bootc upgrade --apply`. After reboot,
   `/usr/local/bin/agent` on the host is the new binary.

### Example: updating opencode

1. Find the new release tag from
   `https://github.com/anomalyco/opencode/releases`.
2. Download the new tarball locally and compute its SHA-256:

   ```bash
   curl -fsSL -o /tmp/opencode.tar.gz \
     "https://github.com/anomalyco/opencode/releases/download/<tag>/opencode-linux-x64.tar.gz"
   sha256sum /tmp/opencode.tar.gz
   ```

3. Bump `OPENCODE_REF` and `OPENCODE_SHA256` in `bootc/Containerfile`.
4. Rebuild with `--build-arg AGENT_KIND=opencode`. The build verifies the
   tarball hash before extraction; mismatch fails the build.
5. Push and apply on the running VM.

### When a full VM rebuild is needed

`rebuild-vm.sh` (which destroys and recreates the VM) is only required when
cloud-init provisioning state needs to change — SSH keys, static IP, proxy
config written by `write_files`, or secrets injected at first boot. It is
never required for component version changes.
