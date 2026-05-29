// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IVault } from "./IVault.sol";
import { IPositionManager } from "./IPositionManager.sol";

/// @notice Canonical types — match spec §14.1, §15.1, §15.2 exactly.
interface ISettlement {
    // ── Public inputs committed into the SP1 proof (spec §14.1) ──────────
    struct BatchPublicInputs {
        bytes32 prevStateRoot;
        bytes32 postStateRoot;
        bytes32 batchHash; // keccak256(abi.encode(BatchBlob))
        uint64 batchNonce;
        uint64 chainId;
        uint64 forceIncludeCursor;
    }

    struct ProofBundle {
        BatchPublicInputs publicInputs;
        bytes sp1Proof;
        bytes batchBlob; // canonical encoding (spec §15.2)
    }

    // ── Batch blob (spec §15.2, field order is load-bearing) ─────────────
    struct BatchHeader {
        uint64 batchNonce;
        bytes32 prevStateRoot;
        uint64 timestamp;
        uint32 intentCount;
        uint32 fillCount;
        uint32 forcedCount;
        uint64 forceIncludeCursor;
    }

    struct MidPriceUpdate {
        uint256 marketId;
        uint256 mid;
    }

    struct ForcedOutcome {
        uint256 forcedIntentId;
        uint8 outcome; // 1 = accepted, 2 = rejected
        uint8 rejectReason; // ForcedRejectReason; 0 if accepted
        bytes32 resultHash;
    }

    // Opaque replayed-intent envelope — decoded off-chain / in zkVM only.
    // Kept `bytes` on-chain so Settlement doesn't need to understand payload.
    struct ReplayedIntent {
        bytes payload;
    }

    struct BatchBlob {
        BatchHeader header;
        ReplayedIntent[] acceptedIntents;
        IPositionManager.Fill[] fills;
        IVault.BalanceDelta[] balanceDeltas;
        MidPriceUpdate[] midPriceUpdates;
        ForcedOutcome[] forcedOutcomes;
        bytes32[] attestedPriceIds;
        bytes32[] attestedPriceHashes;
    }

    // ── Entry points ─────────────────────────────────────────────────────
    function applyBatch(ProofBundle calldata bundle) external;
    function forceInclude(bytes calldata intent, bytes calldata sig) external payable;
    function forceIncludeFor(address trader, bytes calldata intent, bytes calldata sig) external payable;

    function stateRoot() external view returns (bytes32);
    function batchNonce() external view returns (uint64);
    function forceIncludeCursor() external view returns (uint64);
    function programVKey() external view returns (bytes32);

    // ── Events (spec §15.3) ──────────────────────────────────────────────
    event BatchSettled(
        uint64 indexed batchNonce,
        bytes32 prevStateRoot,
        bytes32 postStateRoot,
        bytes32 batchHash,
        uint64 forceIncludeCursor
    );

    event ForcedIntentResolved(uint256 indexed forcedIntentId, uint8 outcome, uint8 rejectReason, bytes32 resultHash);

    event ForceIncludeQueued(
        uint256 indexed forcedIntentId, address indexed trader, bytes32 intentHash, uint64 deadlineBatchNonce
    );

    event ProgramVKeyProposed(bytes32 indexed newVKey, uint64 activateAfter);
    event ProgramVKeyRotated(bytes32 indexed oldVKey, bytes32 indexed newVKey);
    event ProgramVKeyForceRotated(bytes32 indexed oldVKey, bytes32 indexed newVKey, bytes32 forceStateHash);
}
