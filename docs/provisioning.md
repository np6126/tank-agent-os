# Provisioning

tank-agent-os creates the `clawx` user in the image, but instance access
should be configured at provisioning time. Do not bake private SSH keys,
passwords, API keys, provider endpoints, model names, or private hostnames into
the image.

## Cloud-Init

For deployments behind an egress proxy, use
`examples/cloud-init/clawx-leash-user-data.yaml` as the starting point. For
plain deployments without a proxy, use `examples/cloud-init/clawx-user-data.yaml`.

```yaml
#cloud-config
users:
  - name: clawx
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY tank-agent-os

runcmd:
  - [loginctl, enable-linger, clawx]
```

After boot:

```bash
ssh clawx@<host>
systemctl --user status clawx.service
podman ps
clawx --version
```

The `clawx` command on the host delegates to the running rootless container
and executes the pinned agent binary (`claw-code` or `opencode`, depending
on `AGENT_KIND`). See [cli.md](cli.md).

## Local macOS VM

Podman Desktop can build a QCOW2 from the bootc image and start it as a local
Linux VM. If you use the Podman Desktop BootC extension user form, set the user
to `clawx` and paste your SSH public key there.

When Podman Desktop starts the VM, it may use `macadam` and `gvproxy`. To find
the host-side SSH forward:

```bash
ps aux | grep -E 'macadam|gvproxy|bootc'
```

Look for a process with `-ssh-port <port>`, then connect:

```bash
ssh -o ConnectTimeout=5 \
  -i ~/.ssh/id_ed25519 \
  -p <port> \
  clawx@localhost
```

For UTM, QEMU, or another local VM manager, attach a NoCloud seed ISO.
The `instance-id` must be unique on every VM rebuild, otherwise cloud-init
skips re-running:

```bash
tmpdir="$(mktemp -d)"
cp examples/cloud-init/clawx-user-data.yaml "$tmpdir/user-data"
printf 'instance-id: clawx-%s\nlocal-hostname: clawx\n' "$(date +%s)" \
  > "$tmpdir/meta-data"

# macOS
hdiutil makehybrid -iso -joliet -default-volume-name cidata \
  -o tank-agent-os-seed.iso "$tmpdir"

# Linux
genisoimage -output tank-agent-os-seed.iso \
  -volid cidata -joliet -rock "$tmpdir"
```

Attach `tank-agent-os-seed.iso` to the VM as a CD-ROM/cloud-init seed disk.

## libvirt

With recent `virt-install`, pass the same cloud-init files:

```bash
virt-install \
  --connect qemu:///system \
  --import \
  --name tank-agent-os \
  --memory 4096 \
  --disk /path/to/tank-agent-os.qcow2 \
  --os-variant fedora-unknown \
  --cloud-init user-data=examples/cloud-init/clawx-user-data.yaml,meta-data=examples/cloud-init/meta-data
```

If your `virt-install` does not support `--cloud-init user-data=...`, attach a
NoCloud seed ISO instead.

## Runtime Config

Create runtime config as the `clawx` user:

```bash
sudo -iu clawx
install -d -m 0700 ~/.clawx
$EDITOR ~/.clawx/agent.env
```

Example:

```env
AGENT_PROVIDER=ollama
AGENT_BASE_URL=http://ollama.example.internal:11434/v1
AGENT_MODEL=replace-with-ollama-model
```

Restart the service after changes that affect the container:

```bash
systemctl --user restart clawx.service
```

## Podman Secrets

Create Podman secrets in the `clawx` user's rootless store:

```bash
sudo -iu clawx
printf '%s' "$AGENT_API_KEY" | podman secret create agent_api_key -
```

Then sync the generated Quadlet drop-ins:

```bash
tank-clawx-secrets
systemctl --user restart clawx.service
```

Do not create these secrets as root unless you intentionally switch to a rootful
Podman runtime.

See [model-providers.md](model-providers.md) for the provider mapping.

## Egress Proxy

For deployments that require network isolation and audit logging, provision the
instance against an egress proxy. See
[examples/cloud-init/clawx-with-proxy-user-data.yaml](../examples/cloud-init/clawx-with-proxy-user-data.yaml)
for a complete template.

Before provisioning, start the proxy on a separate host and extract its CA
certificate. The proxy must expose an HTTP CONNECT endpoint and inject its CA
cert into the agent VM so TLS interception succeeds. Once the proxy container
is running:

```bash
# Extract the CA cert for distribution to agent VMs
podman exec egress-proxy \
  cat /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem > mitmproxy-ca-cert.pem
```

Then inject the proxy URL and CA certificate into the agent VM at boot:

```bash
# Write the proxy host config for the nftables setup script (requires root).
# Without this file, clawx-nftables.service installs deny-all rules even when
# proxy secrets exist. Cloud-init writes this automatically when using the
# clawx-with-proxy-user-data.yaml template; for manual setup, write it here.
printf 'CLAWX_PROXY_URL=http://proxy.example.internal:8080\nCLAWX_PROXY_PORT=8080\n' \
  | sudo tee /etc/clawx/proxy.env

# As the clawx user on the agent VM
printf '%s' 'http://proxy.example.internal:8080' \
  | podman secret create proxy_url -
cat mitmproxy-ca-cert.pem | podman secret create proxy_ca_cert -
tank-clawx-secrets
sudo systemctl restart clawx-nftables.service
systemctl --user restart clawx.service
```

`tank-clawx-secrets` generates a Quadlet drop-in that sets `HTTP_PROXY`,
`HTTPS_PROXY`, and the CA bundle environment variables inside the `clawx`
container. `clawx-nftables.service` reads the proxy address from
`/etc/clawx/proxy.env` and installs nftables rules that restrict the agent's
outbound traffic to the proxy only. It also installs the `proxy_ca_cert`
Podman secret as a root CA into the host system trust store
(`/etc/pki/ca-trust/source/anchors/clawx-proxy-ca.pem`), so that host
processes such as Podman image pulls and `bootc upgrade` trust the MITM
certificate.

See [security.md](security.md) for the full architecture.

For a complete automated example that wires up the proxy CA certificate, static
network config, and all Podman secrets in one cloud-init run, see
`examples/cloud-init/clawx-leash-user-data.yaml`.

## Sudoers

The image ships a restricted sudoers entry for the `clawx` user that allows
`bootc` and `systemctl` without a password:

```
clawx ALL=(ALL) NOPASSWD: /usr/bin/bootc
clawx ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart clawx-nftables.service
```

Do not add a `sudo:` block or `wheel` group membership to cloud-init.
Both would override this scoped entry with unrestricted root access.
The image's `/etc/sudoers.d/clawx` is the sole authority for what `clawx` may run as root.
