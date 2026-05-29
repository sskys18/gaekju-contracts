// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { Settlement } from "../../src/Settlement.sol";
import { MarketFactory } from "../../src/MarketFactory.sol";
import { ISettlement } from "../../src/interfaces/ISettlement.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { Vault } from "../../src/Vault.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { IPositionManager } from "../../src/interfaces/IPositionManager.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { MockSP1Verifier } from "../mocks/MockSP1Verifier.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SettlementTest is Test {
    Settlement public settlement;
    Vault public vault;
    PositionManager public pm;
    MarginEngine public engine;
    OracleAdapter public oracle;
    MarketFactory public marketFactory;
    MockSP1Verifier public verifier;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    uint256 constant MARKET_ID = 0;
    bytes32 constant INITIAL_ROOT = bytes32(uint256(0xC0FFEE));
    bytes32 constant PROGRAM_VKEY = bytes32(uint256(0xBEEF));
    bytes32 constant PYTH_ID = bytes32(uint256(1));
    uint256 constant ACTIVE_MARKET_ID = 1;

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
                            address(pm),
                            address(0), // fundingRate stub
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
                    abi.encodeCall(MarketFactory.initialize, (admin, address(engine), address(oracle)))
                )
            )
        );

        vm.startPrank(admin);
        vault.grantSettlement(address(settlement));
        pm.grantRole(pm.SETTLEMENT_ROLE(), address(settlement));
        engine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        settlement.setMarketFactory(address(marketFactory));
        engine.setMarketConfig(
            MARKET_ID,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: 0.1e18,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );
        oracle.setMarketOracle(MARKET_ID, PYTH_ID, 60);
        marketFactory.createMarket(
            IMarketFactory.MarketParams({
                tickSize: 0.1e18,
                lotSize: 0.00001e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                pythPriceId: bytes32(uint256(2)),
                oracleStalenessThreshold: 60,
                fundingInterval: 1 hours,
                maxFundingRate: 5e15,
                minOrderSize: 0.001e18,
                maxOrderSize: 100e18,
                makerFeeRate: 5e14,
                takerFeeRate: 1e15
            })
        );
        vm.stopPrank();

        vm.warp(1_000_000);
        mockPyth.setPrice(PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        // Fund alice.
        usdc.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────
    function _emptyBlob(uint64 nonce, bytes32 postRoot, uint64 cursor)
        internal
        view
        returns (ISettlement.BatchBlob memory blob)
    {
        blob.header = ISettlement.BatchHeader({
            batchNonce: nonce,
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
        postRoot;
    }

    function _bundle(ISettlement.BatchBlob memory blob, bytes32 postRoot)
        internal
        view
        returns (ISettlement.ProofBundle memory bundle)
    {
        bytes memory blobBytes = abi.encode(blob);
        bundle.publicInputs = ISettlement.BatchPublicInputs({
            prevStateRoot: settlement.stateRoot(),
            postStateRoot: postRoot,
            batchHash: keccak256(blobBytes),
            batchNonce: blob.header.batchNonce,
            chainId: uint64(block.chainid),
            forceIncludeCursor: blob.header.forceIncludeCursor
        });
        bundle.sp1Proof = hex"";
        bundle.batchBlob = blobBytes;
    }

    // ── Happy path ───────────────────────────────────────────────────────
    function test_applyBatch_empty_advancesState() public {
        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(0xDEAD)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(0xDEAD)));

        settlement.applyBatch(bundle);

        assertEq(settlement.stateRoot(), bytes32(uint256(0xDEAD)), "root advanced");
        assertEq(settlement.batchNonce(), 1, "nonce advanced");
        assertEq(settlement.forceIncludeCursor(), 0, "cursor unchanged");
    }

    // ── Revert: bad nonce ────────────────────────────────────────────────
    function test_applyBatch_staleNonce_reverts() public {
        ISettlement.BatchBlob memory blob = _emptyBlob(2, bytes32(uint256(1)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        vm.expectRevert(Settlement.NonceNotMonotonic.selector);
        settlement.applyBatch(bundle);
    }

    function test_applyBatch_badChainId_reverts() public {
        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        bundle.publicInputs.chainId = uint64(block.chainid + 1);
        // Re-hash not needed — chainId lives in public inputs, not blob.
        vm.expectRevert(Settlement.ChainIdMismatch.selector);
        settlement.applyBatch(bundle);
    }

    function test_applyBatch_badPrevRoot_reverts() public {
        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        bundle.publicInputs.prevStateRoot = bytes32(uint256(0xBAD));
        vm.expectRevert(Settlement.PrevStateRootMismatch.selector);
        settlement.applyBatch(bundle);
    }

    function test_applyBatch_badProof_reverts() public {
        verifier.setValid(false);
        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        vm.expectRevert(MockSP1Verifier.Sp1VerifyFailed.selector);
        settlement.applyBatch(bundle);
    }

    function test_applyBatch_blobHashMismatch_reverts() public {
        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        // Tamper with blob bytes after hash was committed.
        bundle.batchBlob = abi.encode(uint256(0xDEAD));
        vm.expectRevert(Settlement.BatchHashMismatch.selector);
        settlement.applyBatch(bundle);
    }

    // ── Force-include queue ──────────────────────────────────────────────
    function test_forceInclude_enqueues() public {
        bytes memory intent = hex"deadbeef";
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        settlement.forceInclude{ value: 1 wei }(intent, hex"");

        (address trader,, uint64 deadline, bool resolved,,) = settlement.pendingForcedIntent(1);
        assertEq(trader, alice);
        assertEq(deadline, settlement.batchNonce() + settlement.FORCE_INCLUDE_N());
        assertFalse(resolved);
    }

    function test_forceInclude_overdue_reverts_withoutCoverage() public {
        bytes memory intent = hex"deadbeef";
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        settlement.forceInclude{ value: 1 wei }(intent, hex"");

        // deadlineBatchNonce = 0 + FORCE_INCLUDE_N = 3. Batches 1..2 are fine;
        // batch 3 would match the deadline and needs forced coverage.
        uint64 deadlineN = uint64(settlement.FORCE_INCLUDE_N());
        for (uint64 i = 1; i < deadlineN; ++i) {
            ISettlement.BatchBlob memory blob = _emptyBlob(i, settlement.stateRoot(), 0);
            ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(i)));
            settlement.applyBatch(bundle);
        }

        ISettlement.BatchBlob memory overdueBlob = _emptyBlob(deadlineN, settlement.stateRoot(), 0);
        ISettlement.ProofBundle memory overdueBundle = _bundle(overdueBlob, bytes32(uint256(deadlineN)));
        vm.expectRevert(abi.encodeWithSelector(Settlement.ForcedIntentOverdue.selector, uint256(1)));
        settlement.applyBatch(overdueBundle);
    }

    function test_forceInclude_resolvedByBatch() public {
        bytes memory intent = hex"deadbeef";
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        settlement.forceInclude{ value: 1 wei }(intent, hex"");

        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 1);
        blob.forcedOutcomes = new ISettlement.ForcedOutcome[](1);
        blob.forcedOutcomes[0] = ISettlement.ForcedOutcome({
            forcedIntentId: 1, outcome: 1, rejectReason: 0, resultHash: bytes32(uint256(0xAA))
        });
        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));

        settlement.applyBatch(bundle);

        (,,, bool resolved, uint8 outcome,) = settlement.pendingForcedIntent(1);
        assertTrue(resolved);
        assertEq(outcome, 1);
        assertEq(settlement.forceIncludeCursor(), 1);
    }

    function test_applyBatch_pausedFillMarket_reverts() public {
        vm.prank(admin);
        marketFactory.pauseMarket(ACTIVE_MARKET_ID);

        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        blob.fills = new IPositionManager.Fill[](1);
        blob.fills[0] = IPositionManager.Fill({
            account: alice,
            marketId: ACTIVE_MARKET_ID,
            newSize: 1e18,
            newEntryPrice: 60_000e18,
            newCollateral: 1_000e18,
            newCumulativeFunding: 0,
            sizeDelta: 1e18,
            fillPrice: 60_000e18,
            realizedPnl: 0
        });
        blob.header.fillCount = 1;

        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Settlement.MarketPaused.selector, ACTIVE_MARKET_ID));
        settlement.applyBatch(bundle);
    }

    function test_applyBatch_pausedMidPriceMarket_reverts() public {
        vm.prank(admin);
        marketFactory.pauseMarket(ACTIVE_MARKET_ID);

        ISettlement.BatchBlob memory blob = _emptyBlob(1, bytes32(uint256(1)), 0);
        blob.midPriceUpdates = new ISettlement.MidPriceUpdate[](1);
        blob.midPriceUpdates[0] = ISettlement.MidPriceUpdate({ marketId: ACTIVE_MARKET_ID, mid: 60_000e18 });

        ISettlement.ProofBundle memory bundle = _bundle(blob, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(Settlement.MarketPaused.selector, ACTIVE_MARKET_ID));
        settlement.applyBatch(bundle);
    }

    // ── vkey rotation ────────────────────────────────────────────────────
    function test_vkeyRotation_requiresPause() public {
        bytes32 next = bytes32(uint256(0xABCD));
        vm.prank(admin);
        settlement.proposeProgramVKey(next);

        vm.warp(block.timestamp + settlement.ROTATION_TIMELOCK() + 1);
        vm.prank(admin);
        vm.expectRevert(Settlement.VKeyRotationRequiresPause.selector);
        settlement.activateProgramVKey(next);
    }

    function test_vkeyRotation_happyPath() public {
        bytes32 next = bytes32(uint256(0xABCD));
        vm.startPrank(admin);
        settlement.proposeProgramVKey(next);
        vm.warp(block.timestamp + settlement.ROTATION_TIMELOCK() + 1);
        settlement.pauseMatching();
        settlement.activateProgramVKey(next);
        vm.stopPrank();

        assertEq(settlement.programVKey(), next);
    }

    function test_vkeyRotation_timelockNotElapsed_reverts() public {
        bytes32 next = bytes32(uint256(0xABCD));
        vm.startPrank(admin);
        settlement.proposeProgramVKey(next);
        settlement.pauseMatching();
        vm.expectRevert(Settlement.VKeyTimelockNotElapsed.selector);
        settlement.activateProgramVKey(next);
        vm.stopPrank();
    }
}
