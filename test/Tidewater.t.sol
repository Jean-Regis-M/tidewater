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

contract TidewaterTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant CHAIN = 84532;
    address proxy = address(0xB0B0);
    address strategy = address(0x57A7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    TideToken token;
    TidewaterVault vault;
    TidewaterReactive rx;
    MockSystem sys;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        token = new TideToken();
        rx = new TidewaterReactive(CHAIN);
        vault = new TidewaterVault(IERC20(address(token)), IPayable(payable(proxy)), address(rx), strategy);
        rx.bind(address(vault));
        token.mint(alice, 1_000e6);
        token.mint(bob, 1_000e6);
        token.mint(strategy, 1_000e6);
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
            keccak256("LiquidityAdded(address,uint256,uint256,uint256)"),
            abi.encode(amt, liq, pend),
            txh,
            0,
            blk
        );
    }

    // ---- vault
    function test_instantWithdrawWhenLiquid() public {
        vm.startPrank(alice);
        vault.deposit(100e6);
        uint256 id = vault.requestWithdraw(40e6);
        vm.stopPrank();
        assertEq(id, type(uint256).max);
        assertEq(token.balanceOf(alice), 940e6);
        assertEq(vault.pending(), 0);
    }

    function _illiquid() internal {
        vm.prank(alice);
        vault.deposit(100e6);
        vault.lend(100e6);
    }

    function test_queuesWhenIlliquid() public {
        _illiquid();
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(60e6);
        assertEq(id, 0);
        assertEq(vault.pending(), 60e6);
        assertEq(vault.queueLength(), 1);
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
        assertEq(token.balanceOf(alice), 1_000e6); // alice fully paid first
        assertEq(token.balanceOf(bob), 900e6 + 50e6); // bob partial
        assertEq(vault.pending(), 50e6);

        vm.prank(strategy);
        vault.repay(50e6);
        _settle(10);
        assertEq(token.balanceOf(bob), 1_000e6);
        assertEq(vault.pending(), 0);
        assertEq(vault.queueLength(), 0);
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
        _settle(5); // must not revert
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
        _settle(5);
        assertEq(token.balanceOf(alice), 900e6); // cancelled ticket never paid
    }

    function test_cannotCancelOthersTicket() public {
        _illiquid();
        vm.prank(alice);
        vault.requestWithdraw(60e6);
        vm.prank(bob);
        vm.expectRevert(TidewaterVault.NotTicketOwner.selector);
        vault.cancelTicket(0);
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
        _settle(2);
        assertEq(vault.pending(), 0);
    }

    // ---- reactive
    function test_bindSubscribesFourTopics() public view {
        assertEq(sys.subs(), 4);
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
        rx.react(_liquidityLog(5e6, 5e6, 40e6, 4, 13));
        vm.stopPrank();
        assertEq(sys.cbCount(), 2);
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
        rx.setPolicy(1, 1, 1, 1);
    }

    /// Fuzz: whatever FIFO sequence of deposits/withdrawals, vault never pays out more than it holds.
    function testFuzz_solvency(uint96 a, uint96 b, uint96 repayAmt) public {
        a = uint96(bound(a, 1e6, 500e6));
        b = uint96(bound(b, 1e6, 500e6));
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
