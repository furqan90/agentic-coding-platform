# OpenCode + DGX Spark feasibility notes

Last updated: 2026-10-20

## Goal

Evaluate OpenCode as the organization's agentic coding platform, using a remotely served Ollama endpoint on one NVIDIA DGX Spark. Establish coding quality, interactive speed, and realistic concurrency while accounting for occasional bursty workloads on the Spark.

## Current setup

- OpenCode is installed.
- Ollama is reachable from the host at `http://spark-570a:11434`.
- The Spark is an NVIDIA DGX Spark with 128 GB unified memory. NVIDIA lists 273 GB/s memory bandwidth.
- Initial audience is about 50 users. This is a user/seat count, not a measured 50-way simultaneous inference requirement.
- Some other workloads share the Spark; they are bursty rather than continuously active.
- Model inventory was shared in a screenshot. Coding candidates already present include `qwen3-coder:30b` (~18 GB), `qwen3.6:latest` (~23 GB), and `gpt-oss:20b` (~13 GB). The inventory also includes larger and smaller variants.
- A later `ollama ps` screenshot showed `llama3.2:3b` loaded at 100% GPU with an 8,192-token context. This is not a coding-model capacity measurement.

## Working assumptions and estimates

- A single Spark may serve 50 registered users if only a small subset generate at once; capacity for 50 simultaneous generations is unproven and should not be promised.
- Use **2 simultaneous generations** as a conservative provisional pilot cap, then measure at 1, 2, 4, and 8 concurrent requests.
- Compare `qwen3-coder:30b` and `qwen3.6:latest` for coding tasks; use `gpt-oss:20b` as a smaller speed comparison if useful.
- Existing public benchmarks are single-request references, not guarantees for OpenCode traffic, concurrency, long context, or shared Spark workloads.
- Ollama parallel requests increase context-memory requirements. Keep the model/context/concurrency configuration fixed and recorded for each run.
- The actual comfortable cap must be measured under both normal conditions and while a representative burst workload is running.

## Next step: establish a real OpenCode baseline

Use `qwen3-coder:30b` first because the target workload is agentic coding and the model is already present. Keep current shared workloads in their normal state.

1. Record the current serving configuration and `ollama ps` output.
2. Select `qwen3-coder:30b` in OpenCode through the existing remote Ollama connection.
3. Run one representative, bounded coding task in a non-critical repository. Capture wall-clock time, time until the first response, any visible queue/wait, whether tool calls work, and whether the result passes the repository's normal checks.
4. Repeat the same task once to distinguish a cold model load from a warm request. Record the configured context length; do not change it between comparisons.
5. If the single-user result is acceptable, repeat with 2, 4, and 8 simultaneous sessions. Stop increasing concurrency if latency, errors, or the other workloads become unacceptable.
6. Repeat the useful concurrency levels while a representative burst workload is active. Use those results to choose an active-generation limit and decide whether requests should queue during bursts.

### Baseline run 2026-10-20 (Ollama API, single request)

- Endpoint responded at `http://spark-570a:11434`; Ollama version: `0.40.3`.
- Selected model: `qwen3-coder:30b`.
- Request context: 32,768 tokens; output cap: 300 tokens; temperature: 0; same short TypeScript path-normalization prompt in both runs.
- Cold request: 67 prompt tokens, 171 output tokens, 7.69 s wall time including 4.70 s model load; 92.94 generated tokens/s.
- Warm repeat: 67 prompt tokens, 171 output tokens, 2.63 s wall time; 93.18 generated tokens/s; 5,391 prompt tokens/s reported by Ollama.
- `ollama ps` after warm run showed `qwen3-coder:30b` at 32,768 context and about 31.7 GB runtime allocation.
- Quality check: response attempted the required behavior and examples, but the repeated-slash regular expression appears malformed in the returned TypeScript. Treat this as a failed code-quality check until compiled/verified.
- Scope limitation: this is a direct Ollama API generation baseline, not yet an OpenCode end-to-end/tool-call benchmark. It used a very short prompt and one active request, so it does not predict repository-scale latency or concurrency capacity.
- OpenCode CLI version: `2.0.29`. Its model list currently includes `ollama/gemma4:26b`, `ollama/gpt-oss:20b`, and `ollama/qwen3.5:latest`, but not `ollama/qwen3-coder:30b`.
- An OpenCode attempt with `--model ollama/qwen3-coder:30b` returned `provider.no-route` (the model is served by Ollama but isn't registered in OpenCode's current model catalog/config).
- An attempted OpenCode request with the already-listed `ollama/qwen3.5:latest` produced no output and was interrupted. No result was obtained from that attempt.
- The CLI required an approved unsandboxed invocation to write its normal log under the user's `.local/share/opencode` directory; it then ran `opencode --version` successfully.

### OpenCode path and coding probe 2026-10-20

- Added a project-local `opencode.json` that points the Ollama provider at `http://spark-570a:11434/v1` and declares the coding model. This leaves the user's global OpenCode config alone.
- OpenCode's initial request for `qwen3-coder:30b` used only 8,192 context, despite the configured model limit; the OpenAI-compatible API path did not carry Ollama's `num_ctx` option through.
- Created an Ollama alias `qwen3-coder:30b-32k` from the same quantized model with `PARAMETER num_ctx 32768`, then selected it in the project config. `ollama ps` confirmed 32,768 context and about 31.7 GB runtime allocation.
- OpenCode 2.0.29 discovered the alias and completed a bounded coding task through its Build agent. It created a small implementation and Node assert file under `baseline-probe/`, used file and shell tools, recovered from shell command syntax mistakes on Windows, and the Node checks passed. Elapsed time from OpenCode run timestamps was about 24 seconds. This is a small smoke test, not a broad coding-quality evaluation.

### Short-request concurrency sweep 2026-10-20

These were direct Ollama API requests to the 32K alias, each with a 48-token prompt, 128-token output cap, `num_ctx=32768`, and temperature 0. No other Ollama models were reported as loaded. These short requests do not represent long repository prompts or prove burst-workload headroom.

| Concurrent requests | Per-request wall time | Ollama generation rate per request | Aggregate output rate (approx.) | Errors |
| ---: | ---: | ---: | ---: | ---: |
| 2 | 2.84–2.87 s | 80.7 tokens/s | 89 tokens/s | 0 |
| 4 | 4.98–5.01 s | 79.5–81.2 tokens/s | 102 tokens/s | 0 |

The 2- and 4-request results suggest good short-request throughput at these levels, but the prompts were tiny. The response wall time grows from about 2.9 to 5.0 seconds at four-way load, while per-request decode speed stays near 80 tokens/s. Do not extrapolate this to 50 simultaneous OpenCode sessions.

## Current assessment after baseline

- The hardware/model combination is viable for an OpenCode pilot: Qwen3-Coder 30B Q4_K_M returned about 93 tokens/s for a short warm direct request, and a small OpenCode agent task completed with working file edits and passing checks.
- Two to four simultaneous short generations completed successfully, but realistic OpenCode prompts and shared burst workloads still need measurement.
- A provisional deployment cap of **2 active coding generations** remains prudent until long-prompt tests and shared-workload measurements are done. Four-way short-request performance is promising, not yet a production capacity guarantee.
- The 50-user population is plausible as a seat count; measured capacity for 50 simultaneous active generations remains unknown and is not supported by these tests.

## Remote-versus-local Ollama verification 2026-10-20

- The project-local `opencode.json` explicitly sets `provider.ollama.options.baseURL` to `http://spark-570a:11434/v1` and the default model to `ollama/qwen3-coder:30b-32k`.
- `opencode models` resolves that configured model.
- A short request issued through OpenCode returned the requested `REMOTE_ROUTE_OK` response.
- Immediately afterward, the remote Spark `/api/ps` showed `qwen3-coder:30b-32k` loaded at 32,768 context.
- The workstation's separate local `ollama ps` showed `qwen3.5:latest`, not the Spark model. The OpenCode request therefore went to the remote Spark endpoint, while local Ollama remained a distinct server and was not selected by this project's configuration.

## Next actions

1. **Choose a representative repository and tasks.** Use a non-critical codebase with its normal build/test workflow. Select three tasks: a small bug fix, a bounded multi-file change, and a test-failure repair. Avoid synthetic prompts as the main quality signal.
2. **Run a realistic single-user baseline through OpenCode.** Keep `qwen3-coder:30b-32k` fixed. Record model/context, task, time to first response, total task time, tool-call errors, output speed if available, and whether the repository checks pass. Repeat warm runs.
3. **Set an experience target with the pilot users.** Agree what feels acceptable for initial response, generated-token speed, and total task wait. Use this to define a pass/fail threshold before increasing concurrency.
4. **Measure concurrent OpenCode sessions.** Start at 2 active sessions, then try 4 if the first level meets the target. Use representative tasks, not only short API completions. Record p50/p95 latency, queue time, errors, task outcomes, and Spark memory/compute use.
5. **Repeat during a real burst workload.** Compare normal and burst conditions. If the burst cannot be scheduled during the evaluation, record it as an unmeasured condition and keep the active-session cap conservative.
6. **Set the pilot admission policy.** Decide how many active generations to allow, what happens to excess requests (queue or reject/retry), and whether burst workloads have priority. Separate the number of licensed/eligible users from simultaneous request capacity.
7. **Prepare organization access before expanding beyond the pilot.** Keep Ollama behind an authenticated gateway or trusted private network because its local API has no authentication. Add request limits and basic health/latency monitoring, then pilot with a small developer group before onboarding all 50 users.

Immediate next input needed: a representative repository/task and the normal checks we should use. Current measured evidence supports an initial 2-active-session cap; it does not establish long-prompt or burst-load capacity.

### Candidate baseline repository

- User identified `C:\Work\secp-leap-portal`, a substantial Angular application.
- Read-only top-level inspection found `angular.json`, `package.json`, Jest configuration/tests, `src/app`, and a sizable `src/excel-core` rules/templates area. The checkout also contains `node_modules`, build outputs, and a custom CKEditor build.
- This is a good realistic pilot repository if the task is bounded to one issue/component/service and its existing checks. Do not ask the model to absorb or refactor the entire app as the first task.
- No files were changed in that repository. Git status could not be read from the current execution sandbox, so its working-tree cleanliness is unknown.
- For the baseline, select one small ticket/bug with clear expected behavior and run its focused Jest test or other normal check. Avoid using build output or generated dependency trees as task context.

Record per run: date/time, model tag, context length, concurrency, other-workload state, cold/warm state, time to first token, total response/task time, generated tokens/s if available, queue/errors, and coding-task outcome.

## Measurements still needed

- Exact Ollama version and active server settings, especially context length and parallel request setting.
- Actual OpenCode model/provider configuration and confirmation that tool calls work through the remote endpoint.
- Representative normal and burst workloads, including approximate resource use and duration if known.
- User experience target for per-request speed and wait time.
- Measured concurrency results for selected models.

## Operational note

The local Ollama API does not require authentication. Before organization-wide access, keep the endpoint on a trusted network or put an authenticated gateway/proxy in front of it, with access control and request limits.
