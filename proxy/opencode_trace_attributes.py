# Names OpenCode traces in Langfuse and groups them by session.
#
# OpenCode sends a traceparent whose parent span is never exported, so LiteLLM's proxy span
# is not a root and Langfuse leaves the trace name empty. Langfuse reads the name and session
# from these span attributes on any span; agent.name fills the agent_name label in Grafana.
# Requests from other clients have no x-opencode-session header and are left unchanged.
from litellm.integrations.custom_logger import CustomLogger


class OpenCodeTraceAttributes(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        span = user_api_key_dict.parent_otel_span
        headers = (data.get("proxy_server_request") or {}).get("headers") or {}
        session_id = headers.get("x-opencode-session")
        if span is not None and session_id:
            span.set_attribute("langfuse.trace.name", "opencode")
            span.set_attribute("agent.name", "opencode")
            span.set_attribute("session.id", session_id)
        return data


handler = OpenCodeTraceAttributes()
