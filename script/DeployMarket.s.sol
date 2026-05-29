// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";

import { MarketFactory } from "../src/MarketFactory.sol";
import { IMarketFactory } from "../src/interfaces/IMarketFactory.sol";

contract DeployMarket is Script {
    function run() external returns (uint256 btcId, uint256 ethId) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        MarketFactory marketFactory = MarketFactory(vm.envAddress("MARKET_FACTORY"));

        vm.startBroadcast(privateKey);
        btcId = marketFactory.createMarket(_btcParams());
        ethId = marketFactory.createMarket(_ethParams());
        vm.stopBroadcast();

        require(btcId == 1, "btc market id");
        require(ethId == 2, "eth market id");

        console2.log("BTC-USD market id", btcId);
        console2.log("ETH-USD market id", ethId);
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
            oracleStalenessThreshold: 60,
            fundingInterval: 1 hours,
            maxFundingRate: 5e15,
            minOrderSize: 0.01e18,
            maxOrderSize: 250e18,
            makerFeeRate: 4e14,
            takerFeeRate: 9e14
        });
    }
}
