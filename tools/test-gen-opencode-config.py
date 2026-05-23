#!/usr/bin/python3
"""VM-free unit tests for gen-opencode-config (the opencode config generator).

Loads the hyphen-named script as a module via importlib and exercises its
pure helpers. The drift test additionally sources sync-podman-secrets' bash
provider_family and asserts the two implementations never disagree.

Run directly (python3 tools/test-gen-opencode-config.py) or via
tools/static-checks.sh.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

# Don't drop a __pycache__ next to the imported generator — it lives in the
# image rootfs tree and must stay clean.
sys.dont_write_bytecode = True

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "bootc/rootfs/usr/libexec/tank-os/gen-opencode-config")
SYNC = os.path.join(REPO, "bootc/rootfs/usr/libexec/tank-os/sync-podman-secrets")
CLAW_SETTINGS = os.path.join(REPO, "bootc/rootfs/etc/clawx/claw-settings.json")
CLAUDE_MCP = os.path.join(REPO, "bootc/rootfs/etc/clawx/claude-mcp.json")
CLAWX_WRAPPER = os.path.join(REPO, "bootc/rootfs/usr/local/bin/clawx")

ALL_PROVIDERS = ("ollama", "lmstudio", "openrouter", "openai",
                 "custom-openai-compatible", "anthropic",
                 "custom-anthropic-compatible", "nope", "")


def _load(path):
    """Import the hyphen-named, extensionless script as a module. A
    SourceFileLoader is required because importlib cannot infer a loader for
    a file without a .py suffix. The module name is not __main__, so the
    script's main-guard does not run on import."""
    loader = importlib.machinery.SourceFileLoader("gen_opencode_config", path)
    spec = importlib.util.spec_from_loader("gen_opencode_config", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


gen = _load(SCRIPT)


class ProviderFamily(unittest.TestCase):
    def test_openai_family(self):
        for p in ("ollama", "lmstudio", "openrouter", "openai",
                  "custom-openai-compatible"):
            self.assertEqual(gen.provider_family(p), "openai", p)

    def test_anthropic_family(self):
        for p in ("anthropic", "custom-anthropic-compatible"):
            self.assertEqual(gen.provider_family(p), "anthropic", p)

    def test_unknown_family(self):
        for p in ("", "nope", "OLLAMA", "claude"):
            self.assertEqual(gen.provider_family(p), "unknown", p)

    def test_no_drift_vs_sync_podman_secrets(self):
        """provider_family is duplicated in sync-podman-secrets (bash). The
        two copies must agree for every provider value — guards the drift."""
        for p in ALL_PROVIDERS:
            bash = subprocess.run(
                ["bash", "-c",
                 f"source '{SYNC}'; AGENT_PROVIDER='{p}'; provider_family"],
                capture_output=True, text=True).stdout
            self.assertEqual(bash, gen.provider_family(p),
                             f"provider_family drift for '{p}'")

    def test_no_drift_vs_clawx_wrapper(self):
        """The clawx wrapper carries a third provider list — the
        `case "$AGENT_PROVIDER"` that picks the provider env vars. Its two
        arms must partition exactly as provider_family does."""
        with open(CLAWX_WRAPPER, encoding="utf-8") as fh:
            text = fh.read()
        m = re.search(r'case "\$AGENT_PROVIDER" in\n(.*?)\n\s*esac',
                      text, re.DOTALL)
        self.assertIsNotNone(m, "AGENT_PROVIDER case not found in clawx")
        # Case-arm headers: `<tok>|<tok>...)`. The *) default is skipped
        # (its first char is not a lowercase letter).
        arms = re.findall(r'^\s*([a-z][\w|-]*)\)', m.group(1), re.MULTILINE)
        self.assertEqual(len(arms), 2, f"expected 2 provider arms, got {arms}")
        openai_arm = set(arms[0].split("|"))
        anthropic_arm = set(arms[1].split("|"))
        for p in openai_arm:
            self.assertEqual(gen.provider_family(p), "openai", p)
        for p in anthropic_arm:
            self.assertEqual(gen.provider_family(p), "anthropic", p)
        known = {p for p in ALL_PROVIDERS if gen.provider_family(p) != "unknown"}
        self.assertEqual(openai_arm | anthropic_arm, known,
                         "clawx wrapper provider list drifted from provider_family")

    def test_no_drift_vs_require_supported_provider(self):
        """clawx's require_supported_provider carries a fourth provider list —
        the anthropic family that AGENT_KIND=claude accepts. Its accept-arm
        must equal the anthropic side of provider_family."""
        with open(CLAWX_WRAPPER, encoding="utf-8") as fh:
            text = fh.read()
        m = re.search(
            r'require_supported_provider\(\).*?case "\$provider" in\n'
            r'\s*([a-z][\w|-]*)\)',
            text, re.DOTALL)
        self.assertIsNotNone(
            m, "require_supported_provider accept-arm not found in clawx")
        accepted = set(m.group(1).split("|"))
        anthropic = {p for p in ALL_PROVIDERS
                     if gen.provider_family(p) == "anthropic"}
        self.assertEqual(
            accepted, anthropic,
            "require_supported_provider drifted from provider_family")


class BuildConfig(unittest.TestCase):
    def test_strips_local_model_prefix(self):
        cfg = gen.build_config("ollama", "http://ollama:11434/v1", "local/qwen3")
        models = cfg["provider"]["agent"]["models"]
        self.assertIn("qwen3", models)
        self.assertNotIn("local/qwen3", models)

    def test_keeps_unprefixed_model(self):
        cfg = gen.build_config("openai", "http://x/v1", "gpt-4o")
        self.assertIn("gpt-4o", cfg["provider"]["agent"]["models"])

    def test_carries_base_url(self):
        cfg = gen.build_config("ollama", "http://ollama:11434/v1", "m")
        self.assertEqual(cfg["provider"]["agent"]["options"]["baseURL"],
                         "http://ollama:11434/v1")

    def test_quote_in_base_url_stays_valid_json(self):
        # The hand-rolled escaping bug class the shell version was prone to:
        # a double quote in the base URL must not break the JSON.
        cfg = gen.build_config("ollama", 'http://host/v1"evil', "m")
        json.loads(gen.render(cfg))  # raises if invalid

    def test_anthropic_gets_minimal_config(self):
        cfg = gen.build_config("anthropic", "http://x", "claude")
        self.assertNotIn("provider", cfg)
        self.assertIn("service-gator", cfg["mcp"])

    def test_no_agent_env_gets_minimal_config(self):
        cfg = gen.build_config("", "", "")
        self.assertNotIn("provider", cfg)
        self.assertIn("service-gator", cfg["mcp"])

    def test_openai_without_base_url_gets_minimal_config(self):
        cfg = gen.build_config("ollama", "", "m")
        self.assertNotIn("provider", cfg)

    def test_render_is_always_valid_json(self):
        for cfg in (gen.build_config("ollama", "http://x/v1", "local/m"),
                    gen.build_config("", "", "")):
            parsed = json.loads(gen.render(cfg))
            self.assertEqual(parsed["$schema"], "https://opencode.ai/config.json")
            self.assertFalse(parsed["autoupdate"])

    def test_render_has_trailing_newline(self):
        self.assertTrue(gen.render(gen.build_config("", "", "")).endswith("}\n"))


class ReadAgentEnv(unittest.TestCase):
    def test_missing_file_yields_empties(self):
        self.assertEqual(gen.read_agent_env("/no/such/agent.env"), ("", "", ""))

    def test_sources_a_shell_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write('AGENT_PROVIDER=ollama\n')
            f.write('AGENT_BASE_URL="http://ollama:11434/v1"\n')
            f.write("AGENT_MODEL='local/qwen3'\n")
            path = f.name
        try:
            self.assertEqual(
                gen.read_agent_env(path),
                ("ollama", "http://ollama:11434/v1", "local/qwen3"))
        finally:
            os.unlink(path)

    def test_partial_file_yields_empties_for_unset(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("AGENT_PROVIDER=openai\n")
            path = f.name
        try:
            self.assertEqual(gen.read_agent_env(path), ("openai", "", ""))
        finally:
            os.unlink(path)


class McpTopology(unittest.TestCase):
    """The MCP endpoint set is spelled out three times — gen-opencode-config's
    MCP dict (opencode), claw-settings.json (claw-code), and claude-mcp.json
    (claude). All three must list the same servers at the same URLs."""

    def test_all_agents_mcp_urls_agree(self):
        opencode = {name: spec["url"] for name, spec in gen.MCP.items()}
        with open(CLAW_SETTINGS, encoding="utf-8") as f:
            claw_raw = json.load(f)["mcpServers"]
        # claw-code reaches each HTTP MCP through mcp-proxy; the endpoint URL
        # is the last positional arg of the mcp-proxy invocation.
        claw = {name: spec["args"][-1] for name, spec in claw_raw.items()}
        with open(CLAUDE_MCP, encoding="utf-8") as f:
            claude = {name: spec["url"]
                      for name, spec in json.load(f)["mcpServers"].items()}
        self.assertEqual(opencode, claw, "opencode vs claw MCP topology")
        self.assertEqual(opencode, claude, "opencode vs claude MCP topology")


if __name__ == "__main__":
    unittest.main()
