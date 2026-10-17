"""End-to-end check of the LiteLLM Argon proxy, the way Claude Code and Codex use it.

Run:  uv run --python 3.12 --no-project tests/test_proxy.py
Needs only the standard library. Exits non-zero if a required check fails.

Checks: Anthropic /v1/messages (simple, tool round-trip, streaming, count_tokens > 0) and
OpenAI /v1/responses (Codex-style request fields, tool round-trip, streaming).
"""
import json, sys, urllib.request

BASE = "http://127.0.0.1:4000"
TOKEN = "local-proxy"  # the proxy runs without a master key; any bearer is accepted
MODEL = "gemini-4-argon"
FAILS = []


def call(path, body, stream=False):
    h = {"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}", "x-api-key": TOKEN,
         "anthropic-version": "2023-06-01"}
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), headers=h)
    try:
        r = urllib.request.urlopen(req, timeout=180)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:600]
    except Exception as e:  # connection refused etc.
        return 0, str(e)
    if stream:
        return r.status, r.read().decode()
    return r.status, json.loads(r.read().decode())


def check(name, ok, detail="", required=True):
    tag = "PASS " if ok else ("FAIL " if required else "WARN ")
    print(tag + name + (f"  {detail}" if detail else ""))
    if not ok and required:
        FAILS.append(name)


TOOL_A = {"name": "get_weather", "description": "Get weather for a city",
          "input_schema": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}
TOOL_O = {"type": "function", "name": "get_weather", "description": "Get weather for a city",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}

# ---------------- Anthropic Messages (Claude Code) ----------------
st, r = call("/v1/messages", {"model": MODEL, "max_tokens": 64,
                               "messages": [{"role": "user", "content": "Reply with the single word OK."}]})
check("messages: simple", st == 200 and r.get("content", [{}])[0].get("text", "").strip().startswith("OK"),
      f"status={st} usage={r.get('usage') if st == 200 else r}")

st, r = call("/v1/messages", {"model": MODEL, "max_tokens": 1024, "tools": [TOOL_A],
                               "thinking": {"type": "enabled", "budget_tokens": 1024},
                               "system": "Use tools when relevant.",
                               "messages": [{"role": "user", "content": "What is the weather in Athens? Use the tool."}]})
tu = next((c for c in (r.get("content", []) if st == 200 else []) if c.get("type") == "tool_use"), None)
check("messages: tool_use turn 1", st == 200 and tu is not None,
      f"status={st} stop={r.get('stop_reason')}" if st == 200 else f"status={st} {r}")
if tu:
    st2, r2 = call("/v1/messages", {"model": MODEL, "max_tokens": 1024, "tools": [TOOL_A],
                                     "thinking": {"type": "enabled", "budget_tokens": 1024},
                                     "system": "Use tools when relevant.",
                                     "messages": [
                                         {"role": "user", "content": "What is the weather in Athens? Use the tool."},
                                         {"role": "assistant", "content": r["content"]},
                                         {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tu["id"],
                                                                        "content": "Sunny, 24C"}]}]})
    txt = "".join(c.get("text", "") for c in r2.get("content", [])) if st2 == 200 else ""
    check("messages: tool_result turn 2", st2 == 200 and ("24" in txt or "unny" in txt),
          f"status={st2} text={txt[:80]!r}" if st2 == 200 else f"status={st2} {r2}")

st, raw = call("/v1/messages", {"model": MODEL, "max_tokens": 64, "stream": True,
                                 "messages": [{"role": "user", "content": "Reply with the single word OK."}]}, stream=True)
check("messages: streaming", st == 200 and "message_stop" in raw and "content_block_delta" in raw, f"status={st}")

st, r = call("/v1/messages/count_tokens", {"model": MODEL, "system": "You are helpful.",
                                            "messages": [{"role": "user", "content": "hello there, count these tokens"}]})
check("messages: count_tokens", st == 200 and isinstance(r.get("input_tokens"), int) and r["input_tokens"] > 0,
      f"status={st} input_tokens={r.get('input_tokens') if st == 200 else r}")

# ---------------- OpenAI Responses (Codex) ----------------
codex_fields = {"store": False, "stream": False, "include": ["reasoning.encrypted_content"],
                "reasoning": {"effort": "low"}, "text": {"verbosity": "low"},
                "parallel_tool_calls": False, "prompt_cache_key": "test-cache-key",
                "instructions": "You are a coding agent. Use tools when relevant."}
st, r = call("/v1/responses", {"model": MODEL, "input": "Reply with the single word OK.", **codex_fields})
out_text = "".join(c.get("text", "") for o in r.get("output", []) for c in o.get("content", []) if isinstance(c, dict)) if st == 200 else ""
check("responses: simple with Codex fields", st == 200 and "OK" in out_text,
      f"status={st} text={out_text[:40]!r}" if st == 200 else f"status={st} {r}")

st, r = call("/v1/responses", {"model": MODEL, "tools": [TOOL_O], **codex_fields,
                               "input": [{"role": "user", "content": "What is the weather in Athens? Use the tool."}]})
fc = next((o for o in (r.get("output", []) if st == 200 else []) if o.get("type") == "function_call"), None)
check("responses: function_call turn 1", st == 200 and fc is not None,
      f"status={st} types={[o.get('type') for o in r.get('output', [])]}" if st == 200 else f"status={st} {r}")
if fc:
    replay = [{"role": "user", "content": "What is the weather in Athens? Use the tool."}]
    replay += [o for o in r["output"] if o.get("type") in ("reasoning", "function_call", "message")]
    replay.append({"type": "function_call_output", "call_id": fc["call_id"], "output": "Sunny, 24C"})
    st2, r2 = call("/v1/responses", {"model": MODEL, "tools": [TOOL_O], **codex_fields, "input": replay})
    txt = "".join(c.get("text", "") for o in r2.get("output", []) for c in o.get("content", []) if isinstance(c, dict)) if st2 == 200 else ""
    check("responses: function_call_output turn 2", st2 == 200 and ("24" in txt or "unny" in txt),
          f"status={st2} text={txt[:80]!r}" if st2 == 200 else f"status={st2} {r2}")

st, raw = call("/v1/responses", {"model": MODEL, "input": "Reply with the single word OK.",
                                 **{**codex_fields, "stream": True}}, stream=True)
check("responses: streaming", st == 200 and "response.completed" in raw, f"status={st}")

print("\nRESULT:", "ALL REQUIRED CHECKS PASS" if not FAILS else f"FAILED: {FAILS}")
sys.exit(1 if FAILS else 0)
