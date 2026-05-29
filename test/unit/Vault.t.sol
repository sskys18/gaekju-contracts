// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/Vault.sol";
import "../mocks/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultTest is Test {
    Vault public vault;
    MockERC20 public usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public settlement = makeAddr("settlement");
    address public admin = makeAddr("admin");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy behind UUPS proxy
        Vault impl = new Vault();
        bytes memory initData = abi.encodeCall(Vault.initialize, (address(usdc), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = Vault(address(proxy));

        // Grant SETTLEMENT_ROLE to test placeholder (Settlement.sol lands in T3)
        vm.prank(admin);
        vault.grantSettlement(settlement);

        // Fund alice with 10,000 USDC (6 decimals)
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        // Internal balance is 18-decimal: 1_000e6 * 1e12 = 1_000e18
        assertEq(vault.balances(alice), 1_000e18);
        assertEq(vault.totalDeposits(), 1_000e18);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_withdraw() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(alice);
        vault.withdraw(500e18); // withdraw 500 in 18-dec

        assertEq(vault.balances(alice), 500e18);
        assertEq(usdc.balanceOf(alice), 9_500e6); // started with 10k, deposited 1k, withdrew 500
    }

    function test_withdraw_moreThanBalance_reverts() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdraw(1_001e18);
    }

    function test_lockMargin_onlySettlement() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.lockMargin(alice, 500e18);
        assertEq(vault.balances(alice), 500e18);
        assertEq(vault.lockedMargin(alice), 500e18);
    }

    function test_lockMargin_unauthorized_reverts() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(bob);
        vm.expectRevert();
        vault.lockMargin(alice, 500e18);
    }

    function test_unlockMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.lockMargin(alice, 500e18);

        vm.prank(settlement);
        vault.unlockMargin(alice, 200e18);

        assertEq(vault.balances(alice), 700e18);
        assertEq(vault.lockedMargin(alice), 300e18);
    }

    function test_lockOrderMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.lockOrderMargin(alice, 300e18);

        assertEq(vault.balances(alice), 700e18);
        assertEq(vault.orderMargin(alice), 300e18);
    }

    function test_unlockOrderMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.lockOrderMargin(alice, 300e18);

        vm.prank(settlement);
        vault.unlockOrderMargin(alice, 300e18);

        assertEq(vault.balances(alice), 1_000e18);
        assertEq(vault.orderMargin(alice), 0);
    }

    function test_realizePnl_profit() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.realizePnl(alice, int256(200e18));

        assertEq(vault.balances(alice), 1_200e18);
    }

    function test_realizePnl_loss() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.realizePnl(alice, -int256(200e18));

        assertEq(vault.balances(alice), 800e18);
    }

    function test_transferToInsuranceFund() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.realizePnl(alice, -int256(100e18)); // take 100 from alice
        // In practice, insurance fund fees come from specific flows.
        // For this test, just transfer from alice's balance:
        vm.prank(settlement);
        vault.lockMargin(alice, 100e18);
        vm.prank(settlement);
        vault.transferToInsuranceFund(100e18);

        assertEq(vault.insuranceFund(), 100e18);
    }

    function test_cannotWithdraw_lockedMargin() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        vm.prank(settlement);
        vault.lockMargin(alice, 800e18);

        // Only 200 free
        vm.prank(alice);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdraw(300e18);

        // 200 should work
        vm.prank(alice);
        vault.withdraw(200e18);
        assertEq(vault.balances(alice), 0);
    }
}
