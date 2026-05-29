// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/libraries/FixedPointMath.sol";

contract FixedPointMathWrapper {
    function divFp(uint256 a, uint256 b) external pure returns (uint256) {
        return FixedPointMath.divFp(a, b);
    }
}

contract FixedPointMathTest is Test {
    using FixedPointMath for uint256;

    FixedPointMathWrapper wrapper;
    uint256 constant ONE = 1e18;

    function setUp() public {
        wrapper = new FixedPointMathWrapper();
    }

    function test_mulFp_oneTimesOne() public pure {
        assertEq(FixedPointMath.mulFp(ONE, ONE), ONE);
    }

    function test_mulFp_twoTimesThree() public pure {
        assertEq(FixedPointMath.mulFp(2e18, 3e18), 6e18);
    }

    function test_mulFp_zeroReturnsZero() public pure {
        assertEq(FixedPointMath.mulFp(0, 5e18), 0);
        assertEq(FixedPointMath.mulFp(5e18, 0), 0);
    }

    function test_mulFp_fractional() public pure {
        assertEq(FixedPointMath.mulFp(5e17, 5e17), 25e16);
    }

    function test_divFp_sixDividedByTwo() public pure {
        assertEq(FixedPointMath.divFp(6e18, 2e18), 3e18);
    }

    function test_divFp_oneDividedByThree() public pure {
        uint256 result = FixedPointMath.divFp(ONE, 3e18);
        assertApproxEqAbs(result, 333333333333333333, 1);
    }

    function test_divFp_revertsOnZero() public {
        vm.expectRevert();
        wrapper.divFp(ONE, 0);
    }

    function test_mulDiv_basic() public pure {
        assertEq(FixedPointMath.mulDiv(100, 200, 50), 400);
    }

    function test_mulDiv_largeNumbers() public pure {
        uint256 big = 1 << 128;
        assertEq(FixedPointMath.mulDiv(big, big, big), big);
    }

    function test_abs_positive() public pure {
        assertEq(FixedPointMath.abs(int256(5e18)), 5e18);
    }

    function test_abs_negative() public pure {
        assertEq(FixedPointMath.abs(int256(-5e18)), 5e18);
    }

    function test_abs_zero() public pure {
        assertEq(FixedPointMath.abs(int256(0)), 0);
    }

    function test_mulFpSigned() public pure {
        assertEq(FixedPointMath.mulFpSigned(2e18, 3e18), 6e18);
        assertEq(FixedPointMath.mulFpSigned(-2e18, 3e18), -6e18);
        assertEq(FixedPointMath.mulFpSigned(-2e18, -3e18), 6e18);
    }

    function test_min() public pure {
        assertEq(FixedPointMath.min(3, 5), 3);
        assertEq(FixedPointMath.min(5, 3), 3);
        assertEq(FixedPointMath.min(3, 3), 3);
    }

    function test_max() public pure {
        assertEq(FixedPointMath.max(3, 5), 5);
        assertEq(FixedPointMath.max(5, 3), 5);
    }

    function test_clamp() public pure {
        assertEq(FixedPointMath.clamp(int256(5), int256(-10), int256(10)), int256(5));
        assertEq(FixedPointMath.clamp(int256(15), int256(-10), int256(10)), int256(10));
        assertEq(FixedPointMath.clamp(int256(-15), int256(-10), int256(10)), int256(-10));
    }
}
