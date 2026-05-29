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
import { IVault } from "../../src/interfaces/IVault.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";

/// @notice spec §15.3.1 merge gate. Asserts one-fill batch path
///         (Vault.applyBatchDelta + PM.applyBatchFills) yields state
///         bit-identical to the Phase 2 sequential PM.updatePosition path.
contract BatchEquivalenceTest is Test {
    struct Stack {
        Vault vault;
        PositionManager pm;
        MarginEngine engine;
        OracleAdapter oracle;
    }

    Stack legacy;
    Stack batch;

    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public settlement = makeAddr("settlement");
    address public alice = makeAddr("alice");

    uint256 constant MARKET_ID = 0;
    uint256 constant TICK_SIZE = 0.1e18;
    uint256 constant IMR = 2e16; // 2%
    uint64 constant BATCH_NONCE = 1;
    bytes32 constant PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        legacy = _deployStack();
        batch = _deployStack();

        vm.warp(1000);
        mockPyth.setPrice(PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(legacy.vault), type(uint256).max);
        usdc.approve(address(batch.vault), type(uint256).max);
        legacy.vault.deposit(100_000e6);
        batch.vault.deposit(100_000e6);
        vm.stopPrank();

        // Fund the PnL sink on the batch stack so it can absorb realized PnL
        // (profit → sink loses, loss → sink gains).
        usdc.mint(address(0xBEEF), 1_000_000e6);
        vm.startPrank(address(0xBEEF));
        usdc.approve(address(batch.vault), type(uint256).max);
        batch.vault.deposit(1_000_000e6);
        vm.stopPrank();

        // Pre-lock order margin for the legacy harness (matches Phase 2 PM test).
        vm.prank(settlement);
        legacy.vault.lockOrderMargin(alice, 10_000e18);
        vm.prank(settlement);
        batch.vault.lockOrderMargin(alice, 10_000e18);
    }

    function _deployStack() internal returns (Stack memory s) {
        s.vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );
        s.oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );
        s.engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(s.vault), address(s.oracle), admin))
                )
            )
        );
        s.pm = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize, (address(s.vault), address(s.engine), address(s.oracle), admin)
                    )
                )
            )
        );

        vm.startPrank(admin);
        s.vault.grantSettlement(address(s.pm));
        s.vault.grantSettlement(settlement);
        s.pm.grantRole(s.pm.SETTLEMENT_ROLE(), settlement);
        s.engine
            .setMarketConfig(
                MARKET_ID,
                IMarginEngine.MarketConfig({
                    maxLeverage: 50e18,
                    initialMarginRate: IMR,
                    maintenanceMarginRate: 1e16,
                    tickSize: TICK_SIZE,
                    lotSize: 0.00001e18,
                    maxOrderSize: 100e18,
                    minOrderSize: 0.001e18
                })
            );
        s.oracle.setMarketOracle(MARKET_ID, PYTH_ID, 60);
        vm.stopPrank();
    }

    function _assertStateEq(string memory scenario) internal view {
        IPositionManager.Position memory lp = legacy.pm.getPosition(alice, MARKET_ID);
        IPositionManager.Position memory bp = batch.pm.getPosition(alice, MARKET_ID);

        assertEq(lp.size, bp.size, string.concat(scenario, ": size"));
        assertEq(lp.entryPrice, bp.entryPrice, string.concat(scenario, ": entryPrice"));
        assertEq(lp.collateral, bp.collateral, string.concat(scenario, ": collateral"));
        assertEq(legacy.vault.balances(alice), batch.vault.balances(alice), string.concat(scenario, ": free balance"));
        assertEq(
            legacy.vault.lockedMargin(alice), batch.vault.lockedMargin(alice), string.concat(scenario, ": lockedMargin")
        );
        assertEq(
            legacy.vault.orderMargin(alice), batch.vault.orderMargin(alice), string.concat(scenario, ": orderMargin")
        );
    }

    // ── Open long ──────────────────────────────────────────────────────────
    function test_equiv_openLong() public {
        int256 sizeDelta = 0.5e18;
        uint256 fillPrice = 60_000e18;
        uint256 marginDelta = 600e18;

        vm.prank(settlement);
        legacy.pm.updatePosition(alice, MARKET_ID, sizeDelta, fillPrice, marginDelta);

        _applyOpen(batch, alice, sizeDelta, fillPrice, marginDelta);
        _assertStateEq("open long");
    }

    function test_equiv_openShort() public {
        int256 sizeDelta = -0.5e18;
        uint256 fillPrice = 60_000e18;
        uint256 marginDelta = 600e18;

        vm.prank(settlement);
        legacy.pm.updatePosition(alice, MARKET_ID, sizeDelta, fillPrice, marginDelta);

        _applyOpen(batch, alice, sizeDelta, fillPrice, marginDelta);
        _assertStateEq("open short");
    }

    // ── Increase ───────────────────────────────────────────────────────────
    function test_equiv_increaseLong() public {
        vm.startPrank(settlement);
        legacy.pm.updatePosition(alice, MARKET_ID, 0.5e18, 60_000e18, 600e18);
        legacy.pm.updatePosition(alice, MARKET_ID, 0.3e18, 62_000e18, 372e18);
        vm.stopPrank();

        _applyOpen(batch, alice, 0.5e18, 60_000e18, 600e18);

        // Increase: weighted-avg entry.
        uint256 oldSize = 0.5e18;
        uint256 addSize = 0.3e18;
        uint256 oldNotional = FixedPointMath.mulFp(60_000e18, oldSize);
        uint256 newNotional = FixedPointMath.mulFp(62_000e18, addSize);
        uint256 totalSize = oldSize + addSize;
        uint256 newEntry = FixedPointMath.divFp(oldNotional + newNotional, totalSize);
        uint256 newCollateral = 600e18 + 372e18;

        _applyIncrease(
            batch,
            alice,
            /*sizeDelta*/
            int256(addSize),
            /*fillPrice*/
            62_000e18,
            /*marginDelta*/
            372e18,
            /*newSize*/
            int256(totalSize),
            /*newEntry*/
            newEntry,
            /*newCollateral*/
            newCollateral
        );
        _assertStateEq("increase long");
    }

    // ── Partial close (profit) ────────────────────────────────────────────
    function test_equiv_partialClose_profit() public {
        vm.startPrank(settlement);
        legacy.pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);
        legacy.pm.updatePosition(alice, MARKET_ID, -0.4e18, 65_000e18, 0);
        vm.stopPrank();

        _applyOpen(batch, alice, 1e18, 60_000e18, 1_200e18);

        // Partial close: realize PnL on 0.4e18, proportional margin release.
        uint256 closeSize = 0.4e18;
        uint256 absOldSize = 1e18;
        int256 priceDiff = int256(65_000e18) - int256(60_000e18);
        int256 realized = FixedPointMath.mulFpSigned(priceDiff * 1, int256(closeSize));
        uint256 propCollateral = FixedPointMath.mulDiv(1_200e18, closeSize, absOldSize);

        _applyPartialClose(
            batch,
            alice,
            /*sizeDelta*/
            -int256(closeSize),
            /*fillPrice*/
            65_000e18,
            /*realized*/
            realized,
            /*propCollateral*/
            propCollateral,
            /*newSize*/
            int256(0.6e18),
            /*newCollateral*/
            1_200e18 - propCollateral,
            /*newEntry*/
            60_000e18
        );
        _assertStateEq("partial close profit");
    }

    // ── Full close ────────────────────────────────────────────────────────
    function test_equiv_fullClose() public {
        vm.startPrank(settlement);
        legacy.pm.updatePosition(alice, MARKET_ID, 1e18, 60_000e18, 1_200e18);
        legacy.pm.updatePosition(alice, MARKET_ID, -1e18, 61_000e18, 0);
        vm.stopPrank();

        _applyOpen(batch, alice, 1e18, 60_000e18, 1_200e18);

        int256 priceDiff = int256(61_000e18) - int256(60_000e18);
        int256 realized = FixedPointMath.mulFpSigned(priceDiff * 1, int256(1e18));

        _applyFullClose(batch, alice, -1e18, 61_000e18, realized, 1_200e18);
        _assertStateEq("full close");
    }

    // Counterparty row that absorbs realized PnL to satisfy fills-conservation
    // (§10). In production every taker fill has a maker counterparty; in the
    // single-fill gate we synthesize it via the insurance fund sink so alice's
    // bucket math stays equivalent to the Phase 2 sequential path.
    address internal constant PNL_SINK = address(0xBEEF);

    function _counterparty(int256 realized) internal pure returns (IVault.BalanceDelta memory) {
        return IVault.BalanceDelta({
            account: PNL_SINK,
            freeDelta: -realized,
            lockedMarginDelta: 0,
            orderMarginDelta: 0,
            realizedPnlDelta: -realized,
            insuranceFundDelta: 0
        });
    }

    // ── Helpers: build + apply a one-fill batch. ──────────────────────────
    function _applyOpen(Stack memory s, address account, int256 sizeDelta, uint256 fillPrice, uint256 margin) internal {
        IVault.BalanceDelta[] memory d = new IVault.BalanceDelta[](1);
        // Legacy path: unlockOrderMargin(margin) then lockMargin(margin).
        // Net: orderMargin -= margin, lockedMargin += margin.
        d[0] = IVault.BalanceDelta({
            account: account,
            freeDelta: 0,
            lockedMarginDelta: int256(margin),
            orderMarginDelta: -int256(margin),
            realizedPnlDelta: 0,
            insuranceFundDelta: 0
        });

        IPositionManager.Fill[] memory f = new IPositionManager.Fill[](1);
        f[0] = IPositionManager.Fill({
            account: account,
            marketId: MARKET_ID,
            newSize: sizeDelta,
            newEntryPrice: fillPrice,
            newCollateral: margin,
            newCumulativeFunding: 0,
            sizeDelta: sizeDelta,
            fillPrice: fillPrice,
            realizedPnl: 0
        });

        vm.prank(settlement);
        s.vault.applyBatchDelta(BATCH_NONCE, d);
        vm.prank(settlement);
        s.pm.applyBatchFills(BATCH_NONCE, f);
    }

    function _applyIncrease(
        Stack memory s,
        address account,
        int256 sizeDelta,
        uint256 fillPrice,
        uint256 marginDelta,
        int256 newSize,
        uint256 newEntry,
        uint256 newCollateral
    ) internal {
        IVault.BalanceDelta[] memory d = new IVault.BalanceDelta[](1);
        d[0] = IVault.BalanceDelta({
            account: account,
            freeDelta: 0,
            lockedMarginDelta: int256(marginDelta),
            orderMarginDelta: -int256(marginDelta),
            realizedPnlDelta: 0,
            insuranceFundDelta: 0
        });

        IPositionManager.Fill[] memory f = new IPositionManager.Fill[](1);
        f[0] = IPositionManager.Fill({
            account: account,
            marketId: MARKET_ID,
            newSize: newSize,
            newEntryPrice: newEntry,
            newCollateral: newCollateral,
            newCumulativeFunding: 0,
            sizeDelta: sizeDelta,
            fillPrice: fillPrice,
            realizedPnl: 0
        });

        vm.prank(settlement);
        s.vault.applyBatchDelta(BATCH_NONCE + 1, d);
        vm.prank(settlement);
        s.pm.applyBatchFills(BATCH_NONCE + 1, f);
    }

    function _applyPartialClose(
        Stack memory s,
        address account,
        int256 sizeDelta,
        uint256 fillPrice,
        int256 realized,
        uint256 propCollateral,
        int256 newSize,
        uint256 newCollateral,
        uint256 newEntry
    ) internal {
        // Legacy: unlockMargin(propCollateral) + realizePnl(realized).
        // Full-batch conservation needs a counterparty leg for realized PnL;
        // synthesize it via insurance fund so bucket sums are zero overall.
        IVault.BalanceDelta[] memory d = new IVault.BalanceDelta[](2);
        d[0] = IVault.BalanceDelta({
            account: account,
            freeDelta: int256(propCollateral) + realized,
            lockedMarginDelta: -int256(propCollateral),
            orderMarginDelta: 0,
            realizedPnlDelta: realized,
            insuranceFundDelta: 0
        });
        d[1] = _counterparty(realized);

        IPositionManager.Fill[] memory f = new IPositionManager.Fill[](1);
        f[0] = IPositionManager.Fill({
            account: account,
            marketId: MARKET_ID,
            newSize: newSize,
            newEntryPrice: newEntry,
            newCollateral: newCollateral,
            newCumulativeFunding: 0,
            sizeDelta: sizeDelta,
            fillPrice: fillPrice,
            realizedPnl: realized
        });

        vm.prank(settlement);
        s.vault.applyBatchDelta(BATCH_NONCE + 1, d);
        vm.prank(settlement);
        s.pm.applyBatchFills(BATCH_NONCE + 1, f);
    }

    function _applyFullClose(
        Stack memory s,
        address account,
        int256 sizeDelta,
        uint256 fillPrice,
        int256 realized,
        uint256 collateral
    ) internal {
        IVault.BalanceDelta[] memory d = new IVault.BalanceDelta[](2);
        d[0] = IVault.BalanceDelta({
            account: account,
            freeDelta: int256(collateral) + realized,
            lockedMarginDelta: -int256(collateral),
            orderMarginDelta: 0,
            realizedPnlDelta: realized,
            insuranceFundDelta: 0
        });
        d[1] = _counterparty(realized);

        IPositionManager.Fill[] memory f = new IPositionManager.Fill[](1);
        f[0] = IPositionManager.Fill({
            account: account,
            marketId: MARKET_ID,
            newSize: 0,
            newEntryPrice: 0,
            newCollateral: 0,
            newCumulativeFunding: 0,
            sizeDelta: sizeDelta,
            fillPrice: fillPrice,
            realizedPnl: realized
        });

        vm.prank(settlement);
        s.vault.applyBatchDelta(BATCH_NONCE + 1, d);
        vm.prank(settlement);
        s.pm.applyBatchFills(BATCH_NONCE + 1, f);
    }
}
