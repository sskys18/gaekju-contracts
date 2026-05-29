// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

abstract contract ReentrancyGuardUpgradeable is ReentrancyGuard {
    function __ReentrancyGuard_init() internal {
        // In OZ v5, ReentrancyGuard uses transient storage or constant slots
        // No initialization needed
    }

    function __ReentrancyGuard_init_unchained() internal {
        // No initialization needed
    }
}
