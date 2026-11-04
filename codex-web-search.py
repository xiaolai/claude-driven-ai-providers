#!/usr/bin/env python3
"""A small stdio MCP bridge to Codex CLI's hosted web search."""

import json
import os
import re
import subprocess
import sys
import tempfile


TOOL = {
    "name": "search",
    "description": (
        "Search the web using Codex CLI's native hosted web_search. "
        "Returns source URLs and titles when available. Uses the current Codex search mode."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "A focused web search query"}
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}


def search(query):
    if not isinstance(query, str) or not query.strip() or len(query) > 2000:
        raise ValueError("query must be a nonempty string of at most 2000 characters")
    if any(ord(char) < 32 for char in query):
        raise ValueError("query may not contain control characters")

    prompt = (
        "Use your native web_search tool to search for the following query. "
        "Do not run shell commands, read local files, or use other tools. "
        "Return a concise answer with a Sources list containing the title and full HTTPS URL "
        "of each source. If web search is disabled or unavailable, say so.\n\n"
        f"Query: {query}"
    )
    env = os.environ.copy()
    for name in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"):
        env.pop(name, None)
    with tempfile.TemporaryDirectory(prefix="clcd-web-search-") as directory:
        command = [
            "codex", "exec", "--json", "--ephemeral", "--sandbox", "read-only",
            "--skip-git-repo-check", "-c", 'approval_policy="never"',
            "-C", directory, prompt,
        ]
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, encoding="utf-8",
                errors="replace", stdin=subprocess.DEVNULL, timeout=120, env=env,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("Codex web search timed out after 120 seconds") from exc
        except OSError as exc:
            raise RuntimeError("Could not start Codex CLI") from exc

    searched = False
    completed = False
    answer = ""
    failure = ""
    event_sources = []
    for line in result.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = event.get("item") or {}
        if event.get("type") == "item.completed" and item.get("type") == "web_search":
            searched = True
            for result_item in item.get("results") or []:
                if not isinstance(result_item, dict) or result_item.get("error"):
                    continue
                url = result_item.get("url")
                if isinstance(url, str) and url.startswith("https://"):
                    title = result_item.get("title")
                    if not isinstance(title, str) or not title:
                        title = url
                    event_sources.append({"title": title, "url": url})
        if event.get("type") == "item.completed" and item.get("type") == "agent_message":
            answer = item.get("text", "")
        if event.get("type") == "turn.failed":
            failure = (event.get("error") or {}).get("message", "")
        if event.get("type") == "turn.completed":
            completed = True
    if result.returncode != 0 or failure:
        raise RuntimeError("Codex search failed: " + (failure[:300] or "CLI exited with an error"))
    if not completed:
        raise RuntimeError("Codex search ended before the turn completed")
    if not searched:
        raise RuntimeError(
            "Codex did not use native web_search. Check whether search is disabled or unavailable."
        )
    if not answer:
        raise RuntimeError("Codex web_search completed without an answer")

    sources = []
    seen = set()
    for source in event_sources:
        if source["url"] not in seen:
            sources.append(source)
            seen.add(source["url"])
    # Older Codex JSONL events expose the search action but omit result URLs.
    # In that case use the links Codex included in its final answer.
    if not sources:
        for title, url in re.findall(r"\[([^\]]{1,200})\]\((https://[^\s)]+)\)", answer):
            if url not in seen:
                sources.append({"title": title, "url": url})
                seen.add(url)
        for url in re.findall(r"https://[^\s)\]}>]+", answer):
            url = url.rstrip(".,;:")
            if url not in seen:
                sources.append({"title": url, "url": url})
                seen.add(url)
    if not sources:
        raise RuntimeError("Codex web_search completed, but its answer contained no source URLs")
    return {"query": query, "answer": answer[:20000], "sources": sources[:20]}


def respond(request):
    method = request.get("method")
    if method == "initialize":
        version = (request.get("params") or {}).get("protocolVersion", "2025-03-26")
        result = {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "clcd-codex-web-search", "version": "1.0.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [TOOL]}
    elif method == "tools/call":
        params = request.get("params") or {}
        if params.get("name") != TOOL["name"]:
            return {"error": {"code": -32601, "message": "Unknown tool"}}
        try:
            value = search((params.get("arguments") or {}).get("query"))
            result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}
        except (ValueError, RuntimeError) as exc:
            result = {"content": [{"type": "text", "text": str(exc)}], "isError": True}
    else:
        return {"error": {"code": -32601, "message": "Unknown method"}}
    return {"result": result}


def main():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                continue
            if "id" not in request:
                continue
            response = {"jsonrpc": "2.0", "id": request["id"]}
            response.update(respond(request))
        except (json.JSONDecodeError, TypeError, AttributeError):
            continue
        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
