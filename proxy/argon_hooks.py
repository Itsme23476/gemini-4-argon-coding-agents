"""LiteLLM proxy hook for the Gemini 4 Argon setup.

Strips Anthropic `cache_control` markers from every request. Claude Code and the Claude
desktop app attach them to system prompts and messages; LiteLLM turns them into a Gemini
explicit-cache call (:cachedContents) which Argon does not support, and the request 404s.
Vertex implicit caching still applies server-side, so nothing is lost.
Loaded via `litellm_settings.callbacks: argon_hooks.proxy_handler_instance` (PYTHONPATH must
include this directory; start-argon.sh does that).
"""
from litellm.integrations.custom_logger import CustomLogger


def _strip(obj):
    if isinstance(obj, dict):
        obj.pop("cache_control", None)
        for v in obj.values():
            _strip(v)
    elif isinstance(obj, list):
        for v in obj:
            _strip(v)


class ArgonHooks(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        for key in ("messages", "system", "tools"):
            if key in data:
                _strip(data[key])
        return data


proxy_handler_instance = ArgonHooks()


# --- count_tokens URL fix -----------------------------------------------------------------
# LiteLLM's Gemini token counter builds "{api_base}/v1beta/models/{model}:countTokens", which is
# right for AI Studio but wrong for the Vertex publisher path we use as api_base. Vertex wants
# "{api_base}/models/{model}:countTokens". Patch the URL builder for that case only.
try:
    from litellm.llms.gemini.count_tokens import handler as _ct_handler

    for _name in dir(_ct_handler):
        _cls = getattr(_ct_handler, _name)
        if isinstance(_cls, type) and hasattr(_cls, "_construct_url"):
            _orig = _cls._construct_url

            def _construct_url(self, model, api_base=None, _orig=_orig):
                if api_base and "aiplatform.googleapis.com" in api_base:
                    return f"{api_base.rstrip('/')}/models/{model}:countTokens"
                return _orig(self, model=model, api_base=api_base)

            _cls._construct_url = _construct_url
except Exception as _e:  # never block the proxy because of the patch
    print(f"[argon_hooks] count_tokens patch not applied: {_e}")


# --- count_tokens contents fix -------------------------------------------------------------
# The Gemini provider counter ignores `messages` and posts an empty `contents`, so Vertex answers
# totalTokens 0 and Claude Code would believe its context is empty. Build a text-only contents
# payload from system + messages + tools instead; on any failure return None so the proxy falls
# back to LiteLLM's local tokenizer estimate.
try:
    import json as _json
    from litellm.llms.gemini import common_utils as _cu

    def _texts(obj):
        if isinstance(obj, str):
            return [obj]
        if isinstance(obj, dict):
            out = []
            for k in ("text", "content", "input", "arguments"):
                if k in obj:
                    out += _texts(obj[k]) if not isinstance(obj[k], (dict, list)) or k != "input" else [_json.dumps(obj[k])]
            return out
        if isinstance(obj, list):
            return [t for x in obj for t in _texts(x)]
        return []

    for _name in dir(_cu):
        _cls = getattr(_cu, _name)
        if isinstance(_cls, type) and hasattr(_cls, "count_tokens") and hasattr(_cls, "should_use_token_counting_api"):
            _orig_count = _cls.count_tokens

            async def count_tokens(self, model_to_use, messages, contents, deployment=None, request_model="",
                                   tools=None, system=None, _orig=_orig_count):
                try:
                    if not contents:
                        parts = _texts(system) + _texts(messages) + ([_json.dumps(tools)] if tools else [])
                        text = "\n".join(p for p in parts if p)
                        if not text:
                            return None
                        contents = [{"role": "user", "parts": [{"text": text}]}]
                    return await _orig(self, model_to_use=model_to_use, messages=messages, contents=contents,
                                       deployment=deployment, request_model=request_model, tools=tools, system=system)
                except Exception as e:
                    print(f"[argon_hooks] provider count_tokens failed, using local estimate: {e}")
                    return None

            _cls.count_tokens = count_tokens
except Exception as _e:
    print(f"[argon_hooks] count_tokens contents patch not applied: {_e}")
