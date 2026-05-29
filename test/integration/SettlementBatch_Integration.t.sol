// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Settlement } from "../../src/Settlement.sol";
import { Router } from "../../src/Router.sol";
import { MarketFactory } from "../../src/MarketFactory.sol";
import { Vault } from "../../src/Vault.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { MockSP1Verifier } from "../mocks/MockSP1Verifier.sol";

contract SettlementBatchIntegrationTest is Test {
    using FixedPointMath for uint256;

    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant FORCE_INCLUDE_FEE_USDC = 1e6;
    uint256 internal constant DEPOSIT_USDC = 10_000e6;
    bytes32 internal constant INITIAL_ROOT = bytes32(uint256(0xA11CE));
    bytes32 internal constant PROGRAM_VKEY = bytes32(uint256(0xBEEF));
    bytes32 internal constant PYTH_ID = bytes32(uint256(1));

    Settlement internal settlement;
    Router internal router;
    MarketFactory internal marketFactory;
    Vault internal vault;
    PositionManager internal positionManager;
    MarginEngine internal marginEngine;
    OracleAdapter internal oracle;
    MockERC20 internal usdc;
    MockPyth internal mockPyth;
    MockSP1Verifier internal verifier;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

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
        router = Router(
            address(
                new ERC1967Proxy(
                    address(new Router()),
                    abi.encodeCall(
                        Router.initialize,
                        (
                            admin,
                            address(vault),
                            address(settlement),
                            address(marketFactory),
                            address(usdc),
                            FORCE_INCLUDE_FEE_USDC
                        )
                    )
                )
            )
        );

        vm.startPrank(admin);
        verifier.setValid(true);
        vault.grantSettlement(address(settlement));
        vault.grantRouter(address(router));
        positionManager.grantSettlement(address(settlement));
        marginEngine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        settlement.setMarketFactory(address(marketFactory));
        settlement.setRouter(address(router));
        marketFactory.createMarket(_marketParams());
        vm.stopPrank();

        vm.warp(1_000_000);
        mockPyth.setPrice(PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        _depositViaRouter(alice, DEPOSIT_USDC);
        _depositViaRouter(bob, DEPOSIT_USDC);
    }

    function test_applyBatch_endToEnd_advancesStateAndWritesBalances() public {
        ISettlement.BatchBlob memory blob = _fiveFillBatch(1, 0);
        bytes32 postRoot = bytes32(uint256(0xBA71C1));

        settlement.applyBatch(_bundle(blob, postRoot));

        assertEq(settlement.batchNonce(), 1, "batch nonce");
        assertEq(settlement.stateRoot(), postRoot, "state root");
        assertEq(settlement.forceIncludeCursor(), 0, "cursor");
        assertEq(vault.lastAppliedBatchNonce(), 1, "vault nonce");
        assertEq(positionManager.lastAppliedBatchNonce(), 1, "pm nonce");

        assertEq(vault.balances(alice), 10_400e18, "alice free");
        assertEq(vault.lockedMargin(alice), 600e18, "alice locked");
        assertEq(vault.orderMargin(alice), 0, "alice order");

        assertEq(vault.balances(bob), 8_200e18, "bob free");
        assertEq(vault.lockedMargin(bob), 800e18, "bob locked");
        assertEq(vault.orderMargin(bob), 0, "bob order");

        IPositionManager.Position memory alicePos = positionManager.getPosition(alice, MARKET_ID);
        assertEq(alicePos.size, 0.5e18, "alice size");
        assertEq(alicePos.entryPrice, 60_000e18, "alice entry");
        assertEq(alicePos.collateral, 600e18, "alice collateral");

        IPositionManager.Position memory bobPos = positionManager.getPosition(bob, MARKET_ID);
        assertEq(bobPos.size, -0.75e18, "bob size");
        assertEq(bobPos.entryPrice, _weightedEntry(0.5e18, 60_000e18, 0.25e18, 61_000e18), "bob entry");
        assertEq(bobPos.collateral, 800e18, "bob collateral");

        ISettlement.BatchBlob memory skipped = _emptyBlob(3, 0);
        ISettlement.ProofBundle memory skippedBundle = _bundle(skipped, bytes32(uint256(0xDEAD)));
        vm.expectRevert(Settlement.NonceNotMonotonic.selector);
        settlement.applyBatch(skippedBundle);
    }

    function test_forceInclude_overdueAfterNEmptyBatches_reverts() public {
        bytes memory intent = abi.encode(MARKET_ID, alice, uint256(7), uint256(block.timestamp + 1 hours));

        vm.prank(alice);
        router.forceInclude(intent, hex"");

        (address trader, bytes32 digest, uint64 deadlineBatchNonce, bool resolved,,) = settlement.pendingForcedIntent(1);
        assertEq(trader, alice, "queued trader");
        assertEq(digest, keccak256(intent), "intent hash");
        assertEq(deadlineBatchNonce, settlement.FORCE_INCLUDE_N(), "deadline");
        assertFalse(resolved, "queued unresolved");

        uint64 lastSafeBatch = settlement.FORCE_INCLUDE_N() - 1;
        for (uint64 nonce = 1; nonce <= lastSafeBatch; ++nonce) {
            settlement.applyBatch(_bundle(_emptyBlob(nonce, 0), bytes32(uint256(0x1000 + nonce))));
        }

        ISettlement.ProofBundle memory overdueBundle =
            _bundle(_emptyBlob(settlement.FORCE_INCLUDE_N(), 0), bytes32(uint256(0x2000)));
        vm.expectRevert(abi.encodeWithSelector(Settlement.ForcedIntentOverdue.selector, uint256(1)));
        settlement.applyBatch(overdueBundle);
    }

    function test_applyBatch_revertsWhenMarketPaused() public {
        vm.prank(admin);
        marketFactory.pauseMarket(MARKET_ID);

        ISettlement.BatchBlob memory blob = _emptyBlob(1, 0);
        blob.fills = new IPositionManager.Fill[](1);
        blob.fills[0] = _fill(alice, 1e18, 60_000e18, 1_200e18, 1e18, 60_000e18, 0);
        blob.header.fillCount = 1;

        ISettlement.ProofBundle memory pausedBundle = _bundle(blob, bytes32(uint256(0xBAD)));
        vm.expectRevert(abi.encodeWithSelector(Settlement.MarketPaused.selector, MARKET_ID));
        settlement.applyBatch(pausedBundle);
    }

    function _depositViaRouter(address trader, uint256 usdcAmount) internal {
        usdc.mint(trader, usdcAmount + FORCE_INCLUDE_FEE_USDC);
        vm.startPrank(trader);
        usdc.approve(address(router), type(uint256).max);
        router.deposit(usdcAmount);
        vm.stopPrank();
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

    function _emptyBlob(uint64 batchNonce, uint64 cursor) internal view returns (ISettlement.BatchBlob memory blob) {
        blob.header = ISettlement.BatchHeader({
            batchNonce: batchNonce,
            prevStateRoot: settlement.stateRoot(),
            timestamp: uint64(block.timestamp),
            intentCount: 0,
            fillCount: 0,
            forcedCount: 0,
            forceIncludeCursor: cursor
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
            forceIncludeCursor: blob.header.forceIncludeCursor
        });
        proof.sp1Proof = hex"";
        proof.batchBlob = batchBlob;
    }

    function _fiveFillBatch(uint64 batchNonce, uint64 cursor)
        internal
        view
        returns (ISettlement.BatchBlob memory blob)
    {
        blob = _emptyBlob(batchNonce, cursor);
        blob.fills = new IPositionManager.Fill[](5);
        blob.balanceDeltas = new IVault.BalanceDelta[](5);

        blob.fills[0] = _fill(alice, 1e18, 60_000e18, 1_200e18, 1e18, 60_000e18, 0);
        blob.balanceDeltas[0] = _delta(alice, -1_200e18, 1_200e18, 0);

        blob.fills[1] = _fill(bob, -1e18, 60_000e18, 1_200e18, -1e18, 60_000e18, 0);
        blob.balanceDeltas[1] = _delta(bob, -1_200e18, 1_200e18, 0);

        blob.fills[2] = _fill(alice, 0.5e18, 60_000e18, 600e18, -0.5e18, 62_000e18, 1_000e18);
        blob.balanceDeltas[2] = _delta(alice, 1_600e18, -600e18, 1_000e18);

        blob.fills[3] = _fill(bob, -0.5e18, 60_000e18, 600e18, 0.5e18, 62_000e18, -1_000e18);
        blob.balanceDeltas[3] = _delta(bob, -400e18, -600e18, -1_000e18);

        blob.fills[4] = _fill(
            bob, -0.75e18, _weightedEntry(0.5e18, 60_000e18, 0.25e18, 61_000e18), 800e18, -0.25e18, 61_000e18, 0
        );
        blob.balanceDeltas[4] = _delta(bob, -200e18, 200e18, 0);

        blob.header.fillCount = uint32(blob.fills.length);
    }

    function _fill(
        address account,
        int256 newSize,
        uint256 newEntryPrice,
        uint256 newCollateral,
        int256 sizeDelta,
        uint256 fillPrice,
        int256 realizedPnl
    ) internal pure returns (IPositionManager.Fill memory) {
        return IPositionManager.Fill({
            account: account,
            marketId: MARKET_ID,
            newSize: newSize,
            newEntryPrice: newEntryPrice,
            newCollateral: newCollateral,
            newCumulativeFunding: 0,
            sizeDelta: sizeDelta,
            fillPrice: fillPrice,
            realizedPnl: realizedPnl
        });
    }

    function _delta(address account, int256 freeDelta, int256 lockedMarginDelta, int256 realizedPnl)
        internal
        pure
        returns (IVault.BalanceDelta memory)
    {
        return IVault.BalanceDelta({
            account: account,
            freeDelta: freeDelta,
            lockedMarginDelta: lockedMarginDelta,
            orderMarginDelta: 0,
            realizedPnlDelta: realizedPnl,
            insuranceFundDelta: 0
        });
    }

    function _weightedEntry(uint256 oldSize, uint256 oldPrice, uint256 addSize, uint256 addPrice)
        internal
        pure
        returns (uint256)
    {
        uint256 oldNotional = FixedPointMath.mulFp(oldPrice, oldSize);
        uint256 addNotional = FixedPointMath.mulFp(addPrice, addSize);
        return FixedPointMath.divFp(oldNotional + addNotional, oldSize + addSize);
    }
}
