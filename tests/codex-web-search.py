#!/usr/bin/env python3
"""Exercise the MCP protocol and the Codex JSONL search gate without network."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SERVER = Path(__file__).resolve().parents[1] / "codex-web-search.py"


class SearchBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        fake = Path(self.temp.name) / "codex"
        fake.write_text(
            "#!/bin/sh\n"
            "[ -z \"${OPENAI_API_KEY+x}\" ] || exit 91\n"
            "[ -z \"${CODEX_API_KEY+x}\" ] || exit 92\n"
            "[ -z \"${CODEX_ACCESS_TOKEN+x}\" ] || exit 93\n"
            "[ -z \"${OPENAI_BASE_URL+x}\" ] || exit 102\n"
            "SEARCH_TEST_MODE=$(cat \"$CODEX_HOME/test-mode\")\n"
            "SEARCH_TEST_EXPECTED_MODE=$(cat \"$CODEX_HOME/test-expected-mode\")\n"
            "[ \"$1\" = exec ] && [ \"$2\" = --json ] && [ \"$3\" = --ephemeral ] || exit 94\n"
            "case \" $* \" in *' --ignore-user-config '*) ;; *) exit 96;; esac\n"
            "case \" $* \" in *' --sandbox read-only '*) ;; *) exit 97;; esac\n"
            "case \" $* \" in *' approval_policy=\"never\" '*) ;; *) exit 98;; esac\n"
            "for feature in shell_tool apps plugins browser_use computer_use view_image multi_agent; do\n"
            "  case \" $* \" in *\" --disable $feature \"*) ;; *) exit 100;; esac\n"
            "done\n"
            "if [ -n \"$SEARCH_TEST_EXPECTED_MODE\" ]; then\n"
            "  case \" $* \" in *' web_search=\"'\"$SEARCH_TEST_EXPECTED_MODE\"'\" '*) ;; *) exit 99;; esac\n"
            "else\n"
            "  case \" $* \" in *' web_search='*) exit 101;; esac\n"
            "fi\n"
            "if IFS= read -r _line; then exit 95; fi\n"
            "printf '%s\\n' '{\"type\":\"thread.started\"}'\n"
            "if [ \"$SEARCH_TEST_MODE\" = success ]; then\n"
            "  printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"web_search\",\"id\":\"item_1\"}}'\n"
            "fi\n"
            "if [ \"$SEARCH_TEST_MODE\" = event_sources ]; then\n"
            "  printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"web_search\",\"results\":[{\"title\":\"Result\",\"url\":\"https://example.org/result\"}]}}'\n"
            "fi\n"
            "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"See [Official docs](https://example.org/docs).\"}}'\n"
            "printf '%s\\n' '{\"type\":\"turn.completed\"}'\n"
        )
        fake.chmod(0o700)

    def request(self, mode, *messages, expected_search_mode=""):
        env = os.environ.copy()
        env["PATH"] = self.temp.name + os.pathsep + env["PATH"]
        env["CODEX_HOME"] = self.temp.name
        (Path(self.temp.name) / "test-mode").write_text(mode)
        (Path(self.temp.name) / "test-expected-mode").write_text(expected_search_mode)
        env["OPENAI_API_KEY"] = "must-not-be-used"
        env["CODEX_API_KEY"] = "must-not-be-used"
        env["CODEX_ACCESS_TOKEN"] = "must-not-be-used"
        env["OPENAI_BASE_URL"] = "https://example.invalid"
        process = subprocess.run(
            [sys.executable, str(SERVER)],
            input="\n".join(json.dumps(message) for message in messages) + "\n",
            capture_output=True, text=True, env=env, timeout=5, check=True,
        )
        self.assertEqual(process.stderr, "")
        return [json.loads(line) for line in process.stdout.splitlines()]

    def test_successful_search_has_source_and_mcp_handshake(self):
        responses = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )
        self.assertEqual([response["id"] for response in responses], [1, 2, 3])
        self.assertEqual(responses[1]["result"]["tools"][0]["name"], "search")
        value = json.loads(responses[2]["result"]["content"][0]["text"])
        self.assertEqual(value["sources"], [{"title": "Official docs", "url": "https://example.org/docs"}])

    def test_no_web_search_event_is_an_error(self):
        response = self.request(
            "disabled",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("did not use native web_search", response["result"]["content"][0]["text"])

    def test_urls_from_search_event_are_preferred(self):
        response = self.request(
            "event_sources",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        value = json.loads(response["result"]["content"][0]["text"])
        self.assertEqual(value["sources"], [{"title": "Result", "url": "https://example.org/result"}])

    def test_invalid_query_rejected(self):
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": ""}}},
        )[0]
        self.assertTrue(response["result"]["isError"])

    def test_initialize_reports_supported_protocol_version(self):
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2026-07-28"}},
        )[0]
        self.assertEqual(response["result"]["protocolVersion"], "2025-03-26")

    def test_explicit_search_mode_is_preserved_in_isolated_turn(self):
        (Path(self.temp.name) / "config.toml").write_text('web_search = "live"\n[features]\nshell_tool = true\n')
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
            expected_search_mode="live",
        )[0]
        self.assertFalse(response["result"].get("isError", False))

    def test_search_filters_fail_closed_instead_of_being_ignored(self):
        (Path(self.temp.name) / "config.toml").write_text(
            'web_search = "cached"\n[tools.web_search]\nallowed_domains = ["example.org"]\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("tool filters", response["result"]["content"][0]["text"])

    def test_disabled_search_mode_is_passed_through(self):
        (Path(self.temp.name) / "config.toml").write_text('web_search = "disabled"\n')
        response = self.request(
            "disabled",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
            expected_search_mode="disabled",
        )[0]
        self.assertTrue(response["result"]["isError"])

    def test_whitespace_variant_of_domain_filter_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            '[ tools . web_search ]\nallowed_domains = ["example.org"]\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("tool filters", response["result"]["content"][0]["text"])

    def test_dotted_domain_filter_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            'tools . web_search . allowed_domains = ["example.org"]\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("tool filters", response["result"]["content"][0]["text"])

    def test_inline_domain_filter_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            'tools.web_search = { allowed_domains = ["example.org"] }\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("tool filters", response["result"]["content"][0]["text"])

    def test_tools_section_with_dotted_filter_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            '[tools]\nweb_search.allowed_domains = ["example.org"]\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("tool filters", response["result"]["content"][0]["text"])

    def test_profile_specific_mode_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text('[profiles.work]\nweb_search = "live"\n')
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("Profile-specific", response["result"]["content"][0]["text"])

    def test_profile_specific_domain_filter_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            '[profiles.work.tools.web_search]\nallowed_domains = ["example.org"]\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("Profile-specific", response["result"]["content"][0]["text"])

    def test_selected_profile_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text('profile = "work"\n')
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("Profile-specific", response["result"]["content"][0]["text"])

    def test_profile_inline_tools_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text(
            '[profiles.work]\ntools = {web_search = {allowed_domains = ["example.org"]}}\n'
        )
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("Profile-specific", response["result"]["content"][0]["text"])

    def test_invalid_mode_fails_closed(self):
        (Path(self.temp.name) / "config.toml").write_text('web_search = true\n')
        response = self.request(
            "success",
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "Codex docs"}}},
        )[0]
        self.assertTrue(response["result"]["isError"])
        self.assertIn("Unsupported", response["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
