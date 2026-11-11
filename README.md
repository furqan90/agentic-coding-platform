# Agentic coding platform

An evaluation and pilot of [OpenCode](https://opencode.ai) as the organisation's agentic coding tool, running against self-hosted models (Qwen3-Coder 30B on Ollama, on an NVIDIA DGX Spark).

Developers don't call Ollama directly. All model traffic goes through a proxy (Caddy → LiteLLM), which adds TLS, a virtual API key per developer, a concurrency cap and tracing into the shared observability stack (Langfuse, Prometheus, Grafana).

```
OpenCode (CLI / VS Code) ──HTTPS──▶ Caddy ──▶ LiteLLM ──▶ Ollama on DGX Spark
                                      │          │  └──OTLP──▶ OTEL Collector ──▶ Langfuse / Prometheus
                                      │          └──▶ Postgres (virtual keys)
                                      └──▶ Onboarding UI (admin: issue / revoke keys)
```

## Start here

| You want to… | Read |
|--------------|------|
| Understand how it fits together | [docs/architecture.md](docs/architecture.md) |
| Run the proxy on your own machine, or a shared proxy for a team | [docs/proxy-setup.md](docs/proxy-setup.md) |
| Onboard developers to a shared proxy (admin), or set up your machine from an onboarding file (developer) | [onboarding/README.md](onboarding/README.md) |
| Run coding tasks through OpenCode and judge the results | [testbed/README.md](testbed/README.md) |
| See goals, measurements so far and open questions | [PROJECT_NOTES.md](PROJECT_NOTES.md) |

### Quick start: developer on a shared proxy

You need only the onboarding file and `bootstrap.ps1` from your admin. You don't need this repo, Node or Docker.

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Config .\onboarding-<you>.json
```

Then open a new terminal, run `opencode`, and delete the onboarding file, because it contains your API key.

### Quick start: per-workstation proxy

Needs Docker Desktop and the `agentic-observability-platform` stack running ([docs/proxy-setup.md](docs/proxy-setup.md), Steps 1–6 for the details):

```powershell
cd proxy; copy .env.example .env      # set LITELLM_MASTER_KEY
docker compose up -d; cd ..
.\proxy\scripts\export-ca.ps1
.\proxy\scripts\install-ca.ps1 -CertFile .\proxy\certs\proxy-root-ca.crt
# issue a key (Step 5), set OPENCODE_PROXY_API_KEY at user level, open a new shell
opencode run --standalone "reply with exactly: PROXY_OK"
```

## Repository layout

| Path | Contents |
|------|----------|
| [opencode.json](opencode.json) | Project-local OpenCode provider pointing at `https://localhost/v1` |
| [proxy/](proxy/) | Docker Compose stack (caddy, litellm, postgres, onboarding), LiteLLM config and trace hook, CA scripts |
| [proxy/onboarding-ui/](proxy/onboarding-ui/) | Admin onboarding service (FastAPI) and its tests |
| [onboarding/](onboarding/) | `bootstrap.ps1` for developer machines, Windows Sandbox kit builder |
| [testbed/](testbed/) | Sample project, tasks and run/check scripts |
| [baseline-probe/](baseline-probe/) | Direct Ollama concurrency probe from the October baseline |
| [docs/](docs/) | Architecture and proxy runbook |

## Status

Pilot stage. As of 2026-11-11 the proxy, tracing, onboarding flow and testbed are in place, and the first single-session testbed runs are recorded. The concurrency cap is a provisional **2 active generations**. Multi-session and burst-load capacity on the Spark is not yet measured, so 50 users is a seat count, not a concurrency promise. See [PROJECT_NOTES.md](PROJECT_NOTES.md) for details and next actions.

Platform: scripts target Windows PowerShell 5.1+. The proxy runs on any Docker host.

## Secrets

Never commit `proxy/.env` (master key, admin hash), onboarding files (`onboarding-*.json`, which contain an API key) or `onboarding/.sandbox/`. They are gitignored, as are exported certificates (`*.crt`). The Caddy CA private key stays in the `caddy_data` volume on the proxy host. See [docs/architecture.md](docs/architecture.md#security-boundaries).
