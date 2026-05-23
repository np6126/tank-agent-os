#!/usr/bin/python3
"""Structure checks for the static claude-agent config files.

`claude-mcp.json` and `claude-managed-settings.json` are hand-written,
root-owned files shipped in the bootc image. static-checks.sh already
verifies they are valid JSON; these tests additionally pin their *structure*
so an edit cannot silently drop a guardrail — a telemetry kill-switch, the
bypassPermissions default mode, or an MCP server's native http transport.

Run directly (python3 tools/test-claude-config.py) or via
tools/static-checks.sh.
"""
import json
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ETC_CLAWX = os.path.join(REPO_ROOT, "bootc", "rootfs", "etc", "clawx")
MCP_CONFIG = os.path.join(ETC_CLAWX, "claude-mcp.json")
MANAGED_SETTINGS = os.path.join(ETC_CLAWX, "claude-managed-settings.json")

# The kill-switches that must stay enabled — kept in sync with the
# Environment= block of clawx.container (the two layers are belt-and-braces).
TELEMETRY_KILL_SWITCHES = (
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "DISABLE_AUTOUPDATER",
    "DISABLE_UPDATES",
    "DISABLE_TELEMETRY",
    "DISABLE_ERROR_REPORTING",
    "DISABLE_FEEDBACK_COMMAND",
    "DO_NOT_TRACK",
)

# The baked MCP set — must match the wrapper's --mcp-config target and the
# bridge endpoints the docs describe.
EXPECTED_MCP_SERVERS = ("docs-mcp", "llm-wiki", "searxng", "service-gator")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


class ClaudeMcpConfig(unittest.TestCase):
    """bootc/rootfs/etc/clawx/claude-mcp.json"""

    def setUp(self):
        self.cfg = load(MCP_CONFIG)

    def test_has_mcp_servers_block(self):
        self.assertIn("mcpServers", self.cfg)

    def test_exact_server_set(self):
        self.assertEqual(
            sorted(self.cfg["mcpServers"]), sorted(EXPECTED_MCP_SERVERS)
        )

    def test_every_server_is_native_http(self):
        # claude speaks streamable-HTTP MCP natively — no stdio / mcp-proxy.
        for name, server in self.cfg["mcpServers"].items():
            self.assertEqual(
                server.get("type"), "http", f"{name}: must use the http transport"
            )
            url = server.get("url", "")
            self.assertTrue(
                url.startswith("http://"), f"{name}: must have an http:// url"
            )

    def test_no_stdio_or_command_servers(self):
        # A stdio/command entry would spawn a local process — not how the
        # claude image reaches the bridge MCP servers.
        for name, server in self.cfg["mcpServers"].items():
            self.assertNotIn("command", server, f"{name}: must not spawn a command")


class ClaudeManagedSettings(unittest.TestCase):
    """bootc/rootfs/etc/clawx/claude-managed-settings.json"""

    def setUp(self):
        self.cfg = load(MANAGED_SETTINGS)

    def test_telemetry_kill_switches_all_set(self):
        env = self.cfg.get("env", {})
        for key in TELEMETRY_KILL_SWITCHES:
            self.assertEqual(
                env.get(key), "1", f'{key}: must be set to "1" in the env block'
            )

    def test_default_mode_is_bypass_permissions(self):
        self.assertEqual(
            self.cfg.get("permissions", {}).get("defaultMode"),
            "bypassPermissions",
        )

    def test_no_weakening_permission_rules(self):
        # The container sandbox is the boundary; the managed settings must not
        # carry an allow/ask rule set that implies an in-agent policy layer.
        perms = self.cfg.get("permissions", {})
        self.assertEqual(
            set(perms) - {"defaultMode"},
            set(),
            "permissions must carry only defaultMode",
        )


if __name__ == "__main__":
    unittest.main()
