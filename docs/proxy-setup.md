# Proxy setup runbook

Step-by-step guide to bring up the Caddy + LiteLLM proxy stack on a developer workstation and connect it to the existing observability stack.

## Prerequisites

- Docker Desktop running (Windows or Mac)
- Access to the `agentic-observability-platform` repo and its stack already started
- Network access to `spark-570a` on port 11434

## Step 1 — start the observability stack

The OTEL Collector must be reachable at `host.docker.internal:4317` before LiteLLM starts sending traces.

```bash
cd C:\Work\Projects\agentic-observability-platform
docker compose -f docker-compose/docker-compose.yml --env-file .env up -d
docker compose -f docker-compose/docker-compose.yml ps otel-collector
```

## Step 2 — create the proxy `.env`

```bash
cd C:\Work\Projects\agentic-coding-platform\proxy
copy .env.example .env
```

Generate a master key and paste it into `.env` as `LITELLM_MASTER_KEY`:

```bash
openssl rand -hex 32
```

Leave `OTEL_EXPORTER_OTLP_ENDPOINT` as `http://host.docker.internal:4317` for Docker Desktop. Change it to a host IP if the observability stack is on a different machine.

## Step 3 — start the proxy stack

```bash
cd C:\Work\Projects\agentic-coding-platform\proxy
docker compose up -d
docker compose ps
docker compose logs litellm --tail 20
```

LiteLLM prints `LiteLLM: Proxy initialized` when ready.

## Step 4 — trust Caddy's local CA (one-time, per machine)

Caddy generates a root CA on first start and stores it in the `caddy_data` Docker volume. Export it and add it to the Windows trusted root store.

Run in an **elevated (Administrator) PowerShell**:

```powershell
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt caddy-root.crt
certutil -addstore -f "ROOT" caddy-root.crt
```

After this, browsers, `curl` and other tools that use the Windows store trust `https://localhost` without certificate warnings.

**OpenCode does not use the Windows store.** It runs on Bun, which only trusts its bundled CA list plus `NODE_EXTRA_CA_CERTS`. Even with the root installed above, OpenCode fails with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` until `NODE_EXTRA_CA_CERTS` points at `caddy-root.crt` (no admin rights needed):

```powershell
# Persist for the user (picked up by newly started processes)
[Environment]::SetEnvironmentVariable('NODE_EXTRA_CA_CERTS', 'C:\Work\Projects\agentic-coding-platform\proxy\caddy-root.crt', 'User')
```

Check that the exported file matches the root Caddy is serving:

```powershell
echo | openssl s_client -connect localhost:443 -servername localhost -CAfile caddy-root.crt 2>&1 | Select-String 'Verify return code'
# Expected: Verify return code: 0 (ok)
```

## Step 5 — issue a virtual key per developer

Replace `<master-key>` with the value from `.env`:

```bash
curl -X POST https://localhost/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice", "max_parallel_requests": 2}'
```

The response contains a `key` field (e.g. `sk-abc123…`). This is the value each developer sets as `OPENCODE_PROXY_API_KEY`.

Repeat for each developer. Keys are stored in LiteLLM's internal database and survive container restarts.

## Step 6 — configure OpenCode and smoke test

Set the virtual key in the developer's shell (add to `$PROFILE` to persist):

```powershell
$env:OPENCODE_PROXY_API_KEY = "sk-abc123..."
$env:NODE_EXTRA_CA_CERTS = "C:\Work\Projects\agentic-coding-platform\proxy\caddy-root.crt"
```

`opencode.json` reads the key with OpenCode's substitution syntax, `"apiKey": "{env:OPENCODE_PROXY_API_KEY}"`. Shell-style `${OPENCODE_PROXY_API_KEY}` is **not** expanded. OpenCode sends it literally, and LiteLLM rejects it with `LiteLLM Virtual Key expected. Received=${OP****KEY}`.

> **OpenCode Desktop background service:** if OpenCode Desktop is installed, it keeps an `opencode-cli serve --service` process running, and `opencode run` sends its work to that service instead of running in your shell. The service keeps the environment it was started with, so variables set later in a shell (including `NODE_EXTRA_CA_CERTS` and `OPENCODE_PROXY_API_KEY`) never reach it. Either:
>
> - add `--standalone` to `opencode run` to use a private server that inherits the current shell's environment, or
> - set both variables at user level (`[Environment]::SetEnvironmentVariable(..., 'User')`), then fully quit and restart OpenCode Desktop.
>
> To check whether the service is running: `Get-CimInstance Win32_Process | ? CommandLine -like '*opencode-cli*serve*'`

Verify the model is visible:

```bash
cd C:\Work\Projects\agentic-coding-platform
opencode models
```

Run a minimal smoke test:

```bash
opencode run --standalone --model proxy/qwen3-coder:30b-32k "reply with exactly: PROXY_OK"
```

Expected: response contains `PROXY_OK`, no TLS errors, no `provider.no-route` errors. (Drop `--standalone` once the Desktop service has been restarted with the user-level variables.)

`litellm-config.yaml` sets `drop_params: true` under `litellm_settings`. OpenCode sends OpenAI-only parameters such as `store`, and without this setting the Ollama provider rejects every request with `UnsupportedParamsError: ollama does not support parameters: ['store']`.

### Fallback — local Ollama when `spark-570a` is unreachable

To test the proxy path without the DGX Spark, point the alias at Ollama on the workstation. Keep `model_name` unchanged so OpenCode needs no changes:

```yaml
  - model_name: qwen3-coder:30b-32k
    litellm_params:
      model: ollama/gpt-oss:20b                 # any model listed by `ollama list`
      api_base: http://host.docker.internal:11434
```

Then `docker compose restart litellm`. Check that the container can reach host Ollama:

```powershell
docker exec proxy-litellm-1 python -c "import urllib.request;print(urllib.request.urlopen('http://host.docker.internal:11434/api/tags',timeout=5).read()[:200])"
```

This only proves the plumbing (TLS → key auth → routing → Ollama). The substitute model may not follow the prompt exactly; `gpt-oss:20b` answered `{ "PROXY_OK": null }`. While the fallback is in place, the "Qwen3-Coder" alias is served by a different model. Revert to `ollama/qwen3-coder:30b-32k` / `http://spark-570a:11434` when the Spark is back.

## Step 7 — verify traces reach LangFuse

Open LangFuse (`http://localhost:3000` by default). After the smoke test completes, a trace should appear with:

- `gen_ai.request.model = qwen3-coder:30b-32k`
- No PII fields (`user.email`, `user.ip`, `client.ssn` are redacted by the OTEL Collector processor)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `provider.no-route` in OpenCode | Model name mismatch | `model_name` in `litellm-config.yaml` must equal what OpenCode sends (`qwen3-coder:30b-32k`) |
| TLS error on `https://localhost` | CA not trusted | Redo Step 4; check `certutil -verifystore ROOT caddy-root.crt` |
| `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` in OpenCode, but `curl`/openssl verify fine | OpenCode (Bun) ignores the Windows store, or the Desktop background service was started without `NODE_EXTRA_CA_CERTS` | Set `NODE_EXTRA_CA_CERTS`; use `opencode run --standalone` or restart OpenCode Desktop (Step 6) |
| `LiteLLM Virtual Key expected. Received=${OP****KEY}` | `opencode.json` uses `${VAR}` syntax | Use `"apiKey": "{env:OPENCODE_PROXY_API_KEY}"` |
| `UnsupportedParamsError: ollama does not support parameters: ['store']` | OpenAI-only param forwarded to Ollama | Set `drop_params: true` under `litellm_settings` |
| Requests hang / connection errors to `spark-570a:11434` | Spark unreachable | Use the local Ollama fallback in Step 6 |
| `429 Too Many Requests` | Concurrency cap hit | Increase `max_parallel_requests` in `litellm-config.yaml` or wait for an active generation to finish |
| No traces in LangFuse | OTEL Collector not reachable | Check `OTEL_EXPORTER_OTLP_ENDPOINT` in `.env` and that the observability stack is up |
| LiteLLM logs `BadStatusLine('\x00\x00\x06\x04…')` / `Failed to export spans batch`, no traces in LangFuse | LiteLLM defaults to OTLP/HTTP but `:4317` is the collector's gRPC port | Keep `OTEL_EXPORTER_OTLP_PROTOCOL: grpc` in `docker-compose.yaml`, or point the endpoint at `:4318` and drop it |
| Traces land in the wrong LangFuse project | Project is chosen by the collector's `LANGFUSE_OTEL_AUTH` keys, not by the client | Change those keys in the observability stack; per-client routing is planned in `agentic-observability-platform/PROJECT-ROUTING-PLAN.md` |
| Context defaults to 8K | Model alias missing `num_ctx` | Verify `num_ctx: 32768` is in `litellm-config.yaml` under `litellm_params` |
