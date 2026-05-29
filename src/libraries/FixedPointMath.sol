// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

library FixedPointMath {
    uint256 internal constant ONE = 1e18;

    function mulFp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, ONE);
    }

    function divFp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, ONE, b);
    }

    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c);
    }

    function mulFpSigned(int256 a, int256 b) internal pure returns (int256) {
        bool negative = (a < 0) != (b < 0);
        uint256 result = mulFp(abs(a), abs(b));
        return negative ? -int256(result) : int256(result);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(int256 value, int256 lower, int256 upper) internal pure returns (int256) {
        if (value < lower) return lower;
        if (value > upper) return upper;
        return value;
    }
}
