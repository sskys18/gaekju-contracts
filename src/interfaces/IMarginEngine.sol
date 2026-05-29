// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IMarginEngine {
    struct MarketConfig {
        uint256 maxLeverage;
        uint256 initialMarginRate;
        uint256 maintenanceMarginRate;
        uint256 tickSize;
        uint256 lotSize;
        uint256 maxOrderSize;
        uint256 minOrderSize;
    }

    function configs(uint256 marketId)
        external
        view
        returns (
            uint256 maxLeverage,
            uint256 initialMarginRate,
            uint256 maintenanceMarginRate,
            uint256 tickSize,
            uint256 lotSize,
            uint256 maxOrderSize,
            uint256 minOrderSize
        );

    function getConfig(uint256 marketId) external view returns (MarketConfig memory);
    function setMarketConfig(uint256 marketId, MarketConfig calldata config) external;
    function checkInitialMargin(address account, uint256 marketId, uint256 orderSize, uint256 price)
        external
        view
        returns (bool);
    function getAvailableMargin(address account) external view returns (uint256);
    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) external view returns (uint256);
}
