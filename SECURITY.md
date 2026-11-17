# Security notes

Prototype, testnet only, **not audited**.

## Tooling run on v2

- `forge test`: 34 tests. Unit tests for access control, FIFO and partial fills, cancellation, duplicate/stale/foreign events, cooldown and re-fire; a fuzz solvency test; and three stateful invariants checked over 256 runs of 500 random calls (128,000 calls) across deposit, withdraw, cancel, lend, repay and settle.
- Slither 0.11.6 on `src/` (dependencies and tests excluded): **no High findings**. 20 results in total: 5 Medium, 7 Low and 8 Informational/Optimization. The Medium ones are the same three classes as before (`incorrect-equality` on exact integer ticket accounting, `uninitialized-local` for counters that intentionally start at zero, and `reentrancy-no-eth` for state written after a token transfer inside `settle`). They are false positives or mitigated by the shared mutex on every state-changing function.
- An independent adversarial review of the v1 contracts (below), run by a reviewer with no prior knowledge of the project.

## Independent adversarial review of v1, and what v2 changed

The reviewer read the v1 code, wrote extra Foundry tests against a mock system contract (not the real proxy) and reproduced the following. All were **present in the first deployment** and are **fixed in v2**, with a regression test for each.

| Severity | v1 issue | v2 fix | Test |
|---|---|---|---|
| High (liveness) | Cancelled or filled tickets were skipped without counting toward `maxTickets`, and `head` was written after the loop. About 600 queue-and-cancel cycles made `settle` run out of gas on every retry, locking all queued funds. | Queue is a doubly linked list. Cancel unlinks in O(1); `settle` visits only live tickets, bounded by `maxTickets` (capped at `MAX_BATCH`). | `test_queueCancelGriefingCannotBrickSettle` (600 cancelled dust tickets, settle uses under 200k gas and pays the real ticket) |
| Medium-High | The reactive contract did not re-fire after a `Settled` event that left `pending > 0` with liquidity still available. | It re-evaluates the trigger after every `Settled`. | `test_refiresAfterCappedBatch` |
| Medium | Dust tickets multiplied the callbacks needed. | Minimum ticket size and a per-user open-ticket cap. | `test_minTicketAndOpenCap` |
| Medium | Owner could `lend` with no pending-aware guard, repoint the strategy, and pause withdrawals. | `lend` and `setStrategy` revert while any withdrawal is queued; pausing blocks deposits only, never exits or cancels. | `test_lendBlockedWhilePending`, `test_pauseDoesNotBlockExits` |
| Low | `uint128` truncation of ticket amounts. | Amounts above `uint128` max are rejected. | `test_uint128GuardOnWithdraw` |
| Suspected | A blocklisting token could stall the queue head. | A failing payout is parked in `owed` and pulled later with `claimOwed(to)`; the queue keeps moving and parked funds are excluded from `liquidity()`. | `test_blockedRecipientDoesNotStallQueue` |
| Suspected | Shadow `liquidity` ignored `Lent` and `Withdrawn`. | Both events now carry `liquidityAfter` and are subscribed. | `test_lentAndWithdrawnUpdateShadowLiquidity` |
| Suspected | `setPolicy` had no bounds. | `maxTickets` 1 to 25, `callbackGas` 100k to 3M, `cooldown` up to 60 s. | `test_setPolicyBounds` |

What held in v1 and still holds: the FIFO accounting, event decoding in the reactive contract, callback authentication, and cancel-then-settle without double payment.

## Design-level risks that remain

1. **Owner trust.** The owner can still lend idle liquidity while the queue is empty and repoint the strategy under the same condition. There is no timelock or multisig. On the deployed vault the owner and the strategy are the same wallet.
2. **Real proxy behaviour.** The adversarial tests used mocks. The live loops on testnet show the real proxy delivering `settle` correctly, but payload-overwrite and ordering edge cases were not independently fuzzed against the real system contract.
3. **Lost callback.** If a settle callback never arrives, the cooldown expires and the next liquidity event retriggers; there is no periodic heartbeat.
4. **Trust in the callback proxy and system contract** is inherited from Reactive Network.
5. **Test token** has an open mint by design and must never be used outside testnets.
6. **Funding.** If callback reserves on the destination proxy run out, settlement callbacks stop until topped up.

These notes exist so reviewers can weigh the project accurately. Do not use it with real funds.
