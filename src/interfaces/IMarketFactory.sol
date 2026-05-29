// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMarketFactory {
    struct MarketParams {
        uint256 tickSize;
        uint256 lotSize;
        uint256 initialMarginRate;
        uint256 maintenanceMarginRate;
        bytes32 pythPriceId;
        uint256 oracleStalenessThreshold;
        uint256 fundingInterval;
        uint256 maxFundingRate;
        uint256 minOrderSize;
        uint256 maxOrderSize;
        uint256 makerFeeRate;
        uint256 takerFeeRate;
    }

    function createMarket(MarketParams calldata params) external returns (uint256 marketId);
    function pauseMarket(uint256 marketId) external;
    function unpauseMarket(uint256 marketId) external;
    function marketActive(uint256 marketId) external view returns (bool);
    function marketParams(uint256 marketId) external view returns (MarketParams memory params);
}
