// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/FixedPointMath.sol";

contract FixedPointMathFuzzTest is Test {
    function testFuzz_mulFp_identity(uint128 a) public pure {
        uint256 x = uint256(a);
        assertEq(FixedPointMath.mulFp(x, 1e18), x);
    }

    function testFuzz_mulFp_commutative(uint128 a, uint128 b) public pure {
        uint256 x = uint256(a);
        uint256 y = uint256(b);
        assertEq(FixedPointMath.mulFp(x, y), FixedPointMath.mulFp(y, x));
    }

    function testFuzz_mulDiv_roundTrip(uint128 a, uint128 b) public pure {
        vm.assume(b > 0);
        uint256 x = uint256(a);
        uint256 y = uint256(b);
        uint256 product = FixedPointMath.mulFp(x, y);
        uint256 recovered = FixedPointMath.divFp(product, y);
        // Max rounding error: mulFp truncates x*y/1e18, divFp truncates product*1e18/y.
        // Worst-case absolute error is bounded by ceil(1e18 / y).
        uint256 maxDelta = (1e18 + y - 1) / y;
        assertApproxEqAbs(recovered, x, maxDelta);
    }

    function testFuzz_abs_symmetric(int128 x) public pure {
        vm.assume(x != type(int128).min);
        assertEq(FixedPointMath.abs(int256(x)), FixedPointMath.abs(int256(-x)));
    }
}
