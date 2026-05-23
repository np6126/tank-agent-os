#!/usr/bin/python3
"""Unit tests for anthropic-strip-proxy's pure request-rewriting logic.

The proxy deletes the ?beta=true query string Claude Code appends to
/v1/messages (claude-code issue #51239) and forwards to the configured
backend. These tests pin the URL-rewriting helpers — query stripping,
upstream parsing, base-path joining — so a regression there is caught
VM-free. The networking path is exercised on the VM by the regression suite.

Run directly (python3 tools/test-strip-proxy.py) or via static-checks.sh.
"""
import importlib.util
import os
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROXY_PATH = os.path.join(
    REPO_ROOT, "bootc", "clawx-runtime", "anthropic-strip-proxy")


def load_proxy():
    """Import the extension-less proxy script as a module.

    __name__ is the loader name, not "__main__", so importing only defines
    the helpers — main() (and the server) does not run.
    """
    loader = SourceFileLoader("anthropic_strip_proxy", PROXY_PATH)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


proxy = load_proxy()


class StripQuery(unittest.TestCase):
    """strip_query — the core ?beta=true removal."""

    def test_drops_beta_true(self):
        self.assertEqual(
            proxy.strip_query("/v1/messages?beta=true"), "/v1/messages")

    def test_drops_any_query(self):
        self.assertEqual(
            proxy.strip_query("/v1/models?foo=bar&x=1"), "/v1/models")

    def test_path_only_unchanged(self):
        self.assertEqual(
            proxy.strip_query("/v1/messages"), "/v1/messages")

    def test_count_tokens_path_preserved(self):
        self.assertEqual(
            proxy.strip_query("/v1/messages/count_tokens?beta=true"),
            "/v1/messages/count_tokens")


class NormalizeUpstream(unittest.TestCase):
    def test_scheme_kept(self):
        self.assertEqual(
            proxy.normalize_upstream("http://h:11434"), "http://h:11434")

    def test_bare_host_gets_http(self):
        self.assertEqual(
            proxy.normalize_upstream("h:11434"), "http://h:11434")


class UpstreamEndpoint(unittest.TestCase):
    def test_http_with_port(self):
        self.assertEqual(
            proxy.upstream_endpoint("http://ollama:11434"),
            ("http", "ollama", 11434))

    def test_https_default_port(self):
        self.assertEqual(
            proxy.upstream_endpoint("https://gw.example"),
            ("https", "gw.example", 443))

    def test_http_default_port(self):
        self.assertEqual(
            proxy.upstream_endpoint("http://gw.example"),
            ("http", "gw.example", 80))

    def test_bare_host_defaults_to_http(self):
        self.assertEqual(
            proxy.upstream_endpoint("ollama:11434"),
            ("http", "ollama", 11434))


class ForwardPath(unittest.TestCase):
    def test_no_base_path(self):
        self.assertEqual(
            proxy.forward_path("http://ollama:11434", "/v1/messages"),
            "/v1/messages")

    def test_trailing_slash_on_upstream(self):
        self.assertEqual(
            proxy.forward_path("http://ollama:11434/", "/v1/messages"),
            "/v1/messages")

    def test_upstream_base_path_is_prefixed(self):
        self.assertEqual(
            proxy.forward_path("https://gw.example/anthropic", "/v1/messages"),
            "/anthropic/v1/messages")


class ProxyFor(unittest.TestCase):
    """proxy_for — egress must follow HTTP(S)_PROXY / NO_PROXY so the
    forwarded request stays inside the sandbox's allowlisted egress path."""

    def test_no_proxy_env_means_direct(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(proxy.proxy_for("http", "ollama.host"))

    def test_http_proxy_is_parsed(self):
        with mock.patch.dict(os.environ,
                             {"HTTP_PROXY": "http://10.10.10.1:8080"},
                             clear=True):
            self.assertEqual(proxy.proxy_for("http", "ollama.host"),
                             ("10.10.10.1", 8080))

    def test_no_proxy_bypasses_the_proxy(self):
        with mock.patch.dict(os.environ,
                             {"HTTP_PROXY": "http://10.10.10.1:8080",
                              "NO_PROXY": "ollama.host,localhost"},
                             clear=True):
            self.assertIsNone(proxy.proxy_for("http", "ollama.host"))


class OpenUpstream(unittest.TestCase):
    """open_upstream — the request target shape per routing mode."""

    def test_direct_http_uses_path(self):
        conn, target = proxy.open_upstream(
            "http", "ollama", 11434, "/v1/messages", None)
        self.assertEqual((conn.host, conn.port), ("ollama", 11434))
        self.assertEqual(target, "/v1/messages")
        conn.close()

    def test_http_via_proxy_uses_absolute_uri(self):
        conn, target = proxy.open_upstream(
            "http", "ollama", 11434, "/v1/messages", ("10.10.10.1", 8080))
        self.assertEqual((conn.host, conn.port), ("10.10.10.1", 8080))
        self.assertEqual(target, "http://ollama:11434/v1/messages")
        conn.close()

    def test_https_via_proxy_tunnels_to_backend(self):
        conn, target = proxy.open_upstream(
            "https", "gw.example", 443, "/v1/messages", ("10.10.10.1", 8080))
        self.assertEqual((conn.host, conn.port), ("10.10.10.1", 8080))
        self.assertEqual(conn._tunnel_host, "gw.example")
        self.assertEqual(target, "/v1/messages")
        conn.close()


if __name__ == "__main__":
    unittest.main()
