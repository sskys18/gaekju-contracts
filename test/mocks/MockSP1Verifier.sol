// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISP1Verifier } from "../../src/interfaces/ISP1Verifier.sol";

contract MockSP1Verifier is ISP1Verifier {
    bool public valid = true;

    error Sp1VerifyFailed();

    function setValid(bool v) external {
        valid = v;
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external view {
        if (!valid) revert Sp1VerifyFailed();
    }
}
