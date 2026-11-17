// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title TidewaterReactive
/// @notice Lives on Reactive Omni. Mirrors the vault's queue state from its events and, when liquidity
///         arrives while tickets are pending, requests a `settle` callback on the vault's chain.
contract TidewaterReactive is AbstractReactive {
    uint256 public immutable originChainId;
    address public owner;
    address public vault; // origin and destination
    bool public bound;

    // event topic0 hashes
    uint256 public constant T_QUEUED = uint256(keccak256("WithdrawQueued(uint256,address,uint256,uint256)"));
    uint256 public constant T_CANCELLED = uint256(keccak256("TicketCancelled(uint256,address,uint256,uint256)"));
    uint256 public constant T_LIQUIDITY = uint256(keccak256("LiquidityAdded(address,uint256,uint256,uint256)"));
    uint256 public constant T_SETTLED = uint256(keccak256("Settled(uint256,uint256,uint256,uint256,uint256)"));
    uint256 public constant T_LENT = uint256(keccak256("Lent(address,uint256,uint256)"));
    uint256 public constant T_WITHDRAWN = uint256(keccak256("Withdrawn(address,uint256,uint256)"));

    // shadow state derived purely from vault events
    uint256 public pending;
    uint256 public liquidity;
    uint256 public lastBlock;
    uint256 public lastLogIndex;

    // policy
    uint256 public minTrigger = 1; // minimum liquidity (token units) worth a callback
    uint256 public maxTickets = 10;
    uint64 public callbackGas = 1_000_000;
    uint256 public cooldown = 3; // seconds (timestamps, not blocks)
    uint256 public inflightUntil;

    mapping(bytes32 => bool) public seen;
    uint256 public callbacksRequested;
    uint256 public eventsIgnored;

    event Bound(address vault);
    event PolicyUpdated(uint256 minTrigger, uint256 maxTickets, uint64 callbackGas, uint256 cooldown);
    event Observed(uint256 indexed topic0, uint256 pending, uint256 liquidity, uint256 originBlock);
    event TriggerDecision(bool fire, string reason, uint256 pending, uint256 liquidity);
    event SettleRequested(uint256 indexed originTx, uint256 pending, uint256 liquidity, uint256 maxTickets);

    error Unauthorized();
    error AlreadyBound();
    error BadPolicy();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint256 originChainId_) payable {
        originChainId = originChainId_;
        owner = msg.sender;
    }

    /// @notice One-time: point at the deployed vault and register event subscriptions.
    function bind(address vault_) external onlyOwner {
        if (bound) revert AlreadyBound();
        bound = true;
        vault = vault_;
        uint256[6] memory ts = [T_QUEUED, T_CANCELLED, T_LIQUIDITY, T_SETTLED, T_LENT, T_WITHDRAWN];
        for (uint256 i; i < 6; i++) {
            SYSTEM.subscribe(originChainId, vault_, ts[i], REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit Bound(vault_);
    }

    function setPolicy(uint256 minTrigger_, uint256 maxTickets_, uint64 callbackGas_, uint256 cooldown_)
        external
        onlyOwner
    {
        if (maxTickets_ == 0 || maxTickets_ > 25 || callbackGas_ < 100_000 || callbackGas_ > 3_000_000 || cooldown_ > 60) {
            revert BadPolicy();
        }
        minTrigger = minTrigger_;
        maxTickets = maxTickets_;
        callbackGas = callbackGas_;
        cooldown = cooldown_;
        emit PolicyUpdated(minTrigger_, maxTickets_, callbackGas_, cooldown_);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != originChainId || log_.contractAddress != vault) {
            eventsIgnored++;
            return;
        }
        bytes32 key = keccak256(abi.encode(log_.chainId, log_.txHash, log_.logIndex));
        if (seen[key]) {
            eventsIgnored++;
            return;
        }
        seen[key] = true;

        // ignore stale/out-of-order events so shadow state never moves backwards
        if (log_.blockNumber < lastBlock || (log_.blockNumber == lastBlock && log_.logIndex < lastLogIndex)) {
            eventsIgnored++;
            return;
        }
        lastBlock = log_.blockNumber;
        lastLogIndex = log_.logIndex;

        uint256 t0 = log_.topic0;
        if (t0 == T_QUEUED || t0 == T_CANCELLED) {
            // data: (amount|remaining, pendingAfter); id and user are indexed
            (, uint256 pendingAfter) = abi.decode(log_.data, (uint256, uint256));
            pending = pendingAfter;
        } else if (t0 == T_SETTLED) {
            // data: processed, paid, pendingAfter, liquidityAfter, timestamp
            (,, uint256 pendingAfter, uint256 liquidityAfter,) =
                abi.decode(log_.data, (uint256, uint256, uint256, uint256, uint256));
            pending = pendingAfter;
            liquidity = liquidityAfter;
            inflightUntil = 0;
            emit Observed(t0, pending, liquidity, log_.blockNumber);
            _maybeFire(log_.txHash); // a capped batch can leave pending > 0 with liquidity still available
            return;
        } else if (t0 == T_LENT || t0 == T_WITHDRAWN) {
            // data: amount, liquidityAfter; indexed address omitted
            (, uint256 liquidityAfter) = abi.decode(log_.data, (uint256, uint256));
            liquidity = liquidityAfter;
        } else if (t0 == T_LIQUIDITY) {
            // data: amount, liquidityAfter, pendingNow; from is indexed
            (, uint256 liquidityAfter, uint256 pendingNow) = abi.decode(log_.data, (uint256, uint256, uint256));
            liquidity = liquidityAfter;
            pending = pendingNow;
            emit Observed(t0, pending, liquidity, log_.blockNumber);
            _maybeFire(log_.txHash);
            return;
        } else {
            eventsIgnored++;
            return;
        }
        emit Observed(t0, pending, liquidity, log_.blockNumber);
    }

    function _maybeFire(uint256 originTx) internal {
        if (pending == 0) {
            emit TriggerDecision(false, "queue empty", pending, liquidity);
            return;
        }
        if (liquidity < minTrigger) {
            emit TriggerDecision(false, "liquidity below trigger", pending, liquidity);
            return;
        }
        if (block.timestamp < inflightUntil) {
            emit TriggerDecision(false, "settle in flight", pending, liquidity);
            return;
        }
        inflightUntil = block.timestamp + cooldown;
        callbacksRequested++;
        bytes memory payload = abi.encodeWithSignature("settle(address,uint256)", address(0), maxTickets);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId, recipient: vault, gasLimit: callbackGas, payload: payload
            })
        );
        emit TriggerDecision(true, "fire", pending, liquidity);
        emit SettleRequested(originTx, pending, liquidity, maxTickets);
    }
}
