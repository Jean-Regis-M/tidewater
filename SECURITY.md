# Security notes

Prototype, testnet only, **not audited**.

## Tooling run

- `forge test`: 22 tests (access control, FIFO and partial fills, cancellation, duplicate/stale/foreign events, cooldown, fuzzed solvency).
- Slither 0.11.6 on `src/` (dependencies and tests excluded).

## Slither findings and disposition

| Finding | Severity | Disposition |
|---|---|---|
| `reentrancy-no-eth` in `settle` (state written after token transfer) | Medium (as reported) | Mitigated: every state-changing vault function uses a shared mutex, so cross-function reentry is blocked. Left as is to keep deployed evidence valid; would reorder writes in a v2. |
| `incorrect-equality` (`pay == 0`, `filled == amount`) | Medium (as reported) | False positive in context: exact comparisons on ticket accounting that only the contract mutates, not on a balance an attacker can inflate. |
| `uninitialized-local` (`processed`, `paidTotal`) | Medium (as reported) | False positive: Solidity zero-initialises locals, and zero is the intended start. |
| `missing-zero-check` on `bind`, `setStrategy`, constructor | Low | Owner-only; accepted for a prototype. |
| `events-maths` (`setPolicy` emits no event) | Low | Accepted; add `PolicyUpdated` in v2. |
| `calls-loop`, `reentrancy-events`, `timestamp` | Low | Loop bounded by `maxTickets`; events ordering covered by the mutex; timestamp used deliberately for the cooldown (Base blocks are ~200 ms). |
| `costly-loop`, `unindexed-event-address`, `immutable-states` | Informational / Optimization | Accepted. |

No High findings. Counts: 3 Medium, 6 Low, 4 Informational/Optimization.

## Design-level risks

1. **Blocking asset:** a token that reverts transfers to a particular ticket owner stalls the queue head. Mitigation planned: skip-and-park failed tickets.
2. **Stranded liquidity under cooldown:** see README.
3. **Trust in the callback proxy and system contract** is inherited from Reactive Network.
4. **Test token** has an open mint by design and must never be used outside testnets.
5. **Funding:** if callback reserves on the destination proxy run out, settlement callbacks stop until topped up.

## Independent adversarial review (v1 deployment)

An independent reviewer with no prior knowledge of the project read the code and wrote extra Foundry tests against it (mock system contract; not run against the real proxy). Core FIFO accounting held: random deposit/withdraw/cancel/lend/repay/settle sequences (256 runs of 500 calls) kept vault balance, `pending` and `head` consistent, and real event logs decoded correctly in the reactive contract. The following issues were **reproduced and are present in the deployed v1 contracts**:

| Severity | Issue | Impact | Fix (not yet deployed) |
|---|---|---|---|
| High (liveness) | Cancelled or already-filled tickets are skipped without counting toward `maxTickets`, and `head` is written only after the loop. | An attacker can queue and cancel hundreds of dust tickets at their own gas cost until `settle` runs out of gas; every retry fails and real tickets are never paid. | Count skips toward the cap, write `head` before bailing out, advance `head` in `cancelTicket`, add a minimum ticket size and a per-user open-ticket cap. |
| Medium-High | The reactive contract does not re-fire after a `Settled` event that leaves `pending > 0` and liquidity available. | With more than `maxTickets` tickets, the rest wait for the next `LiquidityAdded` event instead of settling immediately. | Call the trigger check after `Settled`. |
| Medium | Dust tickets multiply the number of settle callbacks needed. | Slows or stalls the queue (compounds the two items above). | Minimum ticket amount. |
| Medium | Owner can `lend` without a cap or pending-aware guard, repoint `setStrategy`, and `setPaused` blocks new withdrawals. | Owner can move queue liquidity to itself or freeze exits. Owner and strategy are the same EOA on the deployed vault. | Timelock or multisig, lending cap, block `lend` while `pending > 0`. |
| Low | `uint128` truncation of ticket amounts. | Unreachable with a sane token supply; reachable with the open-mint test token. | `SafeCast`. |

Reasoned but not reproduced: a blocklisting token can stall the queue head; the shadow `liquidity` ignores `Lent`/`Withdrawn`/donations (may cause harmless extra callbacks); `setPolicy` has no bounds.

This is a testnet prototype with a test token. These findings are disclosed so reviewers can weigh them; they would need fixing before any real funds.
