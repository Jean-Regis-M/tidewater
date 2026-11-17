# Design notes

Why Tidewater is built the way it is, what was rejected, and what it costs. Written so a reviewer can disagree with a decision for a stated reason.

## Goal and non-goals

**Goal.** When a vault cannot pay a withdrawal, queue it fairly, and settle the queue the moment liquidity returns, without anyone running infrastructure.

**Non-goals.** Yield, a real lending strategy, price oracles, multi-asset support. The vault is deliberately minimal so the queue-and-settle mechanism is the thing under test.

## The three pieces

| Piece | Chain | Job |
|---|---|---|
| `TidewaterVault` | Base Sepolia | Holds funds, keeps the FIFO queue, pays tickets in `settle()`, emits state-carrying events |
| `TidewaterReactive` | Reactive Lasna | Subscribes to the vault's events, mirrors queue state, decides when to request a settle callback |
| Callback proxy | Base Sepolia | Reactive's delivery point; the only address the vault accepts `settle()` from |

## Decisions

### 1. Events carry state; the reactive contract never reads the chain

A reactive contract can only react to logs. It cannot call `liquidity()` on Base. So every vault event includes the numbers the reactive side needs (`pendingAfter`, `liquidityAfter`). The reactive contract keeps a **shadow copy** of `pending` and `liquidity` built purely from those logs.

*Why not a stateless trigger* ("any `LiquidityAdded` means call settle")? Each callback is paid for from the vault's prepaid reserve on the destination chain. A stateless trigger wastes callbacks when the queue is empty. The shadow state lets the reactive contract decide whether a callback is worth paying for.

*Cost.* Shadow state can drift if events are missed or reordered. Mitigations: a stale-event guard on `(blockNumber, logIndex)`, dedupe on `(chainId, txHash, logIndex)`, and `Settled` events that re-synchronise the numbers.

### 2. The queue is a doubly linked list

v1 used an array with a `head` index and skipped cancelled tickets inside `settle()`. An independent review showed that queue-and-cancel cycles could make `settle()` run out of gas, locking every queued withdrawal. Capping the skips would have kept a weaker version of the same attack.

v2 stores `prev`/`next` per ticket. Cancel unlinks in O(1); `settle()` walks only live tickets. There is nothing to skip, so the loop is bounded by `maxTickets` alone.

*Rejected:* compacting the array (unbounded gas), a heap or tree (FIFO does not need ordering structure), per-user queues (breaks global fairness).

*Cost.* Two extra storage words per ticket.

### 3. Bounded batches, and re-fire after a capped batch

`settle()` pays at most `maxTickets` (capped at `MAX_BATCH = 25`) per call so gas stays predictable. If a batch is capped while liquidity remains, the vault's `Settled` event reports `pendingAfter > 0` with `liquidityAfter > 0`, and the reactive contract fires again. In v1 this case waited for the next unrelated liquidity event.

### 4. Minimum ticket and a per-user cap

Even with O(1) cancel, a flood of dust tickets multiplies the callbacks needed to drain the queue. A minimum ticket size and a per-user open-ticket cap bound that. They are economic limits, not cryptographic ones: with many addresses an attacker can still create many tickets, but each one must lock real funds.

### 5. Failure isolation: parked payouts

A token that can refuse a transfer to one address (a blocklist) would stall the head of the queue. `settle()` pays through a non-reverting call; if it fails, the amount is parked in `owed[user]`, excluded from `liquidity()`, and the user pulls it later with `claimOwed(to)` to any address. The rest of the queue keeps moving.

### 6. Time uses timestamps, not blocks

Base Sepolia produces a block every ~200 ms, so block counts make poor timers. The reactive contract's cooldown (default 3 s) uses `block.timestamp`.

*Known gap.* If a callback is requested and never delivered, nothing retries until the cooldown expires and another liquidity event arrives. There is no heartbeat. A periodic cron subscription could add one; it was left out to keep the system minimal and its reserves predictable.

### 7. Owner powers are narrow but not zero

The owner can lend idle liquidity and change the strategy, but only while no withdrawal is queued, and can pause deposits but never exits or cancels. There is no timelock or multisig; on the deployed vault the owner and the strategy are the same wallet. This is a stated limitation, not a design endorsement.

### 8. Two funding pools, and a gotcha

A Reactive deployment needs two prepaid reserves:

- the **reactive contract** pays for each reaction on Lasna, from *reserves* credited via the system contract's `depositTo`;
- the **vault** pays for each callback on Base, from *reserves* credited via the callback proxy's `depositTo`.

Value sent with a contract's constructor becomes its **balance**, not its reserves. Until `depositTo` is called, reactions or callbacks are not paid for. `scripts/deploy.sh` performs both deposits.

## Testing strategy

- **Unit tests** per behaviour, including each finding from the v1 review as a named regression test.
- **A blocklisting token mock** to test parked payouts.
- **Fuzz test** for solvency across random repay sizes.
- **Stateful invariants** over 128,000 random calls: `pending` equals the sum of unfilled live tickets, walking the list from `head` visits exactly the live tickets in order, and the vault always holds at least `liquidity + owed`.
- **Live testnet loops** against the real callback proxy, because the proxy's behaviour (payload overwrite, delivery) is not reproducible with a mock.

## What would change for production

A timelock or multisig for owner actions, a real strategy with its own accounting, a heartbeat for lost callbacks, an audited token allowlist, and measured behaviour under chain reorgs.
