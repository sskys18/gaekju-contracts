// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal SP1 verifier surface matching Succinct's v3 ABI.
///         Real deployment: SP1VerifierGateway on Giwa once Succinct
///         ships it (ADR-0013). Until then, tests use MockSP1Verifier.
interface ISP1Verifier {
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view;
}
