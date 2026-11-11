# Testbed

A small Python project (`shopcart`) and three coding tasks for trying the agentic coding platform the way a developer would: OpenCode from the CLI or the VS Code extension, through the Caddy → LiteLLM proxy, with every run traced in Langfuse.

Each run happens in a fresh copy of the project, and a check script decides pass/fail with tests the agent never sees.

## Tasks

| Task | Kind | What a pass needs |
|------|------|-------------------|
| `01-bulk-discount` | Bug fix | Fix an off-by-one in the bulk discount; the whole suite plus hidden acceptance tests pass |
| `02-sales-tax` | Multi-file feature | New `tax.py`, `Cart.total(region)`, tax rows on receipts, README update; acceptance tests pass |
| `03-receipt-tests` | Test repair | Fix out-of-date tests without touching `src/` or deleting tests |

The prompt for each task is `tasks/<task>/task.md`; it is copied into the workspace as `TASK.md`.

## One-time setup

1. Bring up the proxy and the observability stack and trust the Caddy CA: [docs/proxy-setup.md](../docs/proxy-setup.md), Steps 1–6.
2. Set `OPENCODE_PROXY_API_KEY` and `NODE_EXTRA_CA_CERTS` (Step 6 of the same doc).
3. Create the testbed venv (pytest):

   ```powershell
   .\testbed\scripts\setup.ps1
   ```

## Run a task from the CLI

```powershell
.\testbed\scripts\run-task.ps1 -Task 01
```

The script:

1. creates a workspace, e.g. `testbed\workspaces\01-bulk-discount-20261111-093000\`
2. runs `opencode run --standalone "Do the task described in TASK.md."` in it, with the testbed venv first on `PATH` and a 10-minute limit (`-TimeoutMinutes`)
3. runs `check.ps1` and prints PASS/FAIL, the session ID and step/token counts

Options: `-Model proxy/<model>` to try another model alias. `-UseService` sends the run to the OpenCode Desktop background service instead of a private server, which is the same path the VS Code extension uses (see the caveat below).

To work interactively instead, create the workspace and start OpenCode's TUI yourself:

```powershell
$ws = .\testbed\scripts\new-workspace.ps1 -Task 02
cd $ws; opencode
# ...give it the task, then:
.\..\..\scripts\check.ps1 -Workspace . -Channel cli-tui
```

## Run a task from the VS Code extension

```powershell
$ws = .\testbed\scripts\new-workspace.ps1 -Task 01
code $ws
```

In the new window, open the OpenCode panel and send: `Do the task described in TASK.md.` The workspace has its own `opencode.json`, so the proxy model is the default. When the agent finishes:

```powershell
.\testbed\scripts\check.ps1 -Workspace $ws -Channel vscode
```

**The extension goes through the OpenCode Desktop background service**, and the service only has the environment it was started with. Before using this channel:

- `OPENCODE_PROXY_API_KEY` and `NODE_EXTRA_CA_CERTS` must be set at **user** level, and OpenCode Desktop fully quit and restarted afterwards (docs/proxy-setup.md, Step 6). Otherwise requests fail with a TLS error or a key error.
- The agent runs the tests with whatever `python` the service sees, which is not the testbed venv. Install pytest for that Python once: `python -m pip install --user pytest`. Otherwise the agent can't run the tests (check.ps1 still uses the venv, so the verdict is unaffected).

## What check.ps1 does

Run it on any workspace, whichever channel produced it:

1. copies the task's hidden `acceptance/` tests into the workspace, runs them with the workspace's own `tests/`, and removes them again
2. fails the run if a path listed under `protected` in `task.json` differs from the `baseline` git tag, or a file under `min_tests` has fewer tests than required
3. finds the workspace's OpenCode session (a workspace is its own git repo, so it is the only session there) and summarises it: outcome, steps, tool calls, failed tool calls, tokens
4. appends one JSON line to `testbed\results\runs.jsonl`

`git -C <workspace> diff baseline` shows exactly what the agent changed.

## Finding the run in Langfuse

Open the **agentic-coding-platform** project and filter **Sessions** by the session ID that check.ps1 prints (`ses_…`). Each model call in the run is one trace named `opencode` in that session. In Grafana, the Agent Ops dashboard's **Project** variable covers the same runs.

## Repeat and concurrency runs

`runs.jsonl` keeps one row per run, so warm repeats are just the same command again. For concurrent sessions, start `run-task.ps1` in two or more terminals at once. Each gets its own workspace, and LiteLLM's `max_parallel_requests` (2) queues the rest. That covers the cold/warm and 2- and 4-session measurements in `PROJECT_NOTES.md`.

## Adding a task

Create `tasks/NN-name/` with:

- `task.md` — the prompt, written like an issue
- `task.json` — `{ "kind": "...", "protected": ["src"], "min_tests": { "tests/test_x.py": 3 } }` (empty lists/objects if not needed)
- `acceptance/test_acceptance_*.py` — hidden tests (optional; names must not clash with files in `project/tests`)
- `setup/` — files copied over the project before the baseline commit, e.g. a broken test (optional)

`project/` itself must stay green: `cd testbed\project; ..\.venv\Scripts\python.exe -m pytest`.
