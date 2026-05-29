// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Settlement } from "../../src/Settlement.sol";
import { MarketFactory } from "../../src/MarketFactory.sol";
import { LiquidationEngine } from "../../src/LiquidationEngine.sol";
import { Vault } from "../../src/Vault.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { ILiquidationEngine } from "../../src/interfaces/ILiquidationEngine.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { MockSP1Verifier } from "../mocks/MockSP1Verifier.sol";

contract LiquidationEngineTest is Test {
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant OPEN_MARGIN = 1_200e18;
    uint256 internal constant INSURANCE_SEED_USDC = 5_000e6;
    bytes32 internal constant INITIAL_ROOT = bytes32(uint256(0x1234));
    bytes32 internal constant PROGRAM_VKEY = bytes32(uint256(0xBEEF));
    bytes32 internal constant PYTH_ID = bytes32(uint256(1));

    struct ExpectedLiquidation {
        bool isFull;
        uint256 reduceSize;
        uint256 liquidatorFeePaid;
        uint256 insuranceFeePaid;
        uint256 insuranceDraw;
        uint256 finalInsuranceFund;
        uint256 finalAliceBalance;
        uint256 finalAliceLockedMargin;
        int256 finalAliceSize;
        uint256 finalAliceCollateral;
    }

    Settlement internal settlement;
    MarketFactory internal marketFactory;
    LiquidationEngine internal liquidationEngine;
    Vault internal vault;
    PositionManager internal positionManager;
    MarginEngine internal marginEngine;
    OracleAdapter internal oracle;
    MockERC20 internal usdc;
    MockPyth internal mockPyth;
    MockSP1Verifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal insurer = makeAddr("insurer");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();
        verifier = new MockSP1Verifier();

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
        marginEngine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );
        positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize, (address(vault), address(marginEngine), address(oracle), admin)
                    )
                )
            )
        );
        liquidationEngine = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(
                        LiquidationEngine.initialize,
                        (address(vault), address(positionManager), address(marginEngine), address(oracle), admin)
                    )
                )
            )
        );
        settlement = Settlement(
            address(
                new ERC1967Proxy(
                    address(new Settlement()),
                    abi.encodeCall(
                        Settlement.initialize,
                        (
                            admin,
                            address(verifier),
                            address(vault),
                            address(positionManager),
                            address(0),
                            PROGRAM_VKEY,
                            INITIAL_ROOT
                        )
                    )
                )
            )
        );
        marketFactory = MarketFactory(
            address(
                new ERC1967Proxy(
                    address(new MarketFactory()),
                    abi.encodeCall(MarketFactory.initialize, (admin, address(marginEngine), address(oracle)))
                )
            )
        );

        vm.startPrank(admin);
        verifier.setValid(true);
        vault.grantSettlement(address(positionManager));
        vault.grantSettlement(address(settlement));
        vault.grantSettlement(address(liquidationEngine));
        positionManager.grantSettlement(address(settlement));
        positionManager.setLiquidationEngine(address(liquidationEngine));
        marginEngine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        settlement.setMarketFactory(address(marketFactory));
        marketFactory.createMarket(_marketParams());
        vm.stopPrank();

        vm.warp(1_000_000);
        mockPyth.setPrice(PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        usdc.mint(alice, 1_200e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_200e6);
        vm.stopPrank();

        usdc.mint(insurer, INSURANCE_SEED_USDC);
        vm.startPrank(insurer);
        usdc.approve(address(vault), type(uint256).max);
        vault.depositInsuranceFund(INSURANCE_SEED_USDC);
        vm.stopPrank();
    }

    function test_isLiquidatable_falseForHealthyPosition() public {
        _seedAliceLong();
        _setLiquidationConfig(5e15, 25e14);

        assertFalse(liquidationEngine.isLiquidatable(alice, MARKET_ID), "healthy position");

        vm.prank(keeper);
        vm.expectRevert(LiquidationEngine.NotLiquidatable.selector);
        liquidationEngine.liquidate(alice, MARKET_ID);
    }

    function test_liquidate_fullLiquidation_closesPositionAndPaysKeeper() public {
        _seedAliceLong();

        ILiquidationEngine.LiquidationConfig memory config =
            ILiquidationEngine.LiquidationConfig({ liquidatorFeeRate: 1e16, insuranceFundFeeRate: 1e16 });
        _setLiquidationConfig(config.liquidatorFeeRate, config.insuranceFundFeeRate);

        uint256 markPrice = 59_390e18;
        mockPyth.setPrice(PYTH_ID, 5_939_000_000_000, 60_000_000, -8);
        ExpectedLiquidation memory expected = _expectedLiquidation(markPrice, config);

        assertTrue(liquidationEngine.isLiquidatable(alice, MARKET_ID), "liquidatable");

        vm.prank(keeper);
        liquidationEngine.liquidate(alice, MARKET_ID);

        _assertOutcome(expected);
        assertEq(vault.balances(keeper), expected.liquidatorFeePaid, "keeper credit");
        assertEq(vault.balances(alice), 0, "alice free");
        assertEq(vault.lockedMargin(alice), 0, "alice locked");
    }

    function test_liquidate_partialLiquidation_reducesPositionAndMovesFees() public {
        _seedAliceLong();

        ILiquidationEngine.LiquidationConfig memory config =
            ILiquidationEngine.LiquidationConfig({ liquidatorFeeRate: 5e15, insuranceFundFeeRate: 25e14 });
        _setLiquidationConfig(config.liquidatorFeeRate, config.insuranceFundFeeRate);

        uint256 markPrice = 59_300e18;
        mockPyth.setPrice(PYTH_ID, 5_930_000_000_000, 60_000_000, -8);
        ExpectedLiquidation memory expected = _expectedLiquidation(markPrice, config);

        assertTrue(liquidationEngine.isLiquidatable(alice, MARKET_ID), "liquidatable");

        vm.prank(keeper);
        liquidationEngine.liquidate(alice, MARKET_ID);

        _assertOutcome(expected);
        assertFalse(expected.isFull, "partial path");
        assertGt(vault.balances(keeper), 0, "keeper fee");
        assertGt(vault.insuranceFund(), INSURANCE_SEED_USDC * 1e12, "insurance fee");
    }

    function test_liquidate_fullLiquidationWithDeficit_drawsInsuranceFund() public {
        _seedAliceLong();

        ILiquidationEngine.LiquidationConfig memory config =
            ILiquidationEngine.LiquidationConfig({ liquidatorFeeRate: 5e15, insuranceFundFeeRate: 25e14 });
        _setLiquidationConfig(config.liquidatorFeeRate, config.insuranceFundFeeRate);

        uint256 markPrice = 58_000e18;
        mockPyth.setPrice(PYTH_ID, 5_800_000_000_000, 60_000_000, -8);
        ExpectedLiquidation memory expected = _expectedLiquidation(markPrice, config);

        assertTrue(liquidationEngine.isLiquidatable(alice, MARKET_ID), "liquidatable");

        vm.prank(keeper);
        liquidationEngine.liquidate(alice, MARKET_ID);

        _assertOutcome(expected);
        assertEq(expected.insuranceDraw, 800e18, "insurance draw");
        assertEq(vault.balances(keeper), 0, "keeper fee");
    }

    function _seedAliceLong() internal {
        ISettlement.BatchBlob memory blob = _emptyBlob(1);
        blob.fills = new IPositionManager.Fill[](1);
        blob.fills[0] = IPositionManager.Fill({
            account: alice,
            marketId: MARKET_ID,
            newSize: 1e18,
            newEntryPrice: 60_000e18,
            newCollateral: OPEN_MARGIN,
            newCumulativeFunding: 0,
            sizeDelta: 1e18,
            fillPrice: 60_000e18,
            realizedPnl: 0
        });
        blob.balanceDeltas = new IVault.BalanceDelta[](1);
        blob.balanceDeltas[0] = IVault.BalanceDelta({
            account: alice,
            freeDelta: -_asInt256(OPEN_MARGIN),
            lockedMarginDelta: _asInt256(OPEN_MARGIN),
            orderMarginDelta: 0,
            realizedPnlDelta: 0,
            insuranceFundDelta: 0
        });
        blob.header.fillCount = 1;

        settlement.applyBatch(_bundle(blob, bytes32(uint256(1))));
    }

    function _setLiquidationConfig(uint256 liquidatorFeeRate, uint256 insuranceFundFeeRate) internal {
        vm.prank(admin);
        liquidationEngine.setLiquidationConfig(
            MARKET_ID,
            ILiquidationEngine.LiquidationConfig({
                liquidatorFeeRate: liquidatorFeeRate, insuranceFundFeeRate: insuranceFundFeeRate
            })
        );
    }

    function _marketParams() internal pure returns (IMarketFactory.MarketParams memory) {
        return IMarketFactory.MarketParams({
            tickSize: 0.1e18,
            lotSize: 0.00001e18,
            initialMarginRate: 2e16,
            maintenanceMarginRate: 1e16,
            pythPriceId: PYTH_ID,
            oracleStalenessThreshold: 60,
            fundingInterval: 1 hours,
            maxFundingRate: 5e15,
            minOrderSize: 0.001e18,
            maxOrderSize: 100e18,
            makerFeeRate: 5e14,
            takerFeeRate: 1e15
        });
    }

    function _emptyBlob(uint64 batchNonce) internal view returns (ISettlement.BatchBlob memory blob) {
        blob.header = ISettlement.BatchHeader({
            batchNonce: batchNonce,
            prevStateRoot: settlement.stateRoot(),
            timestamp: uint64(block.timestamp),
            intentCount: 0,
            fillCount: 0,
            forcedCount: 0,
            forceIncludeCursor: 0
        });
        blob.acceptedIntents = new ISettlement.ReplayedIntent[](0);
        blob.fills = new IPositionManager.Fill[](0);
        blob.balanceDeltas = new IVault.BalanceDelta[](0);
        blob.midPriceUpdates = new ISettlement.MidPriceUpdate[](0);
        blob.forcedOutcomes = new ISettlement.ForcedOutcome[](0);
        blob.attestedPriceIds = new bytes32[](0);
        blob.attestedPriceHashes = new bytes32[](0);
    }

    function _bundle(ISettlement.BatchBlob memory blob, bytes32 postRoot)
        internal
        view
        returns (ISettlement.ProofBundle memory proof)
    {
        bytes memory batchBlob = abi.encode(blob);
        proof.publicInputs = ISettlement.BatchPublicInputs({
            prevStateRoot: settlement.stateRoot(),
            postStateRoot: postRoot,
            batchHash: keccak256(batchBlob),
            batchNonce: blob.header.batchNonce,
            chainId: uint64(block.chainid),
            forceIncludeCursor: 0
        });
        proof.sp1Proof = hex"";
        proof.batchBlob = batchBlob;
    }

    function _expectedLiquidation(uint256 markPrice, ILiquidationEngine.LiquidationConfig memory config)
        internal
        view
        returns (ExpectedLiquidation memory expected)
    {
        IPositionManager.Position memory pos = positionManager.getPosition(alice, MARKET_ID);
        uint256 absSize = FixedPointMath.abs(pos.size);
        IMarginEngine.MarketConfig memory marketConfig = marginEngine.getConfig(MARKET_ID);
        uint256 totalFeeRate = config.liquidatorFeeRate + config.insuranceFundFeeRate;
        uint256 notional = FixedPointMath.mulFp(absSize, markPrice);
        int256 unrealizedPnl = _unrealizedPnl(pos.size, pos.entryPrice, markPrice);
        int256 equity = int256(pos.collateral) + unrealizedPnl;

        if (equity <= 0 || absSize <= marketConfig.minOrderSize) {
            expected.isFull = true;
            expected.reduceSize = absSize;
        } else {
            uint256 imrTimesNotional = FixedPointMath.mulFp(marketConfig.initialMarginRate, notional);
            int256 numerator = _asInt256(imrTimesNotional) - equity;

            if (marketConfig.initialMarginRate <= totalFeeRate) {
                expected.isFull = true;
                expected.reduceSize = absSize;
            } else {
                uint256 denom = FixedPointMath.mulFp(markPrice, marketConfig.initialMarginRate - totalFeeRate);
                expected.reduceSize = FixedPointMath.divFp(_asUint256(numerator), denom);
                if (expected.reduceSize >= absSize || (absSize - expected.reduceSize) < marketConfig.minOrderSize) {
                    expected.isFull = true;
                    expected.reduceSize = absSize;
                }
            }
        }

        uint256 releasedCollateral =
            expected.isFull ? pos.collateral : FixedPointMath.mulDiv(pos.collateral, expected.reduceSize, absSize);

        uint256 balance = vault.balances(alice) + releasedCollateral;
        uint256 locked = vault.lockedMargin(alice) - releasedCollateral;
        int256 realizedPnl = _closePnl(pos.size, pos.entryPrice, markPrice, expected.reduceSize);
        uint256 positionDeficit;

        if (realizedPnl >= 0) {
            balance += _asUint256(realizedPnl);
        } else {
            uint256 loss = _asUint256(-realizedPnl);
            uint256 fromBalance = loss <= balance ? loss : balance;
            balance -= fromBalance;
            loss -= fromBalance;

            uint256 fromLocked = loss <= locked ? loss : locked;
            locked -= fromLocked;
            positionDeficit = loss - fromLocked;
        }

        uint256 nominalLiquidatorFee =
            FixedPointMath.mulFp(FixedPointMath.mulFp(expected.reduceSize, markPrice), config.liquidatorFeeRate);
        uint256 nominalInsuranceFee =
            FixedPointMath.mulFp(FixedPointMath.mulFp(expected.reduceSize, markPrice), config.insuranceFundFeeRate);
        uint256 nominalTotalFee = nominalLiquidatorFee + nominalInsuranceFee;

        if (balance >= nominalTotalFee) {
            expected.liquidatorFeePaid = nominalLiquidatorFee;
            expected.insuranceFeePaid = nominalInsuranceFee;
            balance -= nominalTotalFee;
        } else if (balance > 0 && totalFeeRate > 0) {
            uint256 paidTotalFee = balance;
            balance = 0;
            expected.liquidatorFeePaid = (paidTotalFee * config.liquidatorFeeRate) / totalFeeRate;
            expected.insuranceFeePaid = paidTotalFee - expected.liquidatorFeePaid;
        }

        uint256 insuranceFundBalance = vault.insuranceFund() + expected.insuranceFeePaid;
        if (positionDeficit > 0 && insuranceFundBalance >= positionDeficit) {
            expected.insuranceDraw = positionDeficit;
            insuranceFundBalance -= positionDeficit;
            balance += positionDeficit;
        }

        expected.finalInsuranceFund = insuranceFundBalance;
        expected.finalAliceBalance = balance;
        expected.finalAliceLockedMargin = locked;
        expected.finalAliceSize = expected.isFull ? int256(0) : pos.size - _asInt256(expected.reduceSize);
        expected.finalAliceCollateral = expected.isFull ? 0 : pos.collateral - releasedCollateral;
    }

    function _closePnl(int256 posSize, uint256 entryPrice, uint256 closePrice, uint256 closeSize)
        internal
        pure
        returns (int256)
    {
        int256 priceDiff = _asInt256(closePrice) - _asInt256(entryPrice);
        int256 sign = posSize > 0 ? int256(1) : int256(-1);
        return FixedPointMath.mulFpSigned(priceDiff * sign, _asInt256(closeSize));
    }

    function _unrealizedPnl(int256 posSize, uint256 entryPrice, uint256 markPrice) internal pure returns (int256) {
        int256 priceDiff = _asInt256(markPrice) - _asInt256(entryPrice);
        return FixedPointMath.mulFpSigned(priceDiff, posSize);
    }

    function _asInt256(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "int overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }

    function _asUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "negative int");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value);
    }

    function _assertOutcome(ExpectedLiquidation memory expected) internal view {
        IPositionManager.Position memory pos = positionManager.getPosition(alice, MARKET_ID);

        assertEq(vault.balances(alice), expected.finalAliceBalance, "alice balance");
        assertEq(vault.lockedMargin(alice), expected.finalAliceLockedMargin, "alice locked");
        assertEq(vault.insuranceFund(), expected.finalInsuranceFund, "insurance fund");
        assertEq(vault.balances(keeper), expected.liquidatorFeePaid, "keeper balance");
        assertEq(pos.size, expected.finalAliceSize, "alice size");
        assertEq(pos.collateral, expected.finalAliceCollateral, "alice collateral");
    }
}
