// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {TideToken} from "../src/TideToken.sol";
import {TidewaterVault, IERC20} from "../src/TidewaterVault.sol";
import {TidewaterReactive} from "../src/TidewaterReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// Minimal stand-in for the Reactive system contract: records subscriptions and callback requests.
contract MockSystem {
    uint256 public subs;
    uint256 public cbCount;
    ISystemContract.CallbackConfiguration_V_1_0 public last;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subs++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        cbCount++;
        last = c;
    }

    function lastPayload() external view returns (bytes memory) {
        return last.payload;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// ERC-20 that can refuse transfers to a blocked address (models a blocklisting token such as USDC).
contract BlockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function block_(address a) external {
        blocked[a] = true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(!blocked[to], "blocked");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract TidewaterTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant CHAIN = 84532;
    uint256 constant MIN = 1e6;
    address proxy = address(0xB0B0);
    address strategy = address(0x57A7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    TideToken token;
    TidewaterVault vault;
    TidewaterReactive rx;
    MockSystem sys;

    function setUp() public virtual {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        token = new TideToken();
        rx = new TidewaterReactive(CHAIN);
        vault = new TidewaterVault(IERC20(address(token)), IPayable(payable(proxy)), address(rx), strategy, MIN);
        rx.bind(address(vault));
        token.mint(alice, 1_000_000e6);
        token.mint(bob, 1_000_000e6);
        token.mint(strategy, 1_000_000e6);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(strategy);
        token.approve(address(vault), type(uint256).max);
    }

    // ---- helpers
    function _settle(uint256 max) internal {
        vm.prank(proxy);
        vault.settle(address(rx), max);
    }

    function _log(bytes32 sig, bytes memory data, uint256 txh, uint256 idx, uint256 blk)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord(CHAIN, address(vault), uint256(sig), 0, 0, 0, data, blk, 1, 0, txh, idx);
    }

    function _liquidityLog(uint256 amt, uint256 liq, uint256 pend, uint256 txh, uint256 blk)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return _log(
            keccak256("LiquidityAdded(address,uint256,uint256,uint256)"), abi.encode(amt, liq, pend), txh, 0, blk
        );
    }

    function _illiquid() internal {
        vm.prank(alice);
        vault.deposit(100e6);
        vault.lend(100e6);
    }

    // ---- vault
    function test_instantWithdrawWhenLiquid() public {
        vm.startPrank(alice);
        vault.deposit(100e6);
        uint256 id = vault.requestWithdraw(40e6);
        vm.stopPrank();
        assertEq(id, type(uint256).max);
        assertEq(token.balanceOf(alice), 1_000_000e6 - 60e6);
        assertEq(vault.pending(), 0);
    }

    function test_queuesWhenIlliquid() public {
        _illiquid();
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(60e6);
        assertEq(id, 0);
        assertEq(vault.pending(), 60e6);
        assertEq(vault.queueLength(), 1);
        assertEq(vault.head(), 0);
    }

    function test_settleFifoPartialThenFull() public {
        vm.prank(alice);
        vault.deposit(100e6);
        vm.prank(bob);
        vault.deposit(100e6);
        vault.lend(200e6);
        vm.prank(alice);
        vault.requestWithdraw(100e6);
        vm.prank(bob);
        vault.requestWithdraw(100e6);

        vm.prank(strategy);
        vault.repay(150e6);
        _settle(10);
        assertEq(token.balanceOf(alice), 1_000_000e6); // alice fully paid first
        assertEq(token.balanceOf(bob), 1_000_000e6 - 100e6 + 50e6); // bob partial
        assertEq(vault.pending(), 50e6);
        assertEq(vault.queueLength(), 1);

        vm.prank(strategy);
        vault.repay(50e6);
        _settle(10);
        assertEq(token.balanceOf(bob), 1_000_000e6);
        assertEq(vault.pending(), 0);
        assertEq(vault.queueLength(), 0);
        assertEq(vault.head(), vault.NONE());
    }

    function test_settleOnlyProxy() public {
        vm.expectRevert();
        vault.settle(address(rx), 5);
    }

    function test_settleRejectsWrongReactiveSender() public {
        vm.prank(proxy);
        vm.expectRevert();
        vault.settle(address(0xBAD), 5);
    }

    function test_settleNoopWhenEmpty() public {
        _settle(5);
        assertEq(vault.pending(), 0);
    }

    function test_cancelReturnsClaim() public {
        _illiquid();
        vm.startPrank(alice);
        vault.requestWithdraw(60e6);
        vault.cancelTicket(0);
        vm.stopPrank();
        assertEq(vault.pending(), 0);
        assertEq(vault.claims(alice), 100e6);
        assertEq(vault.queueLength(), 0);
        _settle(5);
        assertEq(token.balanceOf(alice), 1_000_000e6 - 100e6); // cancelled ticket never paid
    }

    function test_cannotCancelOthersTicket() public {
        _illiquid();
        vm.prank(alice);
        vault.requestWithdraw(60e6);
        vm.prank(bob);
        vm.expectRevert(TidewaterVault.NotTicketOwner.selector);
        vault.cancelTicket(0);
    }

    function test_cannotCancelTwice() public {
        _illiquid();
        vm.startPrank(alice);
        vault.requestWithdraw(60e6);
        vault.cancelTicket(0);
        vm.expectRevert(TidewaterVault.BadAmount.selector);
        vault.cancelTicket(0);
        vm.stopPrank();
    }

    function test_cannotWithdrawMoreThanClaim() public {
        vm.prank(alice);
        vault.deposit(10e6);
        vm.prank(alice);
        vm.expectRevert(TidewaterVault.BadAmount.selector);
        vault.requestWithdraw(11e6);
    }

    function test_lendOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(TidewaterVault.Unauthorized.selector);
        vault.lend(1);
    }

    function test_maxTicketsBoundsBatch() public {
        _illiquid();
        for (uint256 i; i < 3; i++) {
            vm.prank(alice);
            vault.requestWithdraw(10e6);
        }
        vm.prank(strategy);
        vault.repay(100e6);
        _settle(2);
        assertEq(vault.pending(), 10e6); // third ticket left for next call
        assertEq(vault.queueLength(), 1);
        _settle(2);
        assertEq(vault.pending(), 0);
    }

    function test_cancelMiddleTicketKeepsOrder() public {
        vm.prank(alice);
        vault.deposit(300e6);
        vault.lend(300e6);
        vm.startPrank(alice);
        vault.requestWithdraw(10e6); // 0
        vault.requestWithdraw(20e6); // 1
        vault.requestWithdraw(30e6); // 2
        vault.cancelTicket(1);
        vm.stopPrank();
        assertEq(vault.queueLength(), 2);
        vm.prank(strategy);
        vault.repay(10e6);
        _settle(10); // pays ticket 0 only, ticket 2 still waits
        assertEq(vault.head(), 2);
        assertEq(vault.pending(), 30e6);
    }

    // ---- v2: review fixes
    function test_minTicketAndOpenCap() public {
        _illiquid();
        vm.startPrank(alice);
        vm.expectRevert(TidewaterVault.BelowMinTicket.selector);
        vault.requestWithdraw(MIN - 1);
        for (uint256 i; i < 5; i++) {
            vault.requestWithdraw(MIN);
        }
        vm.expectRevert(TidewaterVault.TooManyOpenTickets.selector);
        vault.requestWithdraw(MIN);
        vault.cancelTicket(0); // frees a slot
        vault.requestWithdraw(MIN);
        vm.stopPrank();
    }

    /// Reviewer attack: queue+cancel many dust tickets so settle must skip them. Linked list makes it O(live).
    function test_queueCancelGriefingCannotBrickSettle() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vault.lend(10_000e6);
        vm.startPrank(alice);
        for (uint256 i; i < 600; i++) {
            uint256 id = vault.requestWithdraw(MIN);
            vault.cancelTicket(id);
        }
        vault.requestWithdraw(50e6); // the one real ticket
        vm.stopPrank();
        vm.prank(strategy);
        vault.repay(60e6);
        uint256 g = gasleft();
        _settle(10);
        uint256 used = g - gasleft();
        assertLt(used, 200_000);
        assertEq(vault.pending(), 0);
        assertEq(vault.queueLength(), 0);
    }

    function test_lendBlockedWhilePending() public {
        _illiquid();
        vm.prank(alice);
        vault.requestWithdraw(10e6);
        vm.prank(strategy);
        vault.repay(5e6);
        vm.expectRevert(TidewaterVault.QueueNotEmpty.selector);
        vault.lend(5e6);
        vm.expectRevert(TidewaterVault.QueueNotEmpty.selector);
        vault.setStrategy(address(0x1234));
    }

    function test_pauseDoesNotBlockExits() public {
        _illiquid();
        vault.setPaused(true);
        vm.prank(alice);
        vault.requestWithdraw(10e6); // still allowed
        vm.prank(bob);
        vm.expectRevert(TidewaterVault.Paused.selector);
        vault.deposit(1e6);
        vm.prank(alice);
        vault.cancelTicket(0);
    }

    function test_uint128GuardOnWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(TidewaterVault.BadAmount.selector);
        vault.requestWithdraw(uint256(type(uint128).max) + 1);
    }

    function test_setPolicyBounds() public {
        vm.expectRevert(TidewaterReactive.BadPolicy.selector);
        rx.setPolicy(1, 0, 1_000_000, 3);
        vm.expectRevert(TidewaterReactive.BadPolicy.selector);
        rx.setPolicy(1, 26, 1_000_000, 3);
        vm.expectRevert(TidewaterReactive.BadPolicy.selector);
        rx.setPolicy(1, 10, 99_999, 3);
        rx.setPolicy(1, 10, 1_000_000, 3);
    }

    // ---- blocklisting token: failed payout is parked, queue keeps moving
    function test_blockedRecipientDoesNotStallQueue() public {
        BlockToken bt = new BlockToken();
        TidewaterReactive r2 = new TidewaterReactive(CHAIN);
        TidewaterVault v2 =
            new TidewaterVault(IERC20(address(bt)), IPayable(payable(proxy)), address(r2), strategy, MIN);
        bt.mint(alice, 1000e6);
        bt.mint(bob, 1000e6);
        bt.mint(strategy, 1000e6);
        vm.prank(alice);
        bt.approve(address(v2), type(uint256).max);
        vm.prank(bob);
        bt.approve(address(v2), type(uint256).max);
        vm.prank(strategy);
        bt.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.deposit(100e6);
        vm.prank(bob);
        v2.deposit(100e6);
        v2.lend(200e6);
        vm.prank(alice);
        v2.requestWithdraw(100e6); // ticket 0
        vm.prank(bob);
        v2.requestWithdraw(100e6); // ticket 1
        bt.block_(alice); // alice becomes blocklisted
        vm.prank(strategy);
        v2.repay(200e6);
        vm.prank(proxy);
        v2.settle(address(r2), 10);
        assertEq(v2.pending(), 0);
        assertEq(bt.balanceOf(bob), 1000e6); // bob paid despite alice being blocked ahead of him
        assertEq(v2.owed(alice), 100e6); // alice's payout parked
        assertEq(v2.liquidity(), 0); // parked funds are not liquidity
        vm.prank(alice);
        v2.claimOwed(address(0xFEED)); // alice pulls to a different address
        assertEq(bt.balanceOf(address(0xFEED)), 100e6);
        assertEq(v2.owed(alice), 0);
    }

    // ---- reactive
    function test_bindSubscribesSixTopics() public view {
        assertEq(sys.subs(), 6);
    }

    function test_bindOnlyOnce() public {
        vm.expectRevert(TidewaterReactive.AlreadyBound.selector);
        rx.bind(address(vault));
    }

    function test_reactOnlySystem() public {
        vm.expectRevert();
        rx.react(_liquidityLog(1, 1, 1, 1, 1));
    }

    function test_firesCallbackWhenLiquidityAndPending() public {
        bytes32 q = keccak256("WithdrawQueued(uint256,address,uint256,uint256)");
        vm.startPrank(SYSTEM);
        rx.react(_log(q, abi.encode(uint256(60e6), uint256(60e6)), 1, 0, 10));
        assertEq(rx.pending(), 60e6);
        rx.react(_liquidityLog(100e6, 100e6, 60e6, 2, 11));
        vm.stopPrank();
        assertEq(sys.cbCount(), 1);
        assertEq(sys.lastPayload().length, 4 + 64);
        (uint256 cid, address recipient,,) = sys.last();
        assertEq(cid, CHAIN);
        assertEq(recipient, address(vault));
    }

    function test_noCallbackWhenQueueEmpty() public {
        vm.prank(SYSTEM);
        rx.react(_liquidityLog(100e6, 100e6, 0, 1, 10));
        assertEq(sys.cbCount(), 0);
    }

    function test_duplicateEventIgnored() public {
        vm.startPrank(SYSTEM);
        rx.react(_liquidityLog(100e6, 100e6, 60e6, 7, 10));
        vm.warp(block.timestamp + 100);
        rx.react(_liquidityLog(100e6, 100e6, 60e6, 7, 10));
        vm.stopPrank();
        assertEq(sys.cbCount(), 1);
        assertEq(rx.eventsIgnored(), 1);
    }

    function test_staleEventIgnored() public {
        vm.startPrank(SYSTEM);
        rx.react(_liquidityLog(1e6, 1e6, 5e6, 1, 20));
        rx.react(_liquidityLog(9e6, 9e6, 0, 2, 19)); // older block
        vm.stopPrank();
        assertEq(rx.pending(), 5e6);
        assertEq(rx.eventsIgnored(), 1);
    }

    function test_cooldownSuppressesBurstThenSettledReopens() public {
        vm.startPrank(SYSTEM);
        rx.react(_liquidityLog(5e6, 5e6, 50e6, 1, 10));
        rx.react(_liquidityLog(5e6, 10e6, 50e6, 2, 11));
        assertEq(sys.cbCount(), 1); // second suppressed: in flight
        // Settled with nothing left to pay (liquidity 0) -> no refire, but inflight cleared
        rx.react(
            _log(
                keccak256("Settled(uint256,uint256,uint256,uint256,uint256)"),
                abi.encode(uint256(1), uint256(10e6), uint256(40e6), uint256(0), block.timestamp),
                3,
                0,
                12
            )
        );
        assertEq(rx.inflightUntil(), 0);
        assertEq(sys.cbCount(), 1);
        rx.react(_liquidityLog(5e6, 5e6, 40e6, 4, 13));
        vm.stopPrank();
        assertEq(sys.cbCount(), 2);
    }

    /// Reviewer finding: a capped batch left pending > 0 with liquidity available and nothing re-fired.
    function test_refiresAfterCappedBatch() public {
        vm.prank(SYSTEM);
        rx.react(
            _log(
                keccak256("Settled(uint256,uint256,uint256,uint256,uint256)"),
                abi.encode(uint256(10), uint256(100e6), uint256(50e6), uint256(900e6), block.timestamp),
                9,
                0,
                30
            )
        );
        assertEq(sys.cbCount(), 1);
        (, address recipient,,) = sys.last();
        assertEq(recipient, address(vault));
    }

    function test_lentAndWithdrawnUpdateShadowLiquidity() public {
        vm.startPrank(SYSTEM);
        rx.react(_liquidityLog(100e6, 100e6, 0, 1, 10));
        assertEq(rx.liquidity(), 100e6);
        rx.react(_log(keccak256("Lent(address,uint256,uint256)"), abi.encode(uint256(100e6), uint256(0)), 2, 0, 11));
        assertEq(rx.liquidity(), 0);
        rx.react(_log(keccak256("Withdrawn(address,uint256,uint256)"), abi.encode(uint256(5e6), uint256(7e6)), 3, 0, 12));
        assertEq(rx.liquidity(), 7e6);
        vm.stopPrank();
        assertEq(sys.cbCount(), 0);
    }

    function test_wrongOriginIgnored() public {
        IReactive.LogRecord memory l = _liquidityLog(1e6, 1e6, 1e6, 1, 1);
        l.chainId = 1;
        vm.prank(SYSTEM);
        rx.react(l);
        assertEq(rx.eventsIgnored(), 1);
        assertEq(sys.cbCount(), 0);
    }

    function test_onlyOwnerSetsPolicy() public {
        vm.prank(alice);
        vm.expectRevert(TidewaterReactive.Unauthorized.selector);
        rx.setPolicy(1, 1, 200_000, 1);
    }

    /// Fuzz: whatever the repay size, payouts never exceed liquidity and accounting balances.
    function testFuzz_solvency(uint96 a, uint96 b, uint96 repayAmt) public {
        a = uint96(bound(a, MIN, 500e6));
        b = uint96(bound(b, MIN, 500e6));
        repayAmt = uint96(bound(repayAmt, 1, uint256(a) + b));
        vm.prank(alice);
        vault.deposit(a);
        vm.prank(bob);
        vault.deposit(b);
        vault.lend(uint256(a) + b);
        vm.prank(alice);
        vault.requestWithdraw(a);
        vm.prank(bob);
        vault.requestWithdraw(b);
        vm.prank(strategy);
        vault.repay(repayAmt);
        _settle(10);
        assertEq(vault.pending(), uint256(a) + b - repayAmt);
        assertEq(token.balanceOf(address(vault)), 0);
    }
}
