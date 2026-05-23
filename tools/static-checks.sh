#!/usr/bin/env bash
# tank-agent-os — VM-free static checks. Single entry point for the CI
# `guard` job and for local pre-commit use:
#
#   bash tools/static-checks.sh
#
# Runs and aggregates the verdict of:
#   1. local/ leak    — no public *.md names an operator-private local/ file
#   2. syntax         — bash -n for shell scripts, ast.parse for Python
#   3. shellcheck     — severity=warning; local binary or the koalaman image
#   4. JSON validity  — every tracked *.json / *.json.example
#   5. YAML validity  — cloud-init data, CI workflow, settings templates
#   6. unit lint      — Quadlet/systemd unit files have their required sections
#   7. MCS guard      — tools/check-selinux-mcs.sh
#   8. unit tests     — tools/unit-tests.sh + test-gen-opencode-config.py
#                       + test-claude-config.py + test-strip-proxy.py
#
# Exit status is non-zero if any section fails. Sections whose tool is
# missing on a minimal machine WARN and are skipped; CI runners have docker,
# so nothing is silently skipped there.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "cannot cd to repo root: $REPO_ROOT" >&2; exit 1; }

rc=0
section() { printf '\n=== %s ===\n' "$1"; }
fail()    { printf '  FAIL  %s\n' "$1"; rc=1; }
warn()    { printf '  warn  %s\n' "$1"; }
note()    { printf '  ok    %s\n' "$1"; }

# --- 1. operator-private local/ leak guard ----------------------------------
# local/ is rsync-excluded from the public OSS mirror and never goes public.
# A public *.md must therefore not name anything under it — neither a local/
# path (a dead link in the mirror that also advertises the private layout)
# nor a bare filename unique to local/ (a reference with the local/ prefix
# dropped still names a private file). This runs first: it is the cheapest
# check and a leak is a release-blocking policy break, so a bad commit fails
# the build before any other work.
section "1. operator-private local/ leak guard"
# Markdown that reaches the mirror — tracked *.md minus the directories the
# OSS rsync drops wholesale (local/ itself, plus local agent state).
md_public=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  md_public+=("$f")
done < <(git ls-files '*.md' ':!local/' ':!.claude/' ':!.codex/' ':!.agents/')

if (( ${#md_public[@]} == 0 )); then
  warn "no public markdown files to scan"
else
  # A local/<name>.<ext> path. The leading (^|[^/[:alnum:]]) rejects
  # /usr/local/...; requiring a known extension rejects the local/<model-id>
  # identifier (docs/model-providers.md: AGENT_MODEL=local/qwen3...).
  leak=$(grep -nHE \
    '(^|[^/[:alnum:]])local/[[:alnum:]_*.+-]+\.(sh|md|ya?ml|py|txt|toml|json|conf|cfg)' \
    "${md_public[@]}" 2>/dev/null || true)
  # A bare filename unique to local/. A basename also tracked outside local/
  # — e.g. README.md — is generic, so naming it is not a leak.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    base=${rel##*/}
    [[ -n "$(git ls-files -- "$base" "*/$base" ':!local/')" ]] && continue
    hit=$(grep -nHF "$base" "${md_public[@]}" 2>/dev/null || true)
    [[ -n "$hit" ]] && leak+=${leak:+$'\n'}$hit
  done < <(git ls-files -- local/)

  if [[ -n "$leak" ]]; then
    fail "public *.md names an operator-private local/ file:"
    printf '%s\n' "$leak" | sort -u | sed 's/^/        /'
  else
    note "${#md_public[@]} public markdown files — no local/ references"
  fi
fi

# Tracked boot/runtime scripts plus tooling, classified once by shebang into
# shell vs Python. gen-opencode-config is Python; the rest are shell. (The
# first line is read directly — head|grep would SIGPIPE head and trip
# pipefail when grep -q exits early.)
SHELL_SCRIPTS=()
PYTHON_SCRIPTS=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  IFS= read -r first < "$f" || true
  if [[ "$first" == *python* ]]; then
    PYTHON_SCRIPTS+=("$f")
  else
    SHELL_SCRIPTS+=("$f")
  fi
done < <(
  git ls-files \
    'tools/*.sh' 'tools/*.py' \
    'bootc/rootfs/usr/libexec/tank-os/*' \
    'bootc/rootfs/usr/local/bin/*' \
    'bootc/clawx-runtime/clawx-init' \
    'bootc/clawx-runtime/anthropic-strip-proxy' \
    'examples/proxmox/*.sh'
)

# --- 2. syntax: bash -n + Python parse --------------------------------------
section "2. syntax (bash -n + python ast.parse)"
for f in "${SHELL_SCRIPTS[@]}"; do
  err=$(bash -n "$f" 2>&1) || fail "bash syntax error in $f: $err"
done
for f in "${PYTHON_SCRIPTS[@]}"; do
  err=$(python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>&1) \
    || fail "python syntax error in $f: $err"
done
(( rc == 0 )) && note "${#SHELL_SCRIPTS[@]} shell + ${#PYTHON_SCRIPTS[@]} python scripts parse cleanly"

# --- 3. shellcheck -----------------------------------------------------------
section "3. shellcheck (severity=warning)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${SHELL_SCRIPTS[@]}"; then
    note "shellcheck clean (${#SHELL_SCRIPTS[@]} scripts, local binary)"
  else
    fail "shellcheck reported warnings/errors"
  fi
elif command -v docker >/dev/null 2>&1; then
  # Feed each script to shellcheck on stdin rather than bind-mounting the
  # repo: the CI guard job itself runs in a container, so the repo path is
  # not visible to the docker host and a -v mount fails (docker-in-docker).
  sc_bad=0
  for f in "${SHELL_SCRIPTS[@]}"; do
    if ! sc_out=$(docker run --rm -i koalaman/shellcheck:stable \
                    --severity=warning - <"$f" 2>&1); then
      printf '  shellcheck — %s\n%s\n' "$f" "$sc_out"
      sc_bad=1
    fi
  done
  if (( sc_bad )); then
    fail "shellcheck reported warnings/errors"
  else
    note "shellcheck clean (${#SHELL_SCRIPTS[@]} scripts, koalaman/shellcheck image)"
  fi
else
  warn "shellcheck skipped — no shellcheck binary and no docker available"
fi

# --- 4. JSON validity --------------------------------------------------------
section "4. JSON validity"
json_checker=""
if command -v jq >/dev/null 2>&1; then
  json_checker=jq
elif command -v python3 >/dev/null 2>&1; then
  json_checker=python
fi
json_one() {  # $1 = file -> 0 valid, 1 invalid, 2 no checker available
  case "$json_checker" in
    jq)     jq -e . "$1" >/dev/null 2>&1 ;;
    python) python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1 ;;
    *)      return 2 ;;
  esac
}
json_n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  json_one "$f"
  case $? in
    0) json_n=$((json_n + 1)) ;;
    2) warn "JSON check skipped — no jq and no python3"; break ;;
    *) fail "invalid JSON: $f" ;;
  esac
done < <(git ls-files '*.json' '*.json.example')
(( json_n > 0 )) && note "$json_n JSON files valid"

# --- 5. YAML validity --------------------------------------------------------
section "5. YAML validity"
yaml_checker=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  yaml_checker=python
elif command -v yq >/dev/null 2>&1; then
  yaml_checker=yq
elif command -v docker >/dev/null 2>&1; then
  yaml_checker=docker
fi
yaml_one() {  # $1 = file -> 0 if well-formed YAML
  case "$yaml_checker" in
    python) python3 -c 'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))' "$1" >/dev/null 2>&1 ;;
    yq)     yq e 'true' "$1" >/dev/null 2>&1 ;;
    docker) docker run --rm -i mikefarah/yq e 'true' - <"$1" >/dev/null 2>&1 ;;
    *)      return 2 ;;
  esac
}
if [[ -z "$yaml_checker" ]]; then
  warn "YAML check skipped — no python3+pyyaml, no yq, no docker"
else
  yaml_n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if yaml_one "$f"; then
      yaml_n=$((yaml_n + 1))
    else
      fail "malformed YAML: $f"
    fi
  done < <(git ls-files '*.yaml' '*.yml' '*.yml.template' 'examples/cloud-init/meta-data')
  (( yaml_n > 0 )) && note "$yaml_n YAML files well-formed ($yaml_checker)"
fi

# --- 6. Quadlet / systemd unit lint -----------------------------------------
section "6. Quadlet / systemd unit lint"
unit_n=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  unit_n=$((unit_n + 1))
  case "$f" in
    *.container)
      grep -q '^\[Container\]' "$f" || fail "$f: missing [Container] section"
      grep -q '^Image='        "$f" || fail "$f: missing Image="
      ;;
    *.network) grep -q '^\[Network\]' "$f" || fail "$f: missing [Network] section" ;;
    *.path)    grep -q '^\[Path\]'    "$f" || fail "$f: missing [Path] section" ;;
    *.service) grep -q '^\[Service\]' "$f" || fail "$f: missing [Service] section" ;;
  esac
done < <(git ls-files '*.container' '*.network' '*.path' '*.service')
note "$unit_n Quadlet/systemd unit files checked"

# --- 7. SELinux MCS shared-mount guard --------------------------------------
section "7. SELinux MCS shared-mount guard"
if bash tools/check-selinux-mcs.sh; then
  note "MCS guard passed"
else
  fail "MCS guard failed"
fi

# --- 8. unit tests -----------------------------------------------------------
section "8. unit tests"
if bash tools/unit-tests.sh; then
  note "bash unit tests passed (tools/unit-tests.sh)"
else
  fail "bash unit tests failed"
fi
if python3 tools/test-gen-opencode-config.py 2>&1; then
  note "python unit tests passed (tools/test-gen-opencode-config.py)"
else
  fail "python unit tests failed"
fi
if python3 tools/test-claude-config.py 2>&1; then
  note "python unit tests passed (tools/test-claude-config.py)"
else
  fail "python unit tests failed"
fi
if python3 tools/test-strip-proxy.py 2>&1; then
  note "python unit tests passed (tools/test-strip-proxy.py)"
else
  fail "python unit tests failed"
fi

# --- verdict -----------------------------------------------------------------
section "verdict"
if (( rc == 0 )); then
  echo "  static checks: PASS"
else
  echo "  static checks: FAIL"
fi
exit "$rc"
