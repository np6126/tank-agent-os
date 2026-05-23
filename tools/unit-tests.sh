#!/usr/bin/env bash
# tank-agent-os — VM-free unit tests for the pure logic in the boot scripts.
#
# setup-clawx-nftables, sync-podman-secrets, gen-opencode-config and
# gen-searxng-settings each carry a main-guard, so this file can `source`
# them to reach their functions without running main. Every test runs in
# its own `bash -c` for isolation — no cross-test global bleed, and the
# `set -euo pipefail` of the sourced script cannot abort the harness.
#
# Run directly (bash tools/unit-tests.sh) or via tools/static-checks.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBEXEC="$REPO_ROOT/bootc/rootfs/usr/libexec/tank-os"
NFT="$LIBEXEC/setup-clawx-nftables"
SYNC="$LIBEXEC/sync-podman-secrets"
GENSX="$LIBEXEC/gen-searxng-settings"
SETUP="$LIBEXEC/clawx-setup"
CLAWX="$REPO_ROOT/bootc/rootfs/usr/local/bin/clawx"
# gen-opencode-config is Python — its logic is tested by
# tools/test-gen-opencode-config.py, not from here.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }

eq()       { [[ "$3" == "$2" ]]   && ok "$1" || bad "$1" "$2" "$3"; }
contains() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains [$3]" "$2"; }
absent()   { [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must NOT contain [$3]" "$2"; }

# src SCRIPT CODE -> stdout of CODE, with SCRIPT sourced and main not run.
src() { bash -c "source '$1'; set +e; $2"; }

section() { printf '\n--- %s ---\n' "$1"; }

# === provider_family — sync-podman-secrets =================================
# gen-opencode-config carries the other copy of provider_family; that copy
# and the cross-script drift check are covered in Python by
# tools/test-gen-opencode-config.py (test_no_drift_vs_sync_podman_secrets).
section "provider_family (sync-podman-secrets)"
for p in ollama lmstudio openrouter openai custom-openai-compatible; do
  eq "$p -> openai" openai "$(src "$SYNC" "AGENT_PROVIDER='$p'; provider_family")"
done
for p in anthropic custom-anthropic-compatible; do
  eq "$p -> anthropic" anthropic "$(src "$SYNC" "AGENT_PROVIDER='$p'; provider_family")"
done
eq "bogus -> unknown" unknown "$(src "$SYNC" "AGENT_PROVIDER='nope'; provider_family")"
eq "empty -> unknown" unknown "$(src "$SYNC" "AGENT_PROVIDER=''; provider_family")"
eq "unset -> unknown" unknown "$(src "$SYNC" "unset AGENT_PROVIDER; provider_family")"

# === no_proxy_for ==========================================================
section "no_proxy_for (sync-podman-secrets)"
clawx_np="$(src "$SYNC" "no_proxy_for clawx")"
contains "clawx NO_PROXY has service-gator" "$clawx_np" "service-gator"
contains "clawx NO_PROXY has llm-wiki"      "$clawx_np" "llm-wiki"
contains "clawx NO_PROXY ends with loopback" "$clawx_np" "127.0.0.1,::1,localhost"
absent   "clawx NO_PROXY excludes self"     ",${clawx_np}," ",clawx,"
sg_np="$(src "$SYNC" "no_proxy_for service-gator")"
contains "service-gator NO_PROXY has clawx" ",${sg_np}," ",clawx,"
absent   "service-gator NO_PROXY excludes self" ",${sg_np}," ",service-gator,"

# === parse_proxy_host / parse_proxy_port ===================================
section "proxy-URL parsing (setup-clawx-nftables)"
eq "host: http://proxy.local:8080"     proxy.local "$(src "$NFT" "parse_proxy_host 'http://proxy.local:8080'")"
eq "host: https://10.0.0.1:3128/path"  10.0.0.1    "$(src "$NFT" "parse_proxy_host 'https://10.0.0.1:3128/path'")"
eq "host: http://host (no port)"       host        "$(src "$NFT" "parse_proxy_host 'http://host'")"
eq "host: proxy:8080 (no scheme)"      proxy       "$(src "$NFT" "parse_proxy_host 'proxy:8080'")"
eq "port: http://p:8080"               8080        "$(src "$NFT" "parse_proxy_port 'http://p:8080' ''")"
eq "port: https://p:3128/x"            3128        "$(src "$NFT" "parse_proxy_port 'https://p:3128/x' ''")"
eq "port: http://p (default 8080)"     8080        "$(src "$NFT" "parse_proxy_port 'http://p' ''")"
eq "port: explicit override wins"      3128        "$(src "$NFT" "parse_proxy_port 'http://p:9999' '3128'")"

# === generate_ruleset ======================================================
section "generate_ruleset — deny-all baseline (no proxy)"
deny="$(src "$NFT" "generate_ruleset 1000 '' '' ''")"
contains "deny-all: gates on the clawx UID" "$deny" "meta skuid != 1000 return"
contains "deny-all: final reject"           "$deny" "reject with icmp type host-prohibited"
contains "deny-all: loopback allowed"       "$deny" 'oif "lo" accept'
absent   "deny-all: no proxy_v4 set"        "$deny" "proxy_v4"
absent   "deny-all: no dport accept"        "$deny" "dport"

section "generate_ruleset — proxy configured"
v4="$(src "$NFT" "generate_ruleset 1000 8080 '203.0.113.5' ''")"
contains "v4: proxy_v4 set declared"   "$v4" "set proxy_v4"
contains "v4: proxy element present"   "$v4" "203.0.113.5"
contains "v4: dport accept rule"       "$v4" "ip daddr @proxy_v4 tcp dport 8080 accept"
contains "v4: still rejects the rest"  "$v4" "reject with icmp type host-prohibited"
absent   "v4: no proxy_v6 set"         "$v4" "proxy_v6"

v6="$(src "$NFT" "generate_ruleset 1000 3128 '' '2001:db8::1'")"
contains "v6: proxy_v6 set declared"   "$v6" "set proxy_v6"
contains "v6: dport accept rule"       "$v6" "ip6 daddr @proxy_v6 tcp dport 3128 accept"
absent   "v6: no proxy_v4 set"         "$v6" "proxy_v4"

both="$(src "$NFT" "generate_ruleset 1000 8080 '203.0.113.5' '2001:db8::1'")"
contains "v4+v6: both sets present (v4)" "$both" "set proxy_v4"
contains "v4+v6: both sets present (v6)" "$both" "set proxy_v6"

uid="$(src "$NFT" "generate_ruleset 4242 8080 '203.0.113.5' ''")"
contains "uid honored in the ruleset" "$uid" "meta skuid != 4242 return"

# === sync-podman-secrets: add_clawx_secret dedup ===========================
section "sync-podman-secrets: add_clawx_secret target dedup"
dedup="$(src "$SYNC" "secret_exists(){ return 0; }; clawx_secret_lines=(); clawx_secret_targets=' '; \
  add_clawx_secret a OPENAI_API_KEY; add_clawx_secret b OPENAI_API_KEY; \
  add_clawx_secret c ANTHROPIC_API_KEY; echo \${#clawx_secret_lines[@]}")"
eq "two adds to same target collapse to one" 2 "$dedup"
missing="$(src "$SYNC" "secret_exists(){ return 1; }; clawx_secret_lines=(); clawx_secret_targets=' '; \
  add_clawx_secret a OPENAI_API_KEY; echo \${#clawx_secret_lines[@]}")"
eq "absent secret adds nothing" 0 "$missing"

# === sync-podman-secrets: emit_proxy_env ===================================
section "sync-podman-secrets: emit_proxy_env"
pe="$(src "$SYNC" "proxy_url=http://egress:8080; cl=(); sl=(); \
  emit_proxy_env cl sl 'a,b,localhost'; \
  printf 'C:%s\n' \"\${cl[@]}\"; printf 'S:%s\n' \"\${sl[@]}\"")"
contains "[Container] HTTP_PROXY secret"  "$pe" "C:Secret=proxy_url,type=env,target=HTTP_PROXY"
contains "[Container] HTTPS_PROXY secret" "$pe" "C:Secret=proxy_url,type=env,target=HTTPS_PROXY"
contains "[Container] NO_PROXY value"     "$pe" "C:Environment=NO_PROXY=a,b,localhost"
contains "[Service] HTTP_PROXY = url"     "$pe" "S:Environment=HTTP_PROXY=http://egress:8080"
contains "[Service] HTTPS_PROXY = url"    "$pe" "S:Environment=HTTPS_PROXY=http://egress:8080"
contains "[Service] NO_PROXY value"      "$pe" "S:Environment=NO_PROXY=a,b,localhost"

# === gen-searxng-settings: render_settings =================================
section "gen-searxng-settings: render_settings"
printf 'outgoing:\n  proxies:\n    all://:\n      - __CLAWX_PROXY_URL__\n' > "$TMP/sx.tmpl"
sx_p="$(src "$GENSX" "render_settings '$TMP/sx.tmpl' 'http://egress:8080'")"
contains "proxy URL substituted" "$sx_p" "http://egress:8080"
absent   "placeholder gone after substitution" "$sx_p" "__CLAWX_PROXY_URL__"
sx_n="$(src "$GENSX" "render_settings '$TMP/sx.tmpl' ''")"
contains "no proxy: placeholder left intact" "$sx_n" "__CLAWX_PROXY_URL__"

# === clawx-setup: argument handling + secret-name recognition ==============
# The --help and too-many-args paths exit before any podman/systemctl call,
# so they are safe to run as a real subprocess. is_known_secret is pure and
# is exercised by sourcing. The full apply path (podman secret create,
# tank-clawx-secrets, service restarts) is stubbed out so it runs VM-free.
section "clawx-setup: --help / -h"
for flag in --help -h; do
  out="$(bash "$SETUP" "$flag" </dev/null 2>&1)"; rc=$?
  eq       "clawx-setup $flag exits 0" 0 "$rc"
  contains "clawx-setup $flag prints the usage block" "$out" "Usage:"
done

section "clawx-setup: argument validation"
err="$(bash "$SETUP" one two </dev/null 2>&1 >/dev/null)"; rc=$?
eq       "two positional args exit 2" 2 "$rc"
contains "two positional args: 'too many arguments' on stderr" "$err" "too many arguments"
bash "$SETUP" a b c </dev/null >/dev/null 2>&1; rc3=$?
eq       "three positional args exit 2" 2 "$rc3"

section "clawx-setup: is_known_secret"
for s in agent_api_key openai_api_key proxy_url gh_token registry_password; do
  eq "is_known_secret '$s' -> recognised" yes \
     "$(src "$SETUP" "is_known_secret '$s' && echo yes || echo no")"
done
eq "is_known_secret 'some_typo' -> not recognised" no \
   "$(src "$SETUP" "is_known_secret some_typo && echo yes || echo no")"
eq "is_known_secret '' -> not recognised" no \
   "$(src "$SETUP" "is_known_secret '' && echo yes || echo no")"

# Apply path with podman / tank-clawx-secrets / systemctl stubbed out.
setup_stub() {  # $1 = secret name -> runs main, echoes "<rc>|<stdout>|<stderr>"
  local out err rc
  out="$(printf 'val' | bash -c "source '$SETUP'
    podman()            { return 0; }
    tank-clawx-secrets() { return 0; }
    systemctl()         { return 1; }
    main '$1'" 2>"$TMP/stub.err")"
  rc=$?
  err="$(cat "$TMP/stub.err")"
  printf '%s|%s|%s' "$rc" "$out" "$err"
}

section "clawx-setup: unknown secret name warns but does not abort"
res="$(setup_stub some_typo)"
contains "unknown secret: warning on stderr"   "${res#*|*|}" "not a recognised secret name"
contains "unknown secret: flow runs to completion" "${res#*|}" "clawx setup: done."
eq       "unknown secret: exit 0 (not aborted)" 0 "${res%%|*}"

section "clawx-setup: known secret name is accepted silently"
res="$(setup_stub agent_api_key)"
absent   "known secret: no 'not recognised' warning" "${res#*|*|}" "not a recognised secret name"
contains "known secret: stored + applied"            "${res#*|}" "stored secret: agent_api_key"

section "clawx-setup: KNOWN_SECRETS list is complete"
# Every documented operator secret must stay in the list — guards against a
# name silently dropping out of KNOWN_SECRETS.
for s in agent_api_key openai_api_key anthropic_api_key claude_code_oauth_token \
         openrouter_api_key model_endpoint_api_key gh_token gitlab_token \
         forgejo_token jira_api_token proxy_url proxy_ca_cert llm_wiki_token \
         registry_user registry_password; do
  eq "KNOWN_SECRETS contains '$s'" yes \
     "$(src "$SETUP" "is_known_secret '$s' && echo yes || echo no")"
done

# === clawx wrapper: build_cli_args + require_supported_provider ============
# The clawx wrapper carries a main-guard, so sourcing it defines the pure
# argv-shaping helpers without running main. build_cli_args sets the global
# array `cli_args`; each test joins it with spaces and asserts the exact
# argv, so a dropped or weakened guardrail flag (--strict-mcp-config,
# --setting-sources user, --mcp-config) fails the test loudly.
section "clawx: build_cli_args — argv shaping"
eq "claw: bare prompt, model verbatim (no local/ strip)" \
   "--model local/m hello" \
   "$(src "$CLAWX" 'build_cli_args claw local/m hello; echo "${cli_args[*]}"')"
eq "claw: no args" \
   "--model local/m" \
   "$(src "$CLAWX" 'build_cli_args claw local/m; echo "${cli_args[*]}"')"

eq "opencode: bare prompt -> run, local/ stripped to agent/" \
   "run --model agent/m hello" \
   "$(src "$CLAWX" 'build_cli_args opencode local/m hello; echo "${cli_args[*]}"')"
eq "opencode: no args -> TUI" \
   "--model agent/m" \
   "$(src "$CLAWX" 'build_cli_args opencode local/m; echo "${cli_args[*]}"')"
eq "opencode: subcommand passes through verbatim" \
   "mcp list" \
   "$(src "$CLAWX" 'build_cli_args opencode local/m mcp list; echo "${cli_args[*]}"')"

eq "claude: bare prompt -> headless, all guardrails present" \
   "-p --model m --mcp-config /etc/clawx/claude-mcp.json --strict-mcp-config --setting-sources user --permission-mode bypassPermissions hello" \
   "$(src "$CLAWX" 'build_cli_args claude local/m hello; echo "${cli_args[*]}"')"
eq "claude: no args -> TUI, MCP + settings-source lockdown present" \
   "--model m --mcp-config /etc/clawx/claude-mcp.json --strict-mcp-config --setting-sources user" \
   "$(src "$CLAWX" 'build_cli_args claude local/m; echo "${cli_args[*]}"')"
eq "claude: explicit -p -> headless with guardrails" \
   "-p --model m --mcp-config /etc/clawx/claude-mcp.json --strict-mcp-config --setting-sources user --permission-mode bypassPermissions q" \
   "$(src "$CLAWX" 'build_cli_args claude local/m -p q; echo "${cli_args[*]}"')"
eq "claude: subcommand passes through, no injected flags" \
   "mcp list" \
   "$(src "$CLAWX" 'build_cli_args claude local/m mcp list; echo "${cli_args[*]}"')"

# Guardrail-specific assertions — spelled out so a regression names the flag.
cl="$(src "$CLAWX" 'build_cli_args claude local/m hello; echo "${cli_args[*]}"')"
contains "claude headless: --strict-mcp-config present"    "$cl" "--strict-mcp-config"
contains "claude headless: --setting-sources user present" "$cl" "--setting-sources user"
contains "claude headless: --mcp-config present"           "$cl" "--mcp-config /etc/clawx/claude-mcp.json"

eq "build_cli_args: unknown agent kind -> exit 2" 2 \
   "$(src "$CLAWX" 'build_cli_args bogus m hi >/dev/null 2>&1; echo $?')"

section "clawx: require_supported_provider"
for p in anthropic custom-anthropic-compatible; do
  eq "claude + $p -> accepted (rc 0)" 0 \
     "$(src "$CLAWX" "require_supported_provider claude $p; echo \$?")"
done
for p in openai ollama lmstudio openrouter custom-openai-compatible; do
  eq "claude + $p -> rejected (rc 2)" 2 \
     "$(src "$CLAWX" "require_supported_provider claude $p >/dev/null 2>&1; echo \$?")"
done
eq "claw + openai -> accepted (guard is claude-only)" 0 \
   "$(src "$CLAWX" 'require_supported_provider claw openai; echo $?')"
eq "opencode + ollama -> accepted (guard is claude-only)" 0 \
   "$(src "$CLAWX" 'require_supported_provider opencode ollama; echo $?')"

# === clawx wrapper: anthropic_base_url_for =================================
# A claude image on a custom-anthropic-compatible backend is routed through
# the in-container anthropic-strip-proxy (claude appends ?beta=true, which
# hangs an Ollama backend — claude-code #51239). The real Anthropic API and
# claw/opencode reach the backend directly. The helper pins that decision.
section "clawx: anthropic_base_url_for"
eq "claude + custom-anthropic-compatible -> strip-proxy URL" \
   "http://127.0.0.1:8765" \
   "$(src "$CLAWX" 'anthropic_base_url_for claude custom-anthropic-compatible http://ollama:11434')"
eq "claude + anthropic -> real Anthropic API direct" \
   "https://api.anthropic.com" \
   "$(src "$CLAWX" 'anthropic_base_url_for claude anthropic https://api.anthropic.com')"
eq "claw -> backend URL verbatim" \
   "http://ollama:11434" \
   "$(src "$CLAWX" 'anthropic_base_url_for claw custom-anthropic-compatible http://ollama:11434')"
eq "opencode -> backend URL verbatim" \
   "https://api.anthropic.com" \
   "$(src "$CLAWX" 'anthropic_base_url_for opencode anthropic https://api.anthropic.com')"

# === summary ===============================================================
printf '\n=== unit tests: %d passed, %d failed ===\n' "$pass" "$fail"
(( fail == 0 ))
