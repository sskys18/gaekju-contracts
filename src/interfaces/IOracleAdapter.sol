// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IOracleAdapter {
    function getMarkPrice(uint256 marketId) external view returns (uint256);
    function getIndexPrice(uint256 marketId) external view returns (uint256);
    function updatePrice(uint256 marketId, bytes[] calldata priceUpdateData) external payable;
    function setMarketOracle(uint256 marketId, bytes32 pythPriceId, uint256 stalenessThreshold) external;
    function setTickSize(uint256 marketId, uint256 tickSize) external;

    event PriceUpdated(uint256 indexed marketId, uint256 price, uint256 timestamp);
}
