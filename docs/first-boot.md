# First Boot

Steps to go from a freshly provisioned tank-claw-os VM to a working agent
session. Complete them in order.

## 1. Verify The VM

SSH in as `clawx` and confirm the core services are up:

```bash
systemctl --user status clawx.service
systemctl --user status service-gator.service
podman ps
```

Both containers should be running. If they are not:

```bash
systemctl --user start clawx.service service-gator.service
podman logs clawx
podman logs service-gator
```

## 2. Configure The Model Provider

Create `~/.clawx/agent.env` with the provider settings for this instance.
A template is at `/usr/share/tank-os/agent-config.env.example`.

```bash
install -d -m 0700 ~/.clawx
printf '%s\n' \
  'AGENT_PROVIDER=ollama' \
  'AGENT_BASE_URL=http://ollama.example.internal:11434/v1' \
  'AGENT_MODEL=replace-with-model-name' \
  > ~/.clawx/agent.env
```

See [model-providers.md](model-providers.md) for all supported providers and
the matching secret names.

## 3. Create The API Key Secret

```bash
printf '%s' "$AGENT_API_KEY" | podman secret create agent_api_key -
```

## 4. Wire The Secrets Into The Container

```bash
tank-clawx-secrets
systemctl --user restart clawx.service
```

`tank-clawx-secrets` writes a Quadlet drop-in under
`~/.config/containers/systemd/clawx.container.d/` that mounts the secrets and
sets the provider-specific environment variables. It must be re-run whenever
secrets are added or removed.

## 5. Verify The Agent Responds

```bash
clawx --version
clawx prompt "say hello"
```

If the version prints but the prompt call fails, the model provider is not
reachable. Check `AGENT_BASE_URL` and confirm the provider is accessible from
the VM.

## 6. Configure service-gator (Optional)

service-gator gives the agent scoped access to external services such as
GitHub, GitLab, Forgejo, and JIRA. Skip this step if the agent does not need
those tools.

Create the credentials as Podman secrets:

```bash
printf '%s' "$GH_TOKEN" | podman secret create gh_token -
```

Supported secret names: `gh_token`, `gitlab_token`, `forgejo_token`,
`jira_api_token`.

Run `tank-clawx-secrets` again after creating any service-gator secret, then
restart the service:

```bash
tank-clawx-secrets
systemctl --user restart service-gator.service
```

Configure the scope file to define exactly which repositories and projects the
agent is allowed to interact with. A template with all supported fields is at
`/usr/share/tank-os/scopes.json.example`:

```bash
mkdir -p ~/.config/service-gator
cp /usr/share/tank-os/scopes.json.example ~/.config/service-gator/scopes.json
$EDITOR ~/.config/service-gator/scopes.json
```

service-gator rejects any repository not listed in this file, regardless of
which tokens are configured. See [service-gator.md](service-gator.md) for the
permission reference.

### Pointing claw-code at service-gator

service-gator listens on the `clawx-isolated` bridge network. Inside the
`clawx` container, it is reachable by container name:

```
http://service-gator:8080
```

Configure this address as the MCP server URL in claw-code's configuration.
The exact config format depends on the claw-code version in use; check the
upstream documentation for the MCP server field name.

## 7. Configure The Egress Proxy (Optional)

> **Skip this step** if the instance was provisioned with a cloud-init template
> that includes proxy configuration (`clawx-with-proxy-user-data.yaml`,
> `clawx-leash-user-data.yaml`). Those templates write `/etc/clawx/proxy.env`
> and create the required Podman secrets automatically — the proxy is already
> active.

Only continue here if you are setting up a local dev VM without cloud-init and
want to add proxy support manually. Note that the security model intentionally
limits `clawx` sudo to two specific commands (`bootc` and
`systemctl restart clawx-nftables.service`); writing `/etc/clawx/proxy.env`
falls outside that scope and requires either `wheel` group membership (present
on dev builds, see [build.md](build.md)) or a separate root session.

```bash
# Write the proxy host config for the nftables setup script (requires root).
# Without this file, clawx-nftables.service installs deny-all rules even when
# a proxy_url secret exists.
printf 'CLAWX_PROXY_URL=http://proxy.example.internal:8080\nCLAWX_PROXY_PORT=8080\n' \
  | sudo tee /etc/clawx/proxy.env

printf '%s' 'http://proxy.example.internal:8080' \
  | podman secret create proxy_url -
cat /path/to/mitmproxy-ca-cert.pem | podman secret create proxy_ca_cert -
tank-clawx-secrets
sudo systemctl restart clawx-nftables.service
systemctl --user restart clawx.service
```

After this step, direct outbound connections from the agent container are
blocked. All external traffic must flow through the proxy.

Restarting `clawx-nftables.service` also installs the proxy CA certificate
into the host system trust store
(`/etc/pki/ca-trust/source/anchors/clawx-proxy-ca.pem`). This ensures
host-level processes — Podman image pulls and `sudo bootc upgrade` — trust
the MITM certificate without any extra steps.

## Reference

| What changed | What to run |
|---|---|
| Added or removed a secret | `tank-clawx-secrets` then restart the affected service |
| Edited `~/.clawx/agent.env` | `systemctl --user restart clawx.service` |
| Edited `~/.config/service-gator/scopes.json` | `systemctl --user restart service-gator.service` |
| Edited `/etc/clawx/proxy.env` | `sudo systemctl restart clawx-nftables.service` |
| OS update available | `sudo bootc upgrade --apply` |
