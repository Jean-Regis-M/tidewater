// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @title TidewaterVault
/// @notice Deposit vault with a first-in-first-out withdrawal queue. When the vault is illiquid
///         (assets lent to a strategy), withdrawals queue as tickets. A reactive contract on Reactive
///         Omni watches the vault's events and, the moment liquidity returns, calls `settle` through the
///         Base Sepolia callback proxy. Funds only ever go to ticket owners, in queue order.
contract TidewaterVault is AbstractCallback {
    struct Ticket {
        address owner;
        uint128 amount;
        uint128 filled;
        uint64 queuedAt;
        bool cancelled;
    }

    IERC20 public immutable asset;
    address public owner;
    address public strategy;
    bool public paused;

    mapping(address => uint256) public claims; // 1:1 deposit claims (no yield, by design)
    uint256 public totalClaims;
    Ticket[] public tickets;
    uint256 public head; // first ticket that may still be unfilled
    uint256 public pending; // unfilled amount across live tickets
    uint256 private _lock = 1;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event WithdrawQueued(uint256 indexed id, address indexed user, uint256 amount, uint256 pendingAfter);
    event TicketCancelled(uint256 indexed id, address indexed user, uint256 remaining, uint256 pendingAfter);
    event TicketFilled(uint256 indexed id, address indexed user, uint256 paid, bool done);
    event LiquidityAdded(address indexed from, uint256 amount, uint256 liquidityAfter, uint256 pendingNow);
    event Settled(uint256 processed, uint256 paid, uint256 pendingAfter, uint256 liquidityAfter, uint256 timestamp);
    event Lent(address indexed strategy, uint256 amount);

    error Unauthorized();
    error Paused();
    error Reentrancy();
    error BadAmount();
    error NotTicketOwner();
    error TransferFailedErr();

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

    constructor(IERC20 asset_, IPayable callbackProxy_, address reactive_, address strategy_)
        AbstractCallback(callbackProxy_, reactive_)
    {
        asset = asset_;
        owner = msg.sender;
        strategy = strategy_;
    }

    // ---------------------------------------------------------------- views
    function liquidity() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function queueLength() external view returns (uint256) {
        return tickets.length - head;
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
        if (paused) revert Paused();
        if (amount == 0 || claims[msg.sender] < amount) revert BadAmount();
        claims[msg.sender] -= amount;
        totalClaims -= amount;

        if (pending == 0 && liquidity() >= amount) {
            _push(msg.sender, amount);
            emit Withdrawn(msg.sender, amount);
            return type(uint256).max;
        }
        ticketId = tickets.length;
        tickets.push(Ticket(msg.sender, uint128(amount), 0, uint64(block.timestamp), false));
        pending += amount;
        emit WithdrawQueued(ticketId, msg.sender, amount, pending);
    }

    /// @notice Cancel a queued ticket; the unfilled remainder returns to the caller's claim.
    function cancelTicket(uint256 id) external nonReentrant {
        Ticket storage t = tickets[id];
        if (t.owner != msg.sender) revert NotTicketOwner();
        if (t.cancelled || t.filled == t.amount) revert BadAmount();
        uint256 remaining = t.amount - t.filled;
        t.cancelled = true;
        pending -= remaining;
        claims[msg.sender] += remaining;
        totalClaims += remaining;
        emit TicketCancelled(id, msg.sender, remaining, pending);
    }

    // ------------------------------------------------- reactive callback
    /// @notice Settles queued tickets FIFO from live liquidity. Only the callback proxy may call, and
    ///         only on behalf of the authorised reactive contract. Safe to call repeatedly (no-op when
    ///         nothing is payable).
    function settle(address reactive_, uint256 maxTickets)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
        nonReentrant
    {
        uint256 avail = liquidity();
        uint256 processed;
        uint256 paidTotal;
        uint256 i = head;
        uint256 n = tickets.length;
        while (i < n && processed < maxTickets) {
            Ticket storage t = tickets[i];
            if (t.cancelled || t.filled == t.amount) {
                i++;
                continue;
            }
            uint256 pay = t.amount - t.filled;
            if (pay > avail) pay = avail;
            if (pay == 0) break;
            t.filled += uint128(pay);
            avail -= pay;
            pending -= pay;
            paidTotal += pay;
            processed++;
            bool done = t.filled == t.amount;
            _push(t.owner, pay);
            emit TicketFilled(i, t.owner, pay, done);
            if (!done) break; // out of liquidity
            i++;
        }
        head = i;
        emit Settled(processed, paidTotal, pending, liquidity(), block.timestamp);
    }

    // --------------------------------------------------- strategy / admin
    /// @notice Owner moves idle assets to the strategy (simulates assets put to work), making the vault illiquid.
    function lend(uint256 amount) external onlyOwner nonReentrant {
        _push(strategy, amount);
        emit Lent(strategy, amount);
    }

    /// @notice Anyone (normally the strategy) returns liquidity. Does not mint claims.
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadAmount();
        _pull(msg.sender, amount);
        emit LiquidityAdded(msg.sender, amount, liquidity(), pending);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    function setStrategy(address s) external onlyOwner {
        strategy = s;
    }

    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------ internal
    function _pull(address from, uint256 amount) internal {
        if (!asset.transferFrom(from, address(this), amount)) revert TransferFailedErr();
    }

    function _push(address to, uint256 amount) internal {
        if (!asset.transfer(to, amount)) revert TransferFailedErr();
    }
}
