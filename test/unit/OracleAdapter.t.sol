// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/OracleAdapter.sol";
import "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract OracleAdapterTest is Test {
    OracleAdapter public oracle;
    MockPyth public mockPyth;
    address public admin = makeAddr("admin");
    uint256 public constant MARKET_BTC = 0;
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        vm.warp(1_000_000);
        mockPyth = new MockPyth();

        OracleAdapter impl = new OracleAdapter();
        bytes memory initData = abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oracle = OracleAdapter(address(proxy));

        // Configure BTC market
        vm.prank(admin);
        oracle.setMarketOracle(MARKET_BTC, BTC_PYTH_ID, 60); // 60s staleness

        // Set a valid BTC price: $60,000 with expo=-8
        // Pyth stores price as int64 with exponent. $60,000 = 6000000000000 * 10^(-8)
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);
    }

    function test_getIndexPrice() public view {
        uint256 price = oracle.getIndexPrice(MARKET_BTC);
        assertEq(price, 60_000e18);
    }

    function test_getMarkPrice_noOrderbook() public view {
        // No orderbook set -> markPrice = oraclePrice
        uint256 price = oracle.getMarkPrice(MARKET_BTC);
        assertEq(price, 60_000e18);
    }

    function test_stalePrice_reverts() public {
        // Advance time past staleness threshold
        vm.warp(block.timestamp + 120);

        vm.expectRevert();
        oracle.getIndexPrice(MARKET_BTC);
    }

    function test_confidenceBand_tooWide_reverts() public {
        // Set conf > 1% of price. price=60000e8, 1% = 600e8.
        // conf = 700e8 > 1% -> should revert
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 70_000_000_000, -8);

        vm.expectRevert(OracleAdapter.ConfidenceTooWide.selector);
        oracle.getIndexPrice(MARKET_BTC);
    }

    function test_negativePrice_reverts() public {
        mockPyth.setPrice(BTC_PYTH_ID, -100, 1, -8);

        vm.expectRevert();
        oracle.getIndexPrice(MARKET_BTC);
    }
}
