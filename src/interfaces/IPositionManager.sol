// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPositionManager {
    struct Position {
        int256 size;
        uint256 entryPrice;
        uint256 collateral;
        int256 lastCumulativeFunding;
        uint256 lastUpdated;
    }

    // Matcher-computed position snapshot; PM writes it verbatim. Vault bucket
    // effects live in BalanceDelta[], applied by Settlement before fills.
    struct Fill {
        address account;
        uint256 marketId;
        int256 newSize; // 0 = closed
        uint256 newEntryPrice;
        uint256 newCollateral;
        int256 newCumulativeFunding;
        int256 sizeDelta; // event payload
        uint256 fillPrice; // event payload
        int256 realizedPnl; // event payload
    }

    function applyBatchFills(uint64 batchNonce, Fill[] calldata fills) external;
    function lastAppliedBatchNonce() external view returns (uint64);

    function updatePosition(address account, uint256 marketId, int256 sizeDelta, uint256 fillPrice, uint256 marginDelta)
        external;

    function liquidatePosition(address account, uint256 marketId, int256 sizeDelta, uint256 liquidationPrice)
        external
        returns (uint256 deficit);

    function getPosition(address account, uint256 marketId) external view returns (Position memory);
    function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256);
    function getMarginRatio(address account, uint256 marketId) external view returns (uint256);
    function getPositionHolders(uint256 marketId) external view returns (address[] memory);
    function getPositionCount(uint256 marketId) external view returns (uint256);

    event PositionUpdated(
        address indexed account,
        uint256 indexed marketId,
        int256 newSize,
        uint256 entryPrice,
        uint256 collateral,
        int256 realizedPnl
    );
    event PositionClosed(address indexed account, uint256 indexed marketId, int256 realizedPnl);
}
