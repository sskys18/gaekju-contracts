// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { Vault } from "../../src/Vault.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";

contract PositionManagerTest is Test {
    PositionManager public pm;
    Vault public vault;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public settlement = makeAddr("settlement");
    address public liquidationEngine = makeAddr("liquidationEngine");
    address public alice = makeAddr("alice");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );

        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );

        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );

        pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize, (address(vault), address(engine), address(oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantSettlement(address(pm));
        vault.grantSettlement(address(engine));
        vault.grantSettlement(settlement);
        pm.grantRole(pm.SETTLEMENT_ROLE(), settlement);
        pm.setLiquidationEngine(liquidationEngine);

        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: TICK_SIZE,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, bytes32(uint256(1)), 60);
        vm.stopPrank();

        vm.warp(1000);
        mockPyth.setPrice(bytes32(uint256(1)), 6_000_000_000_000, 60_000_000, -8);

        // Fund alice
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100_000e6);

        // Lock order margin to cover all test cases (max single-fill margin = 1_240e18)
        vm.prank(settlement);
        vault.lockOrderMargin(alice, 10_000e18);
    }

    // ─── New Position ───

    function test_newLongPosition() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);
        assertTrue(pos.lastUpdated > 0);
    }

    function test_newShortPosition() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 60_000e18, 600e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);
    }

    function test_newPosition_registersHolder() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        assertEq(pm.getPositionCount(MARKET_ID), 1);
        address[] memory holders = pm.getPositionHolders(MARKET_ID);
        assertEq(holders[0], alice);
    }

    // ─── Increase Position ───

    function test_increaseLong_weightedAvgEntry() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);

        // Lock more order margin for second fill
        vm.prank(settlement);
        vault.lockOrderMargin(alice, 620e18);

        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 62_000e18, 620e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 1e18);
        // Weighted avg: (60000 * 0.5 + 62000 * 0.5) / 1.0 = 61000
        assertEq(pos.entryPrice, 61_000e18);
        assertEq(pos.collateral, 1_220e18);
    }

    function test_increaseShort_weightedAvgEntry() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 60_000e18, 600e18);

        vm.prank(settlement);
        vault.lockOrderMargin(alice, 580e18);

        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 58_000e18, 580e18);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -1e18);
        // Weighted avg: (60000 * 0.5 + 58000 * 0.5) / 1.0 = 59000
        assertEq(pos.entryPrice, 59_000e18);
        assertEq(pos.collateral, 1_180e18);
    }

    // ─── Partial Close ───

    function test_partialCloseLong_profit() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $62,000 => PnL = (62000 - 60000) * 0.5 = 1000
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        // Balance increased by: PnL (1000) + released collateral (600)
        uint256 balanceAfter = vault.balances(alice);
        assertApproxEqAbs(balanceAfter - balanceBefore, 1_600e18, 1e15);
    }

    function test_partialCloseLong_loss() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $58,000 => PnL = (58000 - 60000) * 0.5 = -1000
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -0.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        // Balance changed by: PnL (-1000) + released collateral (600) = -400
        uint256 balanceAfter = vault.balances(alice);
        // balanceAfter = balanceBefore + 600 - 1000 = balanceBefore - 400
        assertApproxEqAbs(balanceBefore - balanceAfter, 400e18, 1e15);
    }

    function test_partialCloseShort_profit() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        uint256 balanceBefore = vault.balances(alice);

        // Close half at $58,000 => PnL = (58000 - 60000) * (-0.5) = +1000
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 60_000e18);
        assertEq(pos.collateral, 600e18);

        uint256 balanceAfter = vault.balances(alice);
        assertApproxEqAbs(balanceAfter - balanceBefore, 1_600e18, 1e15);
    }

    // ─── Full Close ───

    function test_fullCloseLong() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
        assertEq(pos.collateral, 0);

        // Holder removed from registry
        assertEq(pm.getPositionCount(MARKET_ID), 0);
    }

    function test_fullCloseShort() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0);
        assertEq(pm.getPositionCount(MARKET_ID), 0);
    }

    // ─── Flip ───

    function test_flipLongToShort() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        // Flip: sell 1.5 => close 1 long + open 0.5 short
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1.5e18, 62_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 62_000e18);
        // New margin = 0.5 * 62000 * 2% = 620
        assertEq(pos.collateral, 620e18);

        // Still registered as holder
        assertEq(pm.getPositionCount(MARKET_ID), 1);
    }

    function test_flipShortToLong() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 1_200e18);

        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1.5e18, 58_000e18, 0);

        IPositionManager.Position memory pos = pm.getPosition(alice, MARKET_ID);
        assertEq(pos.size, 0.5e18);
        assertEq(pos.entryPrice, 58_000e18);
        // New margin = 0.5 * 58000 * 2% = 580
        assertEq(pos.collateral, 580e18);
    }

    // ─── Unrealized PnL ───

    function test_unrealizedPnl_long_profit() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        // Mark price from oracle = $60,000 (set in setUp)
        int256 pnl = pm.getUnrealizedPnl(alice, MARKET_ID);
        // (60000 - 60000) * 1 = 0
        assertEq(pnl, 0);
    }

    function test_unrealizedPnl_short_profit() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, -1e18, 62_000e18, 1_240e18);

        // Mark price ~ $60,000
        int256 pnl = pm.getUnrealizedPnl(alice, MARKET_ID);
        // (60000 - 62000) * (-1) = +2000
        assertApproxEqAbs(uint256(pnl), 2_000e18, 100e18); // blended price tolerance
    }

    // ─── Margin Ratio ───

    function test_marginRatio_noPosition() public view {
        uint256 ratio = pm.getMarginRatio(alice, MARKET_ID);
        assertEq(ratio, type(uint256).max);
    }

    function test_marginRatio_healthyPosition() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        uint256 ratio = pm.getMarginRatio(alice, MARKET_ID);
        // collateral=1200, notional=60000*1=60000, unrealPnL~0
        // ratio = 1200 / 60000 = 0.02 = 2e16
        assertApproxEqAbs(ratio, 2e16, 1e15);
    }

    // ─── Access Control ───

    function test_updatePosition_onlySettlement() public {
        vm.expectRevert();
        vm.prank(alice);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);
    }

    function test_liquidatePosition_onlyLiquidationEngine() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.expectRevert();
        vm.prank(alice);
        pm.liquidatePosition(alice, MARKET_ID, -0.5e18, 60_000e18);
    }

    // ─── Events ───

    function test_emitsPositionUpdated() public {
        vm.prank(settlement);
        vm.expectEmit(true, true, false, true);
        emit IPositionManager.PositionUpdated(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18, 0);
        pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);
    }

    function test_emitsPositionClosed() public {
        vm.prank(settlement);
        pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);

        vm.prank(settlement);
        vm.expectEmit(true, true, false, false);
        emit IPositionManager.PositionClosed(alice, MARKET_ID, 0);
        pm.updatePosition(alice, MARKET_ID, -1e18, 60_000e18, 0);
    }
}
