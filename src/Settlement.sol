// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { ISettlement } from "./interfaces/ISettlement.sol";
import { ISP1Verifier } from "./interfaces/ISP1Verifier.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";

/// @notice Single on-chain endpoint for proved matching batches (ADR-0012,
///         spec §15). Verifies an SP1 proof over `BatchPublicInputs`, applies
///         the state delta to Vault/PM, and stores resolved forced-intent
///         outcomes. vkey rotation via pause-and-drain (spec §15.5).
contract Settlement is ISettlement, Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    // ── Errors ───────────────────────────────────────────────────────────
    error BatchHashMismatch();
    error ChainIdMismatch();
    error NonceNotMonotonic();
    error PrevStateRootMismatch();
    error HeaderCursorMismatch();
    error CursorNotMonotonic();
    error CursorOutOfRange();
    error CursorNotContiguous();
    error ForcedIntentOverdue(uint256 forcedIntentId);
    error ForcedIntentUnknown(uint256 forcedIntentId);
    error VKeyTimelockNotElapsed();
    error VKeyRotationRequiresPause();
    error VKeyForceTimelockNotElapsed();
    error ForceRotationRequiresPausedThroughout();
    error NoPendingVKey();
    error PendingVKeyMismatch();
    error UnresolvedOverdueForced();
    error MarketFactoryNotSet();
    error MarketPaused(uint256 marketId);
    error UnauthorizedForwarder();

    // ── Constants ────────────────────────────────────────────────────────
    uint64 public constant FORCE_INCLUDE_N = 3; // ADR-0014, spec §15.2
    uint64 public constant ROTATION_TIMELOCK = 24 hours; // spec §15.5
    uint64 public constant ROTATION_FORCE_TIMELOCK = 7 days; // spec §15.5
    uint256 public constant FORCE_INCLUDE_FEE = 1e18; // 1 USDC in 18-dec

    uint8 public constant OUTCOME_ACCEPTED = 1;
    uint8 public constant OUTCOME_REJECTED = 2;
    uint8 public constant REJECTED_SEQUENCER_FORCED_ROTATION = 99;

    // ── Dependencies ─────────────────────────────────────────────────────
    ISP1Verifier public verifier;
    IVault public vault;
    IPositionManager public positionManager;
    address public fundingRate; // minimal placeholder until Phase 5.5
    IMarketFactory public marketFactory;
    address public router;

    // ── Core state ───────────────────────────────────────────────────────
    bytes32 public stateRoot;
    uint64 public batchNonce;
    uint64 public forceIncludeCursor;

    // ── vkey rotation state (spec §15.5) ─────────────────────────────────
    bytes32 public programVKey;
    bytes32 public pendingProgramVKey;
    uint64 public vkeyProposalTimestamp;
    uint64 public pausedSince; // wall-clock of latest pause; 0 when unpaused

    // ── Force-include queue ──────────────────────────────────────────────
    struct PendingForcedIntent {
        address trader;
        bytes32 intentDigest;
        uint64 deadlineBatchNonce;
        bool resolved;
        uint8 outcome;
        uint8 rejectReason;
        bytes32 resultHash;
    }

    mapping(uint256 => PendingForcedIntent) internal _pendingForced;
    uint256 public latestQueuedForcedId;

    uint256[43] private __gap;

    event MarketFactorySet(address indexed marketFactory);
    event RouterSet(address indexed router);

    // ── Init ─────────────────────────────────────────────────────────────
    function initialize(
        address _admin,
        address _verifier,
        address _vault,
        address _positionManager,
        address _fundingRate,
        bytes32 _programVKey,
        bytes32 _initialStateRoot
    ) external initializer {
        __AccessControl_init();
        // OZ v5.6.1 drops Pausable + UUPS __init helpers; storage is
        // lazily initialized via Initializable + modifier chain.

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        verifier = ISP1Verifier(_verifier);
        vault = IVault(_vault);
        positionManager = IPositionManager(_positionManager);
        fundingRate = _fundingRate;
        programVKey = _programVKey;
        stateRoot = _initialStateRoot;
    }

    // ── applyBatch (spec §15.3 step order 1-14) ──────────────────────────
    function applyBatch(ProofBundle calldata bundle) external whenNotPaused {
        BatchPublicInputs calldata pub = bundle.publicInputs;

        // 1. Blob hash + chain id.
        if (keccak256(bundle.batchBlob) != pub.batchHash) revert BatchHashMismatch();
        if (pub.chainId != block.chainid) revert ChainIdMismatch();

        // 2. Nonce continuity.
        if (pub.batchNonce != batchNonce + 1) revert NonceNotMonotonic();

        // 3. Prev-state-root continuity.
        if (pub.prevStateRoot != stateRoot) revert PrevStateRootMismatch();

        // 4. Header cursor lines up with public input + cursor bounds.
        BatchBlob memory blob = abi.decode(bundle.batchBlob, (BatchBlob));
        if (blob.header.forceIncludeCursor != pub.forceIncludeCursor) revert HeaderCursorMismatch();
        if (pub.forceIncludeCursor < forceIncludeCursor) revert CursorNotMonotonic();
        if (pub.forceIncludeCursor > latestQueuedForcedId) revert CursorOutOfRange();

        // 5. SP1 verify.
        verifier.verifyProof(programVKey, abi.encode(pub), bundle.sp1Proof);

        // 6. Force-include liveness check — every overdue unresolved entry
        //    must appear in blob.forcedOutcomes.
        _assertOverdueCovered(pub.batchNonce, blob.forcedOutcomes);

        // 7. Store forced outcomes.
        for (uint256 i; i < blob.forcedOutcomes.length; ++i) {
            ForcedOutcome memory fo = blob.forcedOutcomes[i];
            PendingForcedIntent storage p = _pendingForced[fo.forcedIntentId];
            if (p.trader == address(0)) revert ForcedIntentUnknown(fo.forcedIntentId);
            p.resolved = true;
            p.outcome = fo.outcome;
            p.rejectReason = fo.rejectReason;
            p.resultHash = fo.resultHash;
            emit ForcedIntentResolved(fo.forcedIntentId, fo.outcome, fo.rejectReason, fo.resultHash);
        }

        // 8. Reject paused or unknown markets before any state fan-out.
        _assertMarketsActive(blob.fills, blob.midPriceUpdates);

        // 9. Vault deltas (fills-conservation enforced inside Vault).
        vault.applyBatchDelta(pub.batchNonce, blob.balanceDeltas);

        // 10. Mid-price update hook. Phase 1 perp-era artifact retained only for
        //     v0.1 build compatibility; removed in Phase 2 per ADR-0017.
        _dispatchMidPriceUpdates(blob.midPriceUpdates);

        // 11. Position state.
        positionManager.applyBatchFills(pub.batchNonce, blob.fills);

        // 12. Contiguity check now that forced outcomes applied.
        if (!_cursorContiguous(pub.forceIncludeCursor)) revert CursorNotContiguous();

        // 13. Persist state.
        stateRoot = pub.postStateRoot;
        batchNonce = pub.batchNonce;
        forceIncludeCursor = pub.forceIncludeCursor;

        // 14. Emit.
        emit BatchSettled(pub.batchNonce, pub.prevStateRoot, pub.postStateRoot, pub.batchHash, pub.forceIncludeCursor);
    }

    function _assertOverdueCovered(uint64 currentBatchNonce, ForcedOutcome[] memory outcomes) internal view {
        // Build a set of forcedIntentIds present in outcomes.
        // latestQueuedForcedId is small in v1 (force-include queue is an
        // escape hatch, not the hot path), so O(n*m) is acceptable here.
        uint256 n = latestQueuedForcedId;
        for (uint256 id = 1; id <= n; ++id) {
            PendingForcedIntent storage p = _pendingForced[id];
            if (p.resolved) continue;
            if (p.deadlineBatchNonce > currentBatchNonce) continue;

            bool covered;
            for (uint256 j; j < outcomes.length; ++j) {
                if (outcomes[j].forcedIntentId == id) {
                    covered = true;
                    break;
                }
            }
            if (!covered) revert ForcedIntentOverdue(id);
        }
    }

    function _cursorContiguous(uint64 cursor) internal view returns (bool) {
        for (uint256 id = 1; id <= cursor; ++id) {
            if (!_pendingForced[id].resolved) return false;
        }
        return true;
    }

    function _assertMarketsActive(IPositionManager.Fill[] memory fills, MidPriceUpdate[] memory updates) internal view {
        if (fills.length == 0 && updates.length == 0) return;
        if (address(marketFactory) == address(0)) revert MarketFactoryNotSet();

        for (uint256 i; i < fills.length; ++i) {
            if (!marketFactory.marketActive(fills[i].marketId)) revert MarketPaused(fills[i].marketId);
        }

        for (uint256 i; i < updates.length; ++i) {
            if (!marketFactory.marketActive(updates[i].marketId)) revert MarketPaused(updates[i].marketId);
        }
    }

    function _dispatchMidPriceUpdates(MidPriceUpdate[] memory updates) internal view {
        // Phase 5.5: FundingRate.updateSequencerMid(marketId, mid). Ignore
        // for now — no-op stub so Settlement can ship ahead of FundingRate.
        updates; // silence unused-param warning
        fundingRate; // reserved slot for sink wiring
    }

    // ── forceInclude (spec §15.2/§15.3.4) ────────────────────────────────
    function forceInclude(
        bytes calldata intent,
        bytes calldata /*sig*/
    )
        external
        payable
        whenNotPaused
    {
        _queueForcedIntent(msg.sender, intent);
    }

    function forceIncludeFor(
        address trader,
        bytes calldata intent,
        bytes calldata /*sig*/
    )
        external
        payable
        whenNotPaused
    {
        if (msg.sender != router) revert UnauthorizedForwarder();
        _queueForcedIntent(trader, intent);
    }

    function _queueForcedIntent(address trader, bytes calldata intent) internal {
        uint256 id = ++latestQueuedForcedId;
        bytes32 digest = keccak256(intent);

        _pendingForced[id] = PendingForcedIntent({
            trader: trader,
            intentDigest: digest,
            deadlineBatchNonce: batchNonce + FORCE_INCLUDE_N,
            resolved: false,
            outcome: 0,
            rejectReason: 0,
            resultHash: bytes32(0)
        });

        emit ForceIncludeQueued(id, trader, digest, batchNonce + FORCE_INCLUDE_N);
    }

    function pendingForcedIntent(uint256 id)
        external
        view
        returns (
            address trader,
            bytes32 intentDigest,
            uint64 deadlineBatchNonce,
            bool resolved,
            uint8 outcome,
            uint8 rejectReason
        )
    {
        PendingForcedIntent storage p = _pendingForced[id];
        return (p.trader, p.intentDigest, p.deadlineBatchNonce, p.resolved, p.outcome, p.rejectReason);
    }

    function setMarketFactory(address nextMarketFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        marketFactory = IMarketFactory(nextMarketFactory);
        emit MarketFactorySet(nextMarketFactory);
    }

    function setRouter(address nextRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        router = nextRouter;
        emit RouterSet(nextRouter);
    }

    // ── vkey rotation (spec §15.5) ───────────────────────────────────────
    function proposeProgramVKey(bytes32 next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        pendingProgramVKey = next;
        vkeyProposalTimestamp = uint64(block.timestamp);
        emit ProgramVKeyProposed(next, uint64(block.timestamp) + ROTATION_TIMELOCK);
    }

    function activateProgramVKey(bytes32 next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingProgramVKey == bytes32(0)) revert NoPendingVKey();
        if (next != pendingProgramVKey) revert PendingVKeyMismatch();
        if (!paused()) revert VKeyRotationRequiresPause();
        if (block.timestamp < vkeyProposalTimestamp + ROTATION_TIMELOCK) revert VKeyTimelockNotElapsed();

        // Spec §15.5 step 5: no unresolved force-included intents overdue.
        uint256 n = latestQueuedForcedId;
        for (uint256 id = 1; id <= n; ++id) {
            PendingForcedIntent storage p = _pendingForced[id];
            if (!p.resolved && p.deadlineBatchNonce <= batchNonce) revert UnresolvedOverdueForced();
        }

        bytes32 old = programVKey;
        programVKey = next;
        pendingProgramVKey = bytes32(0);
        vkeyProposalTimestamp = 0;
        emit ProgramVKeyRotated(old, next);
    }

    struct ForceState {
        bytes32 postStateRoot;
        uint64 batchNonce;
        uint64 forceIncludeCursor;
    }

    function forceActivateProgramVKey(bytes32 next, ForceState calldata forceState)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingProgramVKey == bytes32(0)) revert NoPendingVKey();
        if (next != pendingProgramVKey) revert PendingVKeyMismatch();
        if (!paused()) revert ForceRotationRequiresPausedThroughout();
        if (pausedSince == 0 || block.timestamp < pausedSince + ROTATION_FORCE_TIMELOCK) {
            revert VKeyForceTimelockNotElapsed();
        }

        // Reject all queued force-included intents.
        uint256 n = latestQueuedForcedId;
        for (uint256 id = 1; id <= n; ++id) {
            PendingForcedIntent storage p = _pendingForced[id];
            if (p.resolved) continue;
            p.resolved = true;
            p.outcome = OUTCOME_REJECTED;
            p.rejectReason = REJECTED_SEQUENCER_FORCED_ROTATION;
            emit ForcedIntentResolved(id, OUTCOME_REJECTED, REJECTED_SEQUENCER_FORCED_ROTATION, bytes32(0));
        }

        bytes32 old = programVKey;
        programVKey = next;
        stateRoot = forceState.postStateRoot;
        batchNonce = forceState.batchNonce;
        forceIncludeCursor = forceState.forceIncludeCursor;
        pendingProgramVKey = bytes32(0);
        vkeyProposalTimestamp = 0;

        emit ProgramVKeyForceRotated(old, next, keccak256(abi.encode(forceState)));
    }

    // ── Pause / unpause (governance) ─────────────────────────────────────
    function pauseMatching() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
        pausedSince = uint64(block.timestamp);
    }

    function unpauseMatching() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
        pausedSince = 0;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
