# Proxy setup runbook

Step-by-step guide to bring up the proxy stack (Caddy, LiteLLM, Postgres and the onboarding UI) and connect it to the observability stack. Steps 1–8 set up a per-workstation proxy at `https://localhost`. [Shared proxy](#shared-proxy-one-proxy-for-many-developers) covers one proxy for a team. For how the pieces fit together, see [architecture.md](architecture.md).

## Prerequisites

- Docker Desktop running (Windows or Mac)
- Access to the `agentic-observability-platform` repo and its stack already started
- Network access to `spark-570a` on port 11434 (or a local Ollama for the [fallback](#fallback--local-ollama-when-spark-570a-is-unreachable))
- Windows PowerShell 5.1 or later for the scripts in `proxy/scripts/`

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

This starts `caddy`, `litellm`, `postgres` and `onboarding` (built from `proxy/onboarding-ui/` on first start). LiteLLM prints `LiteLLM: Proxy initialized` when ready. The onboarding UI stays locked until it is set up ([onboarding/README.md](../onboarding/README.md), "Admin UI"); the per-workstation steps below don't need it.

## Step 4 — trust Caddy's local CA (one-time, per machine)

Caddy generates a root CA on first start and stores it in the `caddy_data` Docker volume (`root.crt` and its private key `root.key`). Every certificate Caddy serves is signed by it. Clients need the public `root.crt`; `root.key` never leaves the volume.

Export it and check that Caddy's sites chain to it:

```powershell
.\proxy\scripts\export-ca.ps1
```

This writes `proxy\certs\proxy-root-ca.crt` (gitignored) and prints its SHA-256 fingerprint and an `OK` line per site. Then install it for OpenCode (no admin rights needed):

```powershell
.\proxy\scripts\install-ca.ps1 -CertFile .\proxy\certs\proxy-root-ca.crt
```

`install-ca.ps1` copies the certificate to `%USERPROFILE%\.agentic-coding\proxy-root-ca.crt`, sets `NODE_EXTRA_CA_CERTS` at user level, and checks that `https://localhost` presents a certificate signed by it. It refuses, and installs nothing, if the check fails or `NODE_EXTRA_CA_CERTS` already points at another file (`-Force` to replace). Then restart OpenCode Desktop and VS Code (Step 6).

For browsers, `curl` and other tools that use the Windows store, also import it there, in an **elevated (Administrator) PowerShell**:

```powershell
certutil -addstore -f "ROOT" proxy\certs\proxy-root-ca.crt
```

Set `NODE_EXTRA_CA_CERTS` whether or not you import it into the Windows store. It is Node and Bun's documented way to add a CA, and it doesn't depend on the build. In testing, OpenCode 2.0.29 behaved differently in two cases. An early run through the Desktop service failed with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` without the variable. On 2026-11-11 an `opencode run --standalone` succeeded without it on a machine that had the root in the Windows store. Don't rely on the Windows store alone.

If the `caddy_data` volume is ever deleted (e.g. `docker compose down -v`), Caddy creates a **new** CA on the next start. The old file stops working and OpenCode fails with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`. Repeat this step on every client.

## Step 5 — issue a virtual key per developer

The admin UI at `https://<proxy>/admin/onboarding/` does this for you, and also produces the onboarding file `bootstrap.ps1` needs ([onboarding/README.md](../onboarding/README.md)). To issue a key directly, replace `<master-key>` with the value from `.env`:

```bash
curl -X POST https://localhost/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "alice@corp.example", "key_alias": "alice@corp.example", "max_parallel_requests": 2}'
```

The response contains a `key` field (e.g. `sk-abc123…`). This is the value each developer sets as `OPENCODE_PROXY_API_KEY`.

Repeat for each developer. Keys are stored hashed in the `postgres` service (`postgres_data` volume) and survive container restarts, but the plaintext key is only returned now. Setting `key_alias` to the email lets the admin UI list, re-issue and revoke the key.

## Step 6 — configure OpenCode and smoke test

Set the virtual key in the developer's shell (add to `$PROFILE` to persist):

```powershell
$env:OPENCODE_PROXY_API_KEY = "sk-abc123..."
```

(`NODE_EXTRA_CA_CERTS` is already set at user level by `install-ca.ps1` in Step 4. Start a new shell to pick it up.)

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

To test the proxy path without the DGX Spark, point the alias at Ollama on the proxy host. Keep `model_name` unchanged so OpenCode needs no changes. The closest substitute is the same model pulled locally (`ollama pull qwen3-coder:30b`, about 18 GB), with `num_ctx` keeping the 32K context:

```yaml
  - model_name: qwen3-coder:30b-32k
    litellm_params:
      # TEMP: spark-570a unreachable. Restore: ollama_chat/qwen3-coder:30b-32k, http://spark-570a:11434
      model: ollama_chat/qwen3-coder:30b        # any model listed by `ollama list`; keep the ollama_chat/ prefix
      api_base: http://host.docker.internal:11434
      num_ctx: 32768
```

Then `docker compose restart litellm`. Check that the container can reach host Ollama:

```powershell
docker exec proxy-litellm-1 python -c "import urllib.request;print(urllib.request.urlopen('http://host.docker.internal:11434/api/tags',timeout=5).read()[:200])"
```

With the same model, results are comparable for quality, but not for speed or capacity: the workstation's GPU, not the Spark, does the work. A different model (e.g. `gpt-oss:20b`) only proves the plumbing (TLS → key auth → routing → Ollama); `gpt-oss:20b` answered the smoke test with `{ "PROXY_OK": null }`. Either way, record the substitute with any measurements taken while it is in place (testbed rows don't record the backend), and revert when the Spark is back.

Use the `ollama_chat/` prefix, not `ollama/`. `ollama_chat/` calls Ollama's `/api/chat` and passes OpenCode's tools natively. `ollama/` calls `/api/generate`, pastes the tools into the prompt and sets `format: json`, so the model can only answer with JSON. Every reply is parsed as a tool call, and an agent turn never ends with a text answer.

## Step 7 — verify traces reach LangFuse

LiteLLM stamps every span with the resource attribute `tl.project=agentic-coding-platform` (`OTEL_RESOURCE_ATTRIBUTES` in `docker-compose.yaml`; override with `LANGFUSE_PROJECT` in `.env`). The observability platform's collector routes on it to the matching LangFuse project. See `agentic-observability-platform/docs/MULTI-PROJECT.md`.

One-time registration in `agentic-observability-platform` (already done for `agentic-coding-platform`):

1. Create the project in LangFuse and an API key pair for it (Project → Settings → API Keys).
2. Add the slug under `projects:` in `otel/projects.yaml`, then run `python scripts/gen-collector-config.py` (needs `pyyaml`).
3. Add `LANGFUSE_OTEL_AUTH_AGENTIC_CODING_PLATFORM=<base64("pk-lf-…:sk-lf-…")>` to `otel/langfuse-projects.env` (gitignored).
4. Recreate the collector: `docker compose -f docker-compose/docker-compose.yml --env-file .env up -d --no-deps --force-recreate otel-collector`. It is shared by other stacks; untagged traces keep going to the default project.

After the smoke test completes:

- Span metrics carry the project label (about 15 s flush):
  ```powershell
  curl.exe -s http://localhost:8889/metrics | Select-String 'service_name="litellm".*tl_project="agentic-coding-platform"'
  ```
- OpenCode requests are labelled by `proxy/opencode_trace_attributes.py`. A LiteLLM upgrade can break this hook, so re-run this check after changing the pinned image:
  ```powershell
  curl.exe -s http://localhost:8889/metrics | Select-String 'agent_name="opencode".*span_name="Received Proxy Server Request"'
  ```
- In LangFuse (`http://localhost:3000`) the trace appears in the **agentic-coding-platform** project, not in the default project, with:
  - Name `opencode`, and a Session ID matching OpenCode's session (`ses_…`). The name is fixed because OpenCode's requests don't say which agent (`build`, `plan`) is running.
  - `gen_ai.request.model = qwen3-coder:30b-32k`
  - No PII fields (`user.email`, `user.ip`, `client.ssn` are redacted by the OTEL Collector processor)
- Grafana's Agent Ops dashboard can be filtered with its **Project** variable. RED panels include LiteLLM; the cost panel does not, because `agent_tokens_total` and `agent_cost_usd_total` come from the platform's SDK, which LiteLLM doesn't use.

`LANGFUSE_PROJECT` here is only a compose variable that fills in `OTEL_RESOURCE_ATTRIBUTES`; LiteLLM itself doesn't read it.

## Step 8 — try a real coding task

[testbed/README.md](../testbed/README.md) has a sample project and three tasks (bug fix, feature, test repair) to run through OpenCode from the CLI or the VS Code extension, with pass/fail checks and the session ID to look up in LangFuse:

```powershell
.\testbed\scripts\setup.ps1
.\testbed\scripts\run-task.ps1 -Task 01
```

## Developer machine checklist

For a developer whose machine runs its own proxy (the setup above). Steps 1–3 bring up the stacks; then:

1. **CA:** `.\proxy\scripts\export-ca.ps1`, then `.\proxy\scripts\install-ca.ps1 -CertFile .\proxy\certs\proxy-root-ca.crt` (Step 4). Optionally import it into the Windows store for browsers and curl.
2. **Key:** get a virtual key (Step 5) and persist it:
   `[Environment]::SetEnvironmentVariable('OPENCODE_PROXY_API_KEY', 'sk-...', 'User')`
3. **Restart** OpenCode Desktop (fully quit, including the tray/background service) and VS Code. They keep the environment they were started with.
4. **Check:** in a new shell,
   ```powershell
   [Environment]::GetEnvironmentVariable('NODE_EXTRA_CA_CERTS','User')   # %USERPROFILE%\.agentic-coding\proxy-root-ca.crt
   [bool]$env:OPENCODE_PROXY_API_KEY                                    # True
   opencode run --model proxy/qwen3-coder:30b-32k "reply with exactly: PROXY_OK"
   ```
   Then try the same prompt from the VS Code extension, or run a testbed task (Step 8).

## Shared proxy (one proxy for many developers)

If one machine runs the proxy for the team, developers don't run Docker at all. They connect to the proxy host by name, and each machine needs that proxy's root certificate.

### Admin, once

1. Pick a host name every developer can resolve, e.g. `ai-proxy.corp.example`, and add it to `proxy/.env`:
   ```
   PROXY_SITES=localhost, ai-proxy.corp.example
   ```
   Recreate Caddy: `docker compose --env-file .env up -d caddy`. Caddy issues a certificate for each name from its local CA (`tls internal`). Port 443 must be reachable from developer machines (firewall).

   To let clients connect by **IP address** (e.g. `PROXY_SITES=localhost, 172.19.50.206` for a test from Windows Sandbox), also set `PROXY_DEFAULT_SNI=172.19.50.206`. Clients send no TLS server name for an IP. Inside Docker, Caddy can't match the host's IP to its certificate, so without this every handshake by IP fails. Only one IP can be the default. A DHCP address can change, so prefer a host name beyond testing.
2. Export the CA and check every name:
   ```powershell
   .\proxy\scripts\export-ca.ps1
   ```
   All names must show `OK`. Note the `fingerprint: SHA256 …` line.
3. Publish the fingerprint through a channel developers already trust: the team wiki, an internal chat channel, or onboarding mail. **Not** through the proxy itself. The fingerprint is what lets a developer detect a forged certificate. Optionally also share `proxy\certs\proxy-root-ca.crt`, which is public and safe to send.
4. Issue each developer a key and onboarding file from the admin UI at `https://ai-proxy.corp.example/admin/onboarding/` (setup: [onboarding/README.md](../onboarding/README.md), "Admin UI"). Send the file and `onboarding/bootstrap.ps1` through a private channel. Bootstrap does the developer steps below in one go. Without the UI, use Step 5 against `https://ai-proxy.corp.example/key/generate`.

Never copy `root.key` or `intermediate.key` off the proxy host. Anyone holding `root.key` can issue certificates every client trusts. Back up the `caddy_data` volume instead. If it is lost, Caddy creates a new CA and every developer must reinstall.

### Developer, once per machine

1. Install the CA from the proxy, verified against the published fingerprint:
   ```powershell
   .\proxy\scripts\install-ca.ps1 -ProxyUrl https://ai-proxy.corp.example -Fingerprint <SHA256 from the admin>
   ```
   The script downloads `https://ai-proxy.corp.example/ca.crt`, compares its fingerprint, and installs only on a match. Then it checks that the proxy's certificate chains to it for that host name. Alternatively, use `-CertFile <file from the admin>`; add `-Fingerprint` to verify that too.
2. Persist the virtual key: `[Environment]::SetEnvironmentVariable('OPENCODE_PROXY_API_KEY', 'sk-...', 'User')`.
3. Point OpenCode at the shared proxy. In the project's `opencode.json`, set `provider.proxy.options.baseURL` to `https://ai-proxy.corp.example/v1`.
4. Restart OpenCode Desktop and VS Code, and run the check in the checklist above.

`install-ca.ps1` refuses, and changes nothing, when:

- the fingerprint is missing or wrong
- the certificate is not a CA
- the proxy doesn't present a certificate for that host name signed by it
- the name isn't in `PROXY_SITES` (TLS handshake fails)
- `NODE_EXTRA_CA_CERTS` already points at a different file (`-Force` to replace it, or combine both PEM files into one)

`-Scope Process` sets the variable for the current shell only, which is useful for trying it out.

### Longer term

`tls internal` with a per-proxy CA is fine for a pilot. For organisation-wide use, have IT issue a certificate for the proxy's host name from the **company's internal CA**, which managed machines already trust, and configure Caddy with it (`tls <cert> <key>`). Developers then skip the CA step entirely. Whether `NODE_EXTRA_CA_CERTS` is still needed then depends on the Windows-store behaviour described in Step 4, so test it on a clean machine.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `provider.no-route` in OpenCode | Model name mismatch | `model_name` in `litellm-config.yaml` must equal what OpenCode sends (`qwen3-coder:30b-32k`) |
| TLS error on `https://localhost` | CA not trusted | Redo Step 4; `export-ca.ps1` shows whether each site chains to the exported root |
| `install-ca.ps1`: `TLS handshake with <host> failed` | Host name not in `PROXY_SITES`, or Caddy not recreated after changing it | Use a listed name; `docker compose --env-file .env up -d caddy` |
| `install-ca.ps1`: `Fingerprint mismatch` | Wrong value, a new CA after the `caddy_data` volume was recreated, or something intercepting the connection | Check the fingerprint with the admin (`export-ca.ps1` prints the current one). Don't install until they match |
| `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` in OpenCode, but `curl`/openssl verify fine | OpenCode (Bun) ignores the Windows store, or the Desktop background service was started without `NODE_EXTRA_CA_CERTS` | Set `NODE_EXTRA_CA_CERTS`; use `opencode run --standalone` or restart OpenCode Desktop (Step 6) |
| `LiteLLM Virtual Key expected. Received=${OP****KEY}` | `opencode.json` uses `${VAR}` syntax | Use `"apiKey": "{env:OPENCODE_PROXY_API_KEY}"` |
| `UnsupportedParamsError: ollama does not support parameters: ['store']` | OpenAI-only param forwarded to Ollama | Set `drop_params: true` under `litellm_settings` |
| Requests hang / connection errors to `spark-570a:11434` | Spark unreachable | Use the [local Ollama fallback](#fallback--local-ollama-when-spark-570a-is-unreachable) in Step 6 |
| `429 Too Many Requests` | Concurrency cap hit, global (`max_parallel_requests` in `litellm-config.yaml`) or per key (set at issue time) | Wait for an active generation to finish, or raise the limit. The cap is provisional; see [PROJECT_NOTES.md](../PROJECT_NOTES.md) before raising it |
| Admin UI: every login fails | `ONBOARDING_ADMIN_HASH` not set (the default hash is of a discarded password), or set without single quotes so compose expanded its `$` | Set it in `.env` in single quotes; `docker compose --env-file .env up -d caddy` |
| Admin UI refuses to issue keys | `proxy/certs/proxy-root-ca.crt` missing | Run `.\proxy\scripts\export-ca.ps1` |
| No traces in LangFuse | OTEL Collector not reachable | Check `OTEL_EXPORTER_OTLP_ENDPOINT` in `.env` and that the observability stack is up |
| LiteLLM logs `BadStatusLine('\x00\x00\x06\x04…')` / `Failed to export spans batch`, no traces in LangFuse | LiteLLM defaults to OTLP/HTTP but `:4317` is the collector's gRPC port | Keep `OTEL_EXPORTER_OTLP_PROTOCOL: grpc` in `docker-compose.yaml`, or point the endpoint at `:4318` and drop it |
| Traces land in the default LangFuse project instead of `agentic-coding-platform` | Slug not registered in the collector's `otel/projects.yaml`, typo in `LANGFUSE_PROJECT`, or collector not recreated after registering (unknown slugs fall back silently) | `docker exec proxy-litellm-1 env \| grep OTEL_RESOURCE`; check the slug in `projects.yaml`; regenerate and recreate the collector (Step 7) |
| Trace name empty in LangFuse, no `agent_name="opencode"` metric | `opencode_trace_attributes.py` not mounted or not loaded, or a LiteLLM upgrade changed its hook; OpenCode's `traceparent` otherwise leaves LiteLLM's span without a root | Check the volume in `docker-compose.yaml` and `callbacks` in `litellm-config.yaml`, then `docker compose logs litellm` for import errors |
| Collector logs `401` for `otlp_http/langfuse-agentic-coding-platform` | `LANGFUSE_OTEL_AUTH_AGENTIC_CODING_PLATFORM` missing or wrong in `otel/langfuse-projects.env` | Re-encode the project's `pk:sk`, recreate the collector |
| `opencode run` never finishes; the model keeps rewriting/re-reading files, never replies in text, ignores "don't create files" | Model routed with `ollama/` (forced JSON, emulated tools) | Use `model: ollama_chat/<model>` in `litellm-config.yaml`, then `docker compose restart litellm` |
| Context defaults to 8K | Model alias missing `num_ctx` | Verify `num_ctx: 32768` is in `litellm-config.yaml` under `litellm_params` |
