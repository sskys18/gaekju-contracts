// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILiquidationEngine {
    struct LiquidationConfig {
        uint256 liquidatorFeeRate;
        uint256 insuranceFundFeeRate;
    }

    function isLiquidatable(address account, uint256 marketId) external view returns (bool);
    function liquidate(address account, uint256 marketId) external;
    function autoDeleverage(uint256 marketId, address bankruptAccount) external;

    event PositionLiquidated(
        address indexed account,
        uint256 indexed marketId,
        address indexed liquidator,
        int256 sizeReduced,
        uint256 liquidationPrice,
        uint256 liquidatorFee,
        uint256 insuranceFee,
        bool isFullLiquidation
    );
    event AutoDeleveraged(
        address indexed bankruptAccount,
        address indexed counterparty,
        uint256 indexed marketId,
        int256 sizeReduced,
        uint256 price
    );
}
