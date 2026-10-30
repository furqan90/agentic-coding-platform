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

After this any tool on the workstation trusts `https://localhost` without certificate warnings.

> **Fallback (no admin rights):** set `NODE_EXTRA_CA_CERTS` to the path of `caddy-root.crt` in the shell where OpenCode runs. This overrides the system store for Node.js processes only.

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
```

Verify the model is visible:

```bash
cd C:\Work\Projects\agentic-coding-platform
opencode models
```

Run a minimal smoke test:

```bash
opencode run --model proxy/qwen3-coder:30b-32k "reply with exactly: PROXY_OK"
```

Expected: response contains `PROXY_OK`, no TLS errors, no `provider.no-route` errors.

## Step 7 — verify traces reach LangFuse

Open LangFuse (`http://localhost:3000` by default). After the smoke test completes, a trace should appear with:

- `gen_ai.request.model = qwen3-coder:30b-32k`
- No PII fields (`user.email`, `user.ip`, `client.ssn` are redacted by the OTEL Collector processor)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `provider.no-route` in OpenCode | Model name mismatch | `model_name` in `litellm-config.yaml` must equal what OpenCode sends (`qwen3-coder:30b-32k`) |
| TLS error on `https://localhost` | CA not trusted | Redo Step 4; check `certutil -verifystore ROOT caddy-root.crt` |
| `429 Too Many Requests` | Concurrency cap hit | Increase `max_parallel_requests` in `litellm-config.yaml` or wait for an active generation to finish |
| No traces in LangFuse | OTEL Collector not reachable | Check `OTEL_EXPORTER_OTLP_ENDPOINT` in `.env` and that the observability stack is up |
| Context defaults to 8K | Model alias missing `num_ctx` | Verify `num_ctx: 32768` is in `litellm-config.yaml` under `litellm_params` |
