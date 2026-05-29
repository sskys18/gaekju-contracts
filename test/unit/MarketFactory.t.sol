// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MarketFactory } from "../../src/MarketFactory.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { Vault } from "../../src/Vault.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";

contract MarketFactoryTest is Test {
    MarketFactory public marketFactory;
    MarginEngine public marginEngine;
    OracleAdapter public oracle;
    Vault public vault;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public outsider = makeAddr("outsider");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );
        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );
        marginEngine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );
        marketFactory = MarketFactory(
            address(
                new ERC1967Proxy(
                    address(new MarketFactory()),
                    abi.encodeCall(MarketFactory.initialize, (admin, address(marginEngine), address(oracle)))
                )
            )
        );

        vm.startPrank(admin);
        marginEngine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        vm.stopPrank();
    }

    function test_createMarket_writesRegistryAndDependencies() public {
        IMarketFactory.MarketParams memory params = _btcParams();

        vm.prank(admin);
        uint256 marketId = marketFactory.createMarket(params);

        assertEq(marketId, 1);
        assertTrue(marketFactory.marketActive(marketId));

        IMarketFactory.MarketParams memory stored = marketFactory.marketParams(marketId);
        assertEq(stored.tickSize, params.tickSize);
        assertEq(stored.lotSize, params.lotSize);
        assertEq(stored.initialMarginRate, params.initialMarginRate);
        assertEq(stored.maintenanceMarginRate, params.maintenanceMarginRate);
        assertEq(stored.pythPriceId, params.pythPriceId);
        assertEq(stored.oracleStalenessThreshold, params.oracleStalenessThreshold);
        assertEq(stored.fundingInterval, params.fundingInterval);
        assertEq(stored.maxFundingRate, params.maxFundingRate);
        assertEq(stored.minOrderSize, params.minOrderSize);
        assertEq(stored.maxOrderSize, params.maxOrderSize);
        assertEq(stored.makerFeeRate, params.makerFeeRate);
        assertEq(stored.takerFeeRate, params.takerFeeRate);

        IMarginEngine.MarketConfig memory config = marginEngine.getConfig(marketId);
        assertEq(config.maxLeverage, 50e18);
        assertEq(config.initialMarginRate, params.initialMarginRate);
        assertEq(config.maintenanceMarginRate, params.maintenanceMarginRate);
        assertEq(config.tickSize, params.tickSize);
        assertEq(config.lotSize, params.lotSize);
        assertEq(config.maxOrderSize, params.maxOrderSize);
        assertEq(config.minOrderSize, params.minOrderSize);

        (bytes32 priceId, uint256 staleness) = oracle.marketOracles(marketId);
        assertEq(priceId, params.pythPriceId);
        assertEq(staleness, params.oracleStalenessThreshold);
        assertEq(oracle.tickSizes(marketId), params.tickSize);
    }

    function test_createMarket_incrementsIds() public {
        vm.startPrank(admin);
        uint256 btcId = marketFactory.createMarket(_btcParams());
        uint256 ethId = marketFactory.createMarket(_ethParams());
        vm.stopPrank();

        assertEq(btcId, 1);
        assertEq(ethId, 2);
    }

    function test_pauseAndUnpauseMarket() public {
        vm.prank(admin);
        uint256 marketId = marketFactory.createMarket(_btcParams());

        vm.prank(admin);
        marketFactory.pauseMarket(marketId);
        assertFalse(marketFactory.marketActive(marketId));

        vm.prank(admin);
        marketFactory.unpauseMarket(marketId);
        assertTrue(marketFactory.marketActive(marketId));
    }

    function test_onlyAdminCanMutateMarkets() public {
        vm.prank(outsider);
        vm.expectRevert();
        marketFactory.createMarket(_btcParams());

        vm.prank(admin);
        marketFactory.createMarket(_btcParams());

        vm.prank(outsider);
        vm.expectRevert();
        marketFactory.pauseMarket(1);

        vm.prank(outsider);
        vm.expectRevert();
        marketFactory.unpauseMarket(1);
    }

    function test_marketParams_unknownMarket_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.MarketNotFound.selector, 42));
        marketFactory.marketParams(42);
    }

    function _btcParams() internal pure returns (IMarketFactory.MarketParams memory) {
        return IMarketFactory.MarketParams({
            tickSize: 0.1e18,
            lotSize: 0.00001e18,
            initialMarginRate: 2e16,
            maintenanceMarginRate: 1e16,
            pythPriceId: bytes32(uint256(1)),
            oracleStalenessThreshold: 60,
            fundingInterval: 1 hours,
            maxFundingRate: 5e15,
            minOrderSize: 0.001e18,
            maxOrderSize: 100e18,
            makerFeeRate: 5e14,
            takerFeeRate: 1e15
        });
    }

    function _ethParams() internal pure returns (IMarketFactory.MarketParams memory) {
        return IMarketFactory.MarketParams({
            tickSize: 0.01e18,
            lotSize: 0.0001e18,
            initialMarginRate: 5e16,
            maintenanceMarginRate: 25e15,
            pythPriceId: bytes32(uint256(2)),
            oracleStalenessThreshold: 30,
            fundingInterval: 1 hours,
            maxFundingRate: 5e15,
            minOrderSize: 0.01e18,
            maxOrderSize: 250e18,
            makerFeeRate: 4e14,
            takerFeeRate: 9e14
        });
    }
}
