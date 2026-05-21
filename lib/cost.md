# Cost Protocol

Status: protocol shared by all skills in the `wk` plugin. Implemented in `WK-3` (shipped in v6.0.0).

Per-ticket token cost tracking. Each `Agent` invocation contributes input + output token counts; the helper multiplies by the rates in `lib/cost-rates.json` and accumulates a running total in `metadata.cost`. Stage 9 surfaces the total at wrapup. Unknown models fall back to a `lazy` rate (warns once, never blocks).

## Storage

Lives at `metadata.cost` (top-level object in `./.doer/tickets/<TICKET-ID>/metadata.json`). Created lazily on first `record` call.

```json
{
  "currency": "USD",
  "rates_fetched_at": "<ISO8601 from cost-rates.json at first record>",
  "total_input_tokens": 123456,
  "total_output_tokens": 78901,
  "total_usd": 1.234567,
  "by_model": {
    "claude-opus-4-7": {
      "calls": 12,
      "input_tokens": 80000,
      "output_tokens": 50000,
      "usd": 0.987654
    },
    "claude-sonnet-4-6": { ... }
  },
  "by_stage": {
    "4": {"calls": 7, "usd": 0.5},
    "5": {"calls": 5, "usd": 0.42}
  },
  "unknown_models": [
    {"model": "claude-future-model-1", "calls": 2, "first_seen": "<ISO8601>"}
  ]
}
```

- `total_usd` is rounded to 6 decimals on every write.
- `by_model` and `by_stage` are append-update; `unknown_models` lists any model id not present in `cost-rates.json` at record time.

## Rates file

Lives at `${CLAUDE_PLUGIN_ROOT}/lib/cost-rates.json`. Hand-curated; refreshed via `scripts/refresh-rates.sh` (interactive, dev-pastes-from-pricing-page). Schema:

```json
{
  "currency": "USD",
  "source": "https://claude.com/pricing#api",
  "fetched_at": "<ISO8601>",
  "ttl_days": 7,
  "rates": {
    "claude-opus-4-7": {
      "input_per_mtok": 15.00,
      "output_per_mtok": 75.00
    },
    "claude-sonnet-4-6": {
      "input_per_mtok": 3.00,
      "output_per_mtok": 15.00
    }
  },
  "lazy_fallback": {
    "input_per_mtok": 3.00,
    "output_per_mtok": 15.00,
    "rationale": "Sonnet-tier midpoint when the model id is not yet listed; warns and never blocks."
  }
}
```

`per_mtok` = USD per 1,000,000 tokens.

### Staleness

A rates file is **stale** when `now - fetched_at >= ttl_days * 86400`. The helper warns to stderr on stale rates but does NOT block. Refresh via:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/refresh-rates.sh
```

## Operations

The orchestrator MUST call these via `${CLAUDE_PLUGIN_ROOT}/lib/helpers/cost.sh`:

| Operation | Arguments | Behavior |
|-----------|-----------|----------|
| `record <ID>` | `--model <id> --input <tokens> --output <tokens> [--stage <N>] [--agent <name>]` | Update `metadata.cost` totals + `by_model[<id>]` + `by_stage[<N>]`. Unknown models use the `lazy_fallback` rate, append to `unknown_models`, and warn once per model to stderr. |
| `total <ID>` | (none) | Print `metadata.cost` as JSON. Empty object if nothing has been recorded yet. |
| `status <ID>` | (none) | Print a human-readable one-paragraph summary: total tokens, total USD, top-3 models, top-3 stages, any unknown models, rate file age. |

All operations write atomically: read `metadata.json`, mutate via `jq`, write to `metadata.json.tmp`, `mv` over the original.

## When to record

- After every `Agent` call returns, if the SDK exposed token counts. Most Claude Code Agent invocations expose input/output tokens in the trailing usage block.
- The orchestrator MUST attempt the record but MUST NOT abort the pipeline if the record fails (e.g. unknown shape, rates file missing). Cost tracking is best-effort.
- `--agent <name>` is informational; not persisted directly. The model id is the canonical key.

## Stage 9 wrapup

Step 12 (after inbox clear): run `cost.sh status <ID>` and narrate the one-paragraph summary inline. The persisted state (`metadata.cost`) is the source of truth; the narration is just a UX courtesy.

## Lazy fallback

When a model id is not in `cost-rates.json`:

1. Use `lazy_fallback.input_per_mtok` / `lazy_fallback.output_per_mtok` for the calculation.
2. Add an entry to `metadata.cost.unknown_models` (or increment its `calls`) with `first_seen` set to now.
3. Warn to stderr: `"cost.sh: unknown model '<id>', using lazy_fallback. Refresh rates with scripts/refresh-rates.sh."`. Within a single process call the warning is suppressed for repeats; across calls each new process re-warns (acceptable noise; the orchestrator narrates the warning once when surfacing it).

The fallback rate is intentionally close to mid-tier Sonnet pricing; it errs slightly conservative for Haiku and slightly low for Opus. Acceptable for a warn-only signal.

## Configuration

- `WK_COST_DISABLED=1` skips all `record` calls (useful in tests).
- No other env vars.

## What this protocol does NOT do

- Real billing. The total is a guide; the bill of record is the API console.
- Per-call breakdown. `metadata.cost` aggregates only; individual call traces are not persisted.
- Cross-ticket aggregation. Cost is per-ticket; cross-ticket sums are out of scope.
- Auto-refresh. The dev triggers `refresh-rates.sh` manually; the helper only warns when stale.
