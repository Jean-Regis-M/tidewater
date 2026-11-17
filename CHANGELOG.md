# Changelog

## v2.0 (2026-11-17)

Redeployed after an independent adversarial review of v1 found real problems. Each fix has a regression test.

**Fixed**
- **High:** `settle()` could be bricked by queueing and cancelling hundreds of dust tickets (skipped tickets did not count toward the batch cap). The queue is now a doubly linked list; `settle()` only visits live tickets.
- The reactive contract now re-fires after a `Settled` event that leaves work behind, instead of waiting for the next liquidity event.
- Minimum ticket size and a per-user open-ticket cap against dust tickets.
- `lend` and `setStrategy` are blocked while any withdrawal is queued; pausing blocks deposits only, never exits.
- A failing payout is parked for pull payment (`claimOwed`) instead of stalling the queue.
- `uint128` truncation guard; bounded `setPolicy`; `Lent` and `Withdrawn` carry `liquidityAfter` and are subscribed so the reactive shadow liquidity stays accurate.

**Evidence**
- 20 of 20 live loops on the new contracts, with Base, Lasna and Base hashes; median 1.4 s origin block to queue paid.
- 34 tests including stateful invariants.
- Contract source verified on Blockscout (Base Sepolia) and Sourcify (Lasna, exact match).
- Latency compared against a polling keeper running the same vault code (see `docs/MEASUREMENT.md`).

**Deployments**
- Vault `0xc7B06Bf2e5c6Fbc7817631DB81842Ee3c6Df61aD` (Base Sepolia), reactive `0xe7B2A395E352b3a9c7Af5DC249CbB46243b092F4` (Lasna). Token unchanged.

## v1.0 (2026-11-17), superseded

First deployment: vault `0x7cF8C75c98b8ffFA1707CDB35e739C846C6000dd`, reactive `0xde9cAF1626f5680c2d7961ca4fd1638D3c4a1885`. Six live loops. Archived under `deployments/v1/`. Do not use: it contains the griefing vulnerability above.
