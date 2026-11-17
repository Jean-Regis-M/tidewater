// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @title TidewaterVault (v2)
/// @notice Deposit vault with a first-in-first-out withdrawal queue. When the vault is illiquid
///         (assets lent to a strategy), withdrawals queue as tickets. A reactive contract on Reactive
///         Omni watches the vault's events and, the moment liquidity returns, calls `settle` through the
///         Base Sepolia callback proxy. Funds only ever go to ticket owners, in queue order.
/// @dev v2 changes after an independent adversarial review: the queue is a doubly linked list so cancel
///      and settle are O(1) per ticket and `settle` only ever visits live tickets (no skip loop to grief);
///      minimum ticket size and a per-user open-ticket cap; payouts that fail are parked for pull payment
///      instead of stalling the queue; `lend` is blocked while tickets are pending; exits are never paused.
contract TidewaterVault is AbstractCallback {
    struct Ticket {
        address owner;
        uint128 amount;
        uint128 filled;
        uint64 queuedAt;
        bool active;
        uint256 prev;
        uint256 next;
    }

    uint256 public constant NONE = type(uint256).max;
    uint256 public constant MAX_BATCH = 25;
    uint256 public constant MAX_OPEN_PER_USER = 5;

    IERC20 public immutable asset;
    uint256 public immutable minTicket;
    address public owner;
    address public strategy;
    bool public paused; // blocks deposits only; withdrawals are never paused

    mapping(address => uint256) public claims; // 1:1 deposit claims (no yield, by design)
    uint256 public totalClaims;
    Ticket[] public tickets;
    uint256 public head = NONE; // first live ticket
    uint256 public tail = NONE;
    uint256 public liveCount;
    uint256 public pending; // unfilled amount across live tickets
    mapping(address => uint256) public openTickets;
    mapping(address => uint256) public owed; // parked payouts (failed transfers), pull payment
    uint256 public totalOwed;
    uint256 private _lock = 1;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 liquidityAfter);
    event WithdrawQueued(uint256 indexed id, address indexed user, uint256 amount, uint256 pendingAfter);
    event TicketCancelled(uint256 indexed id, address indexed user, uint256 remaining, uint256 pendingAfter);
    event TicketFilled(uint256 indexed id, address indexed user, uint256 paid, bool done);
    event LiquidityAdded(address indexed from, uint256 amount, uint256 liquidityAfter, uint256 pendingNow);
    event Settled(uint256 processed, uint256 paid, uint256 pendingAfter, uint256 liquidityAfter, uint256 timestamp);
    event Lent(address indexed strategy, uint256 amount, uint256 liquidityAfter);
    event OwedParked(uint256 indexed id, address indexed user, uint256 amount);
    event OwedClaimed(address indexed user, address indexed to, uint256 amount);
    event StrategyUpdated(address indexed strategy);

    error Unauthorized();
    error Paused();
    error Reentrancy();
    error BadAmount();
    error NotTicketOwner();
    error TransferFailedErr();
    error BelowMinTicket();
    error TooManyOpenTickets();
    error QueueNotEmpty();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IERC20 asset_, IPayable callbackProxy_, address reactive_, address strategy_, uint256 minTicket_)
        AbstractCallback(callbackProxy_, reactive_)
    {
        if (strategy_ == address(0)) revert ZeroAddress();
        asset = asset_;
        owner = msg.sender;
        strategy = strategy_;
        minTicket = minTicket_;
    }

    // ---------------------------------------------------------------- views
    /// @notice Tokens available to pay now (vault balance minus parked payouts).
    function liquidity() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        return bal > totalOwed ? bal - totalOwed : 0;
    }

    function queueLength() external view returns (uint256) {
        return liveCount;
    }

    function ticketCount() external view returns (uint256) {
        return tickets.length;
    }

    // ----------------------------------------------------------- user flow
    function deposit(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (amount == 0) revert BadAmount();
        claims[msg.sender] += amount;
        totalClaims += amount;
        _pull(msg.sender, amount);
        emit Deposited(msg.sender, amount);
        emit LiquidityAdded(msg.sender, amount, liquidity(), pending);
    }

    /// @notice Withdraw now if liquid and nobody is queued ahead; otherwise take a queue ticket.
    function requestWithdraw(uint256 amount) external nonReentrant returns (uint256 ticketId) {
        if (amount == 0 || amount > type(uint128).max || claims[msg.sender] < amount) revert BadAmount();
        bool instant = pending == 0 && liquidity() >= amount;
        if (!instant) {
            if (amount < minTicket) revert BelowMinTicket();
            if (openTickets[msg.sender] >= MAX_OPEN_PER_USER) revert TooManyOpenTickets();
        }
        claims[msg.sender] -= amount;
        totalClaims -= amount;

        if (instant) {
            _push(msg.sender, amount);
            emit Withdrawn(msg.sender, amount, liquidity());
            return NONE;
        }
        ticketId = tickets.length;
        tickets.push(Ticket(msg.sender, uint128(amount), 0, uint64(block.timestamp), true, tail, NONE));
        if (tail == NONE) head = ticketId;
        else tickets[tail].next = ticketId;
        tail = ticketId;
        liveCount++;
        pending += amount;
        openTickets[msg.sender]++;
        emit WithdrawQueued(ticketId, msg.sender, amount, pending);
    }

    /// @notice Cancel a queued ticket; the unfilled remainder returns to the caller's claim. O(1).
    function cancelTicket(uint256 id) external nonReentrant {
        Ticket storage t = tickets[id];
        if (t.owner != msg.sender) revert NotTicketOwner();
        if (!t.active) revert BadAmount();
        uint256 remaining = t.amount - t.filled;
        _unlink(id);
        t.active = false;
        openTickets[msg.sender]--;
        pending -= remaining;
        claims[msg.sender] += remaining;
        totalClaims += remaining;
        emit TicketCancelled(id, msg.sender, remaining, pending);
    }

    /// @notice Pull a parked payout (one whose direct transfer failed) to any address.
    function claimOwed(address to) external nonReentrant {
        uint256 amt = owed[msg.sender];
        if (amt == 0 || to == address(0)) revert BadAmount();
        owed[msg.sender] = 0;
        totalOwed -= amt;
        _push(to, amt);
        emit OwedClaimed(msg.sender, to, amt);
    }

    // ------------------------------------------------- reactive callback
    /// @notice Settles queued tickets FIFO from live liquidity. Only the callback proxy may call, and
    ///         only on behalf of the authorised reactive contract. Visits live tickets only, bounded by
    ///         `maxTickets` (capped at MAX_BATCH). Safe to call repeatedly (no-op when nothing is payable).
    function settle(address reactive_, uint256 maxTickets)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
        nonReentrant
    {
        uint256 cap = maxTickets > MAX_BATCH ? MAX_BATCH : maxTickets;
        uint256 avail = liquidity();
        uint256 processed;
        uint256 paidTotal;
        uint256 i = head;
        while (i != NONE && processed < cap) {
            Ticket storage t = tickets[i];
            uint256 rem = t.amount - t.filled;
            uint256 pay = rem > avail ? avail : rem;
            if (pay == 0) break;
            t.filled += uint128(pay);
            avail -= pay;
            pending -= pay;
            paidTotal += pay;
            processed++;
            bool done = t.filled == t.amount;
            address who = t.owner;
            uint256 nxt = t.next;
            if (done) {
                _unlink(i);
                t.active = false;
                openTickets[who]--;
            }
            if (!_tryPush(who, pay)) {
                owed[who] += pay;
                totalOwed += pay;
                emit OwedParked(i, who, pay);
            }
            emit TicketFilled(i, who, pay, done);
            if (!done) break; // out of liquidity
            i = nxt;
        }
        emit Settled(processed, paidTotal, pending, liquidity(), block.timestamp);
    }

    // --------------------------------------------------- strategy / admin
    /// @notice Owner moves idle assets to the strategy. Blocked while any withdrawal is queued.
    function lend(uint256 amount) external onlyOwner nonReentrant {
        if (pending != 0) revert QueueNotEmpty();
        if (amount == 0 || amount > liquidity()) revert BadAmount();
        _push(strategy, amount);
        emit Lent(strategy, amount, liquidity());
    }

    /// @notice Anyone (normally the strategy) returns liquidity. Does not mint claims.
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadAmount();
        _pull(msg.sender, amount);
        emit LiquidityAdded(msg.sender, amount, liquidity(), pending);
    }

    /// @notice Pauses new deposits only. Withdrawals and cancels are never paused.
    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    function setStrategy(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        if (pending != 0) revert QueueNotEmpty();
        strategy = s;
        emit StrategyUpdated(s);
    }

    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------ internal
    function _unlink(uint256 id) internal {
        Ticket storage t = tickets[id];
        if (t.prev == NONE) head = t.next;
        else tickets[t.prev].next = t.next;
        if (t.next == NONE) tail = t.prev;
        else tickets[t.next].prev = t.prev;
        liveCount--;
    }

    function _pull(address from, uint256 amount) internal {
        if (!asset.transferFrom(from, address(this), amount)) revert TransferFailedErr();
    }

    function _push(address to, uint256 amount) internal {
        if (!asset.transfer(to, amount)) revert TransferFailedErr();
    }

    /// @dev Non-reverting payout used inside `settle` so one failing recipient cannot stall the queue.
    function _tryPush(address to, uint256 amount) internal returns (bool ok) {
        try asset.transfer(to, amount) returns (bool r) {
            ok = r;
        } catch {
            ok = false;
        }
    }
}
