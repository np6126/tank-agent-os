#!/usr/bin/env bash
# CI guard for the SELinux MCS invariant.
#
# Any container that bind-mounts a host path SHARED with another container
# MUST carry an identical SecurityLabelLevel in its base .container file.
# A :Z mount otherwise relabels the shared path to whichever container
# started last, stealing its MCS categories and locking the others out
# (EACCES — even for root inside the container).
#
# The project fought this repeatedly (:z -> restorecon hacks -> revert)
# before settling on the fixed-level pattern in commit c24666d, then a new
# container (searxng) was added without the pin and broke claw-code's MCP
# bridge. This check fails the build if the gap is ever reintroduced.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
quadlet_dir="$repo_root/bootc/rootfs/etc/containers/systemd/users/1000"
sync_script="$repo_root/bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets"

required_label='SecurityLabelLevel=s0:c200,c500'

# Host paths that get mounted into more than one container.
shared_paths=('%h/workspaces' '%h/.clawx/ca-bundle.crt')

declare -A reason_of   # container name -> why it needs the pin

# Source 1: shared mounts declared directly in base *.container files.
for sp in "${shared_paths[@]}"; do
  while IFS= read -r cf; do
    [[ -n "$cf" ]] && reason_of["$(basename "$cf" .container)"]="base mount of $sp"
  done < <(grep -lF "Volume=$sp" "$quadlet_dir"/*.container 2>/dev/null || true)
done

# Source 2: shared mounts injected at runtime by sync-podman-secrets, e.g.
#   searxng_extra_lines+=("Volume=%h/.clawx/ca-bundle.crt:...:ro,Z")
while IFS= read -r line; do
  prefix="$(sed -E 's/^[[:space:]]*([a-z_]+)_(extra|secret)_lines.*/\1/' <<<"$line")"
  [[ -n "$prefix" ]] && reason_of["${prefix//_/-}"]="sync-podman-secrets shared mount"
done < <(grep -E '_(extra|secret)_lines\+=\("Volume=%h/(workspaces|\.clawx/ca-bundle\.crt)' \
           "$sync_script" 2>/dev/null || true)

if (( ${#reason_of[@]} == 0 )); then
  echo "FAIL: no shared mounts detected — the paths in this script are stale."
  exit 1
fi

fail=0
for name in "${!reason_of[@]}"; do
  cf="$quadlet_dir/$name.container"
  if [[ ! -f "$cf" ]]; then
    echo "FAIL  $name — ${reason_of[$name]}, but $name.container does not exist"
    fail=1
  elif grep -Fxq "$required_label" "$cf"; then
    echo "ok    $name — carries the MCS pin (${reason_of[$name]})"
  else
    echo "FAIL  $name — ${reason_of[$name]}, but $name.container lacks '$required_label'"
    fail=1
  fi
done

if (( fail )); then
  echo
  echo "SELinux MCS guard FAILED. Every container sharing a bind-mounted host"
  echo "path must pin SecurityLabelLevel to the same value. Add"
  echo "'$required_label' to the [Container] section of each flagged file."
  exit 1
fi
echo
echo "SELinux MCS guard passed — ${#reason_of[@]} container(s) verified."
