# How latency was measured

A latency number is only worth as much as its method. This page states exactly what was measured, how, and what it does not tell you.

## The loop

One loop is the full path from the user-visible trigger to the user being paid:

1. **Origin event (Base Sepolia).** `repay()` returns liquidity to an illiquid vault with a withdrawal queued; the vault emits `LiquidityAdded`.
2. **Reaction (Reactive Lasna).** The reactive contract receives the log, updates its shadow state, and requests a callback (`SettleRequested`).
3. **Settlement (Base Sepolia).** The callback proxy calls `settle()`; the vault pays the ticket and emits `Settled`.

## Primary metric: on-chain, from block timestamps

For each loop, the gap between **the block containing the origin transaction** and **the block containing the settle transaction**, using the `timestampMs` field of Base Sepolia blocks (millisecond precision; blocks are about 200 ms apart).

- Computed by [`scripts/measure_onchain.py`](../scripts/measure_onchain.py) from public RPC data. Anyone can recompute it from the transaction hashes in the README.
- It does not depend on the measuring machine's network speed or polling interval.
- Granularity is one Base block (about 200 ms), so differences smaller than that are not meaningful.

## Secondary metric: client-polled

`scripts/live_loop.sh` also records how long after the `repay` receipt returned a polling client first saw `pending()` drop. It is noisier (about 0.25 s polling plus RPC time) and is kept only as a cross-check.

## What is deliberately not reported

- **A per-hop split (Base to Lasna to Base).** Lasna block timestamps are whole seconds, so any split would be rounding noise. An earlier attempt produced negative durations, which is why it was dropped.
- **Reactive's block time as "the latency".** The advertised block time is not the end-to-end time; the number above is the whole loop.

## The keeper baseline

To test whether the Reactive path is actually worth using, the same loops were run with a conventional polling keeper as the settler.

- **Same vault code.** A second `TidewaterVault` is deployed with the keeper address as the authorised caller in place of the Reactive callback proxy. Nothing else differs.
- **The keeper** ([`baseline/keeper.mjs`](../baseline/keeper.mjs)) polls `pending()` and `liquidity()` every N ms and sends `settle()` when both are non-zero. It uses a fixed gas limit and 100 ms receipt polling. It is a reasonably tuned keeper, not an adversarially fast one.
- **Best case for the keeper.** It runs on the same laptop as the load generator and uses the same public RPC, so network distance is minimal.
- **Two poll intervals** (1000 ms and 250 ms), 20 loops each.
- **The outage test** ([`scripts/keeper_outage.sh`](../scripts/keeper_outage.sh)) stops the keeper, returns liquidity, and observes whether anything settles the queue, then restarts the keeper and times the recovery. It is a single observation.

## Data integrity note

A first attempt at the 250 ms run and at the outage test was **discarded**. A keeper process from an earlier run was still alive (stopping it with a saved shell PID only killed the wrapper, not the node process), so the 250 ms run was effectively "best of two keepers" and a supposed outage was settled within 2.7 s by the stray process. The problem was noticed because the outage result was impossible. All keeper processes were stopped by matching their command line (`baseline/stop-keepers.ps1`), the outage script now refuses to run if any keeper is already running, and both experiments were rerun with exactly one keeper confirmed. The 1000 ms run was unaffected: it was the only keeper running when it was measured.

## The 281-second outlier

In the clean 250 ms run, loop 12 settled 1,406 Base blocks (about 281 s) after its origin block. The keeper was polling the whole time (about a thousand polls) but did not see a queue until reads recovered, during the same minutes in which the public RPC returned an HTTP error and the measuring script's own `pending()` reads stalled. The script timed out and recorded the loop as unsettled, so its settle transaction was reconstructed from chain data (the first `Settled` event after the origin block) and flagged with a `note` in `deployments/baseline-poll250.jsonl`. The loop is **included** in the statistics; it is why that row's p95 is 3.0 s and its maximum 281.2 s. The probable cause is stale reads from the load-balanced public RPC, which was not proven.

## Limits of these results

- One machine, public RPCs, one scenario repeated. Not a benchmark of Reactive's capacity or of other networks.
- 20 loops per configuration is enough to show the shape, not tight confidence intervals.
- The keeper baseline is single-chain. A keeper watching several chains would need more infrastructure, and that case was not built or measured.
- Results can vary with RPC load and testnet conditions.

## Reproduce

```bash
python scripts/measure_onchain.py deployments/measurements.jsonl          # Reactive loops
python scripts/measure_onchain.py deployments/baseline-poll250.jsonl      # keeper loops
python scripts/compare_latency.py                                         # side-by-side table
```
