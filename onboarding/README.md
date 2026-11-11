# Developer onboarding

Sets up a new developer machine (no repo, no Node, no Docker needed) to use the agentic coding platform through a shared proxy.

```
admin                                   developer
-----                                   ---------
issue key for alice@corp  ──onboarding-alice.json──▶  bootstrap.ps1 -Config onboarding-alice.json
(admin UI on the proxy)      (private channel)        CA + key + OpenCode CLI + config + smoke test
```

## Developer: run bootstrap.ps1

Save `bootstrap.ps1` and the onboarding file your admin sent you in one folder, then in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Config .\onboarding-alice.json
```

It runs these steps, stopping at the first failure:

| Step | What happens | Stops if |
|------|--------------|----------|
| 1. Onboarding file | Checks format and fields | Wrong format, missing field, non-https URL |
| 2. Proxy certificate | Downloads `<proxy>/ca.crt`, compares its SHA-256 with the file | Fingerprint mismatch, not a CA certificate |
| 3. API key | Calls `/v1/models` with the key, over a connection verified against that CA | Key rejected (401), default model not served |
| 4. OpenCode CLI | Downloads the pinned `@opencode/cli-windows-<arch>` tarball from the npm registry, checks its sha512 against the registry's `integrity`, installs to `%LOCALAPPDATA%\Programs\agentic-coding\opencode` | Integrity mismatch |
| 5. Environment | Saves the CA to `%USERPROFILE%\.agentic-coding\proxy-root-ca.crt`; sets `NODE_EXTRA_CA_CERTS` and `OPENCODE_PROXY_API_KEY` at user level; adds OpenCode to the user `PATH` | `NODE_EXTRA_CA_CERTS` already points elsewhere (`-Force` to replace) |
| 6. OpenCode config | Adds the `proxy` provider and default model to `%USERPROFILE%\.config\opencode\opencode.json`. Other settings are kept and the old file is backed up | — |
| 7. Smoke test | `opencode run --standalone "reply with exactly: PROXY_OK"` (6 min limit for a cold model load) | No `PROXY_OK` in the reply |

Nothing is installed if steps 1–3 fail. Re-running is safe: an installed CLI of the same version is reused, and the config is merged again.

Afterwards, open a new terminal (and restart VS Code / OpenCode Desktop), then **delete the onboarding file**, which contains your API key.

Options: `-Scope Process` keeps all changes in the current shell, for trying it out. `-InstallDir`, `-CaPath` and `-OpenCodeConfigPath` move the files; a non-default config path also sets `OPENCODE_CONFIG`. `-SkipSmokeTest` and `-SmokeTestMinutes` control the smoke test.

**Network:** the developer machine must reach the proxy's host name on port 443, and that name must be in the proxy's `PROXY_SITES` ([docs/proxy-setup.md](../docs/proxy-setup.md), "Shared proxy"). From Windows Sandbox or a VM, `localhost` is the sandbox itself, so use the proxy host's name or IP. For an IP, add it to `PROXY_SITES` too; Caddy issues IP certificates with `tls internal`. The npm registry (`registry.npmjs.org`) must be reachable for step 4, and OpenCode fetches the `@ai-sdk/openai-compatible` provider package from npm on first use.

## Testing on a clean machine (Windows Sandbox)

Needs the Windows Sandbox feature (Windows Pro/Enterprise; enabling it needs a restart). The proxy must accept connections by an address the sandbox can reach. For this machine's IP, set `PROXY_SITES` and `PROXY_DEFAULT_SNI` in `proxy/.env` and recreate Caddy ([docs/proxy-setup.md](../docs/proxy-setup.md), "Shared proxy"). Then:

```powershell
.\onboarding\new-sandbox-kit.ps1 -Config .\onboarding-alice.json   # proxy_url = https://<host IP or name>
# double-click onboarding\.sandbox\agentic-coding-bootstrap.wsb
```

The sandbox starts with the kit mapped read-only at `C:\kit` and runs bootstrap in a PowerShell window. In that window, try `opencode` or `opencode run "hello"` afterwards. Closing the sandbox discards everything. The kit folder holds the API key; it is gitignored, but delete it when done.

## Onboarding file (`agentic-coding-onboarding/1`)

```json
{
  "format": "agentic-coding-onboarding/1",
  "email": "alice@corp.example",
  "issued_at": "2026-11-11T10:45:40Z",
  "proxy_url": "https://ai-proxy.corp.example",
  "ca_fingerprint_sha256": "E6:03:3C:...:7D:AE",
  "api_key": "sk-...",
  "opencode_version": "2.0.29",
  "default_model": "qwen3-coder:30b-32k",
  "models": [{ "id": "qwen3-coder:30b-32k", "name": "Qwen3-Coder 30B (32K context, via LiteLLM)", "context": 32768, "output": 4096 }]
}
```

The file is a secret (it holds the key), so send it through a private channel. The fingerprint inside it is what lets bootstrap detect a forged proxy certificate. The admin UI below produces it. Without the UI, assemble it by hand: key from `/key/generate` (docs/proxy-setup.md, Step 5), fingerprint from `proxy/scripts/export-ca.ps1`, models and limits from `proxy/litellm-config.yaml`.

## Admin UI

`https://<proxy>/admin/onboarding/`, the `onboarding` service in `proxy/docker-compose.yaml` (code in [proxy/onboarding-ui/](../proxy/onboarding-ui/)).

- **Issue:** enter an email. The UI creates a LiteLLM key with `user_id` and `key_alias` set to the email, 2 parallel requests, and `metadata.issued_by` set to the admin's login. The browser downloads `onboarding-<email>.json`, and the page shows the bootstrap command to send with it. **Download bootstrap.ps1** gives the script itself, which is the same for every developer. The repo's copy is served behind the admin login, so it goes out through the same private channel as the key, not over a connection the developer can't verify yet. The key is only available at this moment, because LiteLLM stores keys hashed. If the file is lost, use **Re-issue**.
- **Issued keys:** email, issue date, last activity, spend, parallel limit and issuing admin. **Re-issue** revokes and replaces a key; **Revoke** removes it immediately. Keys created elsewhere (e.g. with the master key directly) are shown when "Show keys not issued here" is ticked.
- One key per email: issuing for an email that already has a key is refused; re-issue it instead.

**Setup (proxy host, once):**

1. Export the CA: `.\proxy\scripts\export-ca.ps1`. The UI reads only the resulting public `proxy\certs\proxy-root-ca.crt` and refuses to issue until it exists. It never mounts Caddy's data volume, which holds `root.key`.
2. In `proxy/.env`, set the URL developers will use, plus an admin login:
   ```
   PUBLIC_PROXY_URL=https://ai-proxy.corp.example
   ONBOARDING_ADMIN_USER=admin
   ONBOARDING_ADMIN_HASH='$2a$14$...'
   ```
   Create the hash with `docker compose exec caddy caddy hash-password`. Keep the single quotes: the hash contains `$`, which compose would otherwise expand. Until a hash is set, the UI is locked: every login fails.
3. `docker compose --env-file .env up -d --build onboarding caddy`.

**Security:**
- **Master key:** stays in the service container and is never sent to the browser.
- **Admin identity:** Caddy enforces basic auth, then sets `X-Admin-User` from the authenticated login, replacing any value the client sent.
- **CSRF:** state-changing calls must be JSON, and their `Origin` must match the host, so another site can't use the browser's cached basic-auth login to issue or revoke keys.
- **Exposure:** the service has no host port; it is reachable only through Caddy.

Tests: `docker run --rm -v "${PWD}\proxy\onboarding-ui:/src:ro" python:3.12-slim sh -c "pip install -q -r /src/requirements.txt -r /src/requirements-dev.txt && cp -r /src /tmp/w && cd /tmp/w && python -m pytest -q tests"`.
