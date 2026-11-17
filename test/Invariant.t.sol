// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {TideToken} from "../src/TideToken.sol";
import {TidewaterVault, IERC20} from "../src/TidewaterVault.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// Random sequences of deposit / withdraw / cancel / lend / repay / settle across three users.
contract Handler is Test {
    TidewaterVault public vault;
    TideToken public token;
    address public proxy;
    address public reactive;
    address public strategy;
    address[3] public users;
    uint256[] public openIds;

    constructor(TidewaterVault v, TideToken t, address proxy_, address reactive_, address strategy_) {
        vault = v;
        token = t;
        proxy = proxy_;
        reactive = reactive_;
        strategy = strategy_;
        users = [address(0x1001), address(0x1002), address(0x1003)];
        for (uint256 i; i < 3; i++) {
            token.mint(users[i], 1e15);
            vm.prank(users[i]);
            token.approve(address(v), type(uint256).max);
        }
        token.mint(strategy_, 1e15);
        vm.prank(strategy_);
        token.approve(address(v), type(uint256).max);
    }

    function deposit(uint256 u, uint256 amt) external {
        address a = users[u % 3];
        vm.prank(a);
        vault.deposit(bound(amt, 1e6, 1e9));
    }

    function withdraw(uint256 u, uint256 amt) external {
        address a = users[u % 3];
        uint256 c = vault.claims(a);
        if (c < 1e6) return;
        vm.prank(a);
        try vault.requestWithdraw(bound(amt, 1e6, c)) {} catch {}
    }

    function cancel(uint256 id) external {
        uint256 n = vault.ticketCount();
        if (n == 0) return;
        id = id % n;
        (address o,,,, bool active,,) = vault.tickets(id);
        if (!active) return;
        vm.prank(o);
        vault.cancelTicket(id);
    }

    function lend(uint256 amt) external {
        uint256 l = vault.liquidity();
        if (l == 0 || vault.pending() != 0) return;
        vm.prank(vault.owner());
        vault.lend(bound(amt, 1, l));
    }

    function repay(uint256 amt) external {
        vm.prank(strategy);
        vault.repay(bound(amt, 1, 1e9));
    }

    function settle(uint256 max) external {
        vm.prank(proxy);
        vault.settle(reactive, bound(max, 1, 30));
    }
}

contract InvariantTest is Test {
    TidewaterVault vault;
    TideToken token;
    Handler h;
    address proxy = address(0xB0B0);
    address reactive = address(0xCAFE);

    function setUp() public {
        token = new TideToken();
        vault = new TidewaterVault(IERC20(address(token)), IPayable(payable(proxy)), reactive, address(0x57A7), 1e6);
        h = new Handler(vault, token, proxy, reactive, address(0x57A7));
        targetContract(address(h));
    }

    /// pending equals the sum of unfilled amounts of live tickets, and the live count matches the list.
    function invariant_pendingMatchesLiveTickets() public view {
        uint256 sum;
        uint256 live;
        for (uint256 i; i < vault.ticketCount(); i++) {
            (,uint128 amt, uint128 filled,, bool active,,) = vault.tickets(i);
            if (active) {
                sum += amt - filled;
                live++;
            }
        }
        assertEq(vault.pending(), sum);
        assertEq(vault.queueLength(), live);
    }

    /// walking the list from head visits exactly the live tickets, in id order (FIFO).
    function invariant_listIsFifoAndComplete() public view {
        uint256 i = vault.head();
        uint256 seen;
        uint256 prevId;
        bool first = true;
        while (i != vault.NONE()) {
            (,,,, bool active,, uint256 next) = vault.tickets(i);
            assertTrue(active);
            if (!first) assertGt(i, prevId);
            first = false;
            prevId = i;
            seen++;
            i = next;
            assertLe(seen, vault.ticketCount());
        }
        assertEq(seen, vault.queueLength());
    }

    /// the vault never holds less than liquidity + parked payouts (no hidden insolvency).
    function invariant_balanceCoversLiquidityAndOwed() public view {
        assertGe(token.balanceOf(address(vault)), vault.liquidity() + vault.totalOwed());
    }
}
