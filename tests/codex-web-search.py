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
            "[ \"$1\" = exec ] && [ \"$2\" = --json ] && [ \"$3\" = --ephemeral ] || exit 94\n"
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

    def request(self, mode, *messages):
        env = os.environ.copy()
        env["PATH"] = self.temp.name + os.pathsep + env["PATH"]
        env["SEARCH_TEST_MODE"] = mode
        env["OPENAI_API_KEY"] = "must-not-be-used"
        env["CODEX_API_KEY"] = "must-not-be-used"
        env["CODEX_ACCESS_TOKEN"] = "must-not-be-used"
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


if __name__ == "__main__":
    unittest.main()
