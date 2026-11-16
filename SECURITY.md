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
