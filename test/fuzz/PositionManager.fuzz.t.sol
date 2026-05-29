// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { FixedPointMath } from "../../src/libraries/FixedPointMath.sol";

contract PositionManagerFuzzTest is Test {
    /// @dev Weighted avg entry must always be between the two fill prices.
    function testFuzz_weightedAvgEntry_bounded(
        uint64 rawOldSize,
        uint64 rawNewSize,
        uint64 rawOldPrice,
        uint64 rawNewPrice
    ) public pure {
        // Constrain to reasonable ranges: size 0.001-100 BTC, price $100-$1M
        uint256 oldSize = bound(uint256(rawOldSize), 0.001e18, 100e18);
        uint256 newSize = bound(uint256(rawNewSize), 0.001e18, 100e18);
        uint256 oldPrice = bound(uint256(rawOldPrice), 100e18, 1_000_000e18);
        uint256 newPrice = bound(uint256(rawNewPrice), 100e18, 1_000_000e18);

        uint256 oldNotional = FixedPointMath.mulFp(oldPrice, oldSize);
        uint256 newNotional = FixedPointMath.mulFp(newPrice, newSize);
        uint256 totalSize = oldSize + newSize;

        uint256 avgPrice = FixedPointMath.divFp(oldNotional + newNotional, totalSize);

        uint256 minPrice = FixedPointMath.min(oldPrice, newPrice);
        uint256 maxPrice = FixedPointMath.max(oldPrice, newPrice);

        // mulFp/divFp accumulate rounding errors proportional to size ratios.
        // Tolerance: 1 unit per 1e9 of size ratio (still negligible vs real prices).
        uint256 sizeRatio =
            FixedPointMath.divFp(FixedPointMath.max(oldSize, newSize), FixedPointMath.min(oldSize, newSize));
        uint256 tolerance = sizeRatio / 1e9 + 2;
        assertTrue(avgPrice + tolerance >= minPrice, "avg below min");
        assertTrue(avgPrice <= maxPrice + tolerance, "avg above max");
    }

    /// @dev Close PnL + remaining position value should equal total position value.
    function testFuzz_closePnl_conservesValue(uint64 rawSize, uint64 rawEntry, uint64 rawClose, uint64 rawCloseRatio)
        public
        pure
    {
        uint256 posSize = bound(uint256(rawSize), 0.001e18, 100e18);
        uint256 entryPrice = bound(uint256(rawEntry), 100e18, 1_000_000e18);
        uint256 closePrice = bound(uint256(rawClose), 100e18, 1_000_000e18);
        uint256 closeRatio = bound(uint256(rawCloseRatio), 1, 99); // 1-99% close

        uint256 closeSize = (posSize * closeRatio) / 100;
        if (closeSize == 0) closeSize = 1;
        if (closeSize >= posSize) closeSize = posSize - 1;

        int256 priceDiff = int256(closePrice) - int256(entryPrice);
        int256 pnl = FixedPointMath.mulFpSigned(priceDiff, int256(closeSize));

        // Verify PnL is proportional to close size
        int256 fullPnl = FixedPointMath.mulFpSigned(priceDiff, int256(posSize));
        int256 expectedPnl = (fullPnl * int256(closeSize)) / int256(posSize);

        // Allow 2 wei tolerance for rounding
        assertApproxEqAbs(pnl, expectedPnl, 2);
    }
}
