// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

contract PositionManager is IPositionManager, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    error OnlyLiquidationEngine();
    error NoPosition();
    error InsufficientBalance();
    error StaleBatchNonce();

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    IVault public vault;
    IMarginEngine public marginEngine;
    IOracleAdapter public oracle;
    address public liquidationEngine;

    mapping(address => mapping(uint256 => Position)) internal _positions;
    mapping(uint256 => EnumerableSet.AddressSet) internal _positionHolders;
    uint64 public lastAppliedBatchNonce;

    uint256[49] private __gap;

    modifier onlyLiquidationEngine() {
        if (msg.sender != liquidationEngine) revert OnlyLiquidationEngine();
        _;
    }

    function initialize(address _vault, address _marginEngine, address _oracle, address _admin) external initializer {
        __AccessControl_init();
        vault = IVault(_vault);
        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function grantSettlement(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(SETTLEMENT_ROLE, account);
    }

    function setLiquidationEngine(address _liquidationEngine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        liquidationEngine = _liquidationEngine;
    }

    function updatePosition(address account, uint256 marketId, int256 sizeDelta, uint256 fillPrice, uint256 marginDelta)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        _updatePositionInternal(account, marketId, sizeDelta, fillPrice, marginDelta);
    }

    /// @notice Write position snapshots from a proved batch.
    /// @dev spec §15.3 step 12, §15.3.1: position-state only. Vault buckets
    ///      are mutated separately via Vault.applyBatchDelta BEFORE this call.
    function applyBatchFills(uint64 batchNonce_, Fill[] calldata fills)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        if (batchNonce_ <= lastAppliedBatchNonce) revert StaleBatchNonce();

        for (uint256 i; i < fills.length; ++i) {
            Fill calldata f = fills[i];
            Position storage pos = _positions[f.account][f.marketId];

            if (f.newSize == 0) {
                emit PositionClosed(f.account, f.marketId, f.realizedPnl);
                delete _positions[f.account][f.marketId];
                _positionHolders[f.marketId].remove(f.account);
            } else {
                bool wasEmpty = pos.size == 0;
                pos.size = f.newSize;
                pos.entryPrice = f.newEntryPrice;
                pos.collateral = f.newCollateral;
                pos.lastCumulativeFunding = f.newCumulativeFunding;
                pos.lastUpdated = block.timestamp;

                if (wasEmpty) _positionHolders[f.marketId].add(f.account);

                emit PositionUpdated(f.account, f.marketId, f.newSize, f.newEntryPrice, f.newCollateral, f.realizedPnl);
            }
        }

        lastAppliedBatchNonce = batchNonce_;
    }

    function liquidatePosition(address account, uint256 marketId, int256 sizeDelta, uint256 liquidationPrice)
        external
        onlyLiquidationEngine
        nonReentrant
        returns (uint256 deficit)
    {
        return _liquidateInternal(account, marketId, sizeDelta, liquidationPrice);
    }

    function _updatePositionInternal(
        address account,
        uint256 marketId,
        int256 sizeDelta,
        uint256 fillPrice,
        uint256 marginDelta
    ) internal {
        Position storage pos = _positions[account][marketId];

        // Stub: settleFunding(account, marketId) — no-op until Phase 3

        // Convert order margin to position margin
        if (marginDelta > 0) {
            vault.unlockOrderMargin(account, marginDelta);
            vault.lockMargin(account, marginDelta);
        }

        int256 realizedPnl = 0;

        if (pos.size == 0) {
            // New position
            pos.size = sizeDelta;
            pos.entryPrice = fillPrice;
            pos.collateral = marginDelta;
            pos.lastUpdated = block.timestamp;
            _positionHolders[marketId].add(account);

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, 0);
        } else if (_sameDirection(pos.size, sizeDelta)) {
            // Increase — weighted average entry price
            uint256 oldNotional = FixedPointMath.mulFp(pos.entryPrice, FixedPointMath.abs(pos.size));
            uint256 newNotional = FixedPointMath.mulFp(fillPrice, FixedPointMath.abs(sizeDelta));
            uint256 totalSize = FixedPointMath.abs(pos.size) + FixedPointMath.abs(sizeDelta);

            pos.entryPrice = FixedPointMath.divFp(oldNotional + newNotional, totalSize);
            pos.size = pos.size + sizeDelta;
            pos.collateral += marginDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, 0);
        } else if (FixedPointMath.abs(sizeDelta) < FixedPointMath.abs(pos.size)) {
            // Partial close
            uint256 closeSize = FixedPointMath.abs(sizeDelta);
            uint256 absOldSize = FixedPointMath.abs(pos.size);

            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, closeSize);

            uint256 proportionalCollateral = FixedPointMath.mulDiv(pos.collateral, closeSize, absOldSize);
            pos.collateral -= proportionalCollateral;
            vault.unlockMargin(account, proportionalCollateral);
            vault.realizePnl(account, realizedPnl);

            pos.size = pos.size + sizeDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        } else if (FixedPointMath.abs(sizeDelta) == FixedPointMath.abs(pos.size)) {
            // Full close
            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, FixedPointMath.abs(pos.size));
            vault.unlockMargin(account, pos.collateral);
            vault.realizePnl(account, realizedPnl);

            emit PositionClosed(account, marketId, realizedPnl);

            delete _positions[account][marketId];
            _positionHolders[marketId].remove(account);
        } else {
            // Flip — close old, open new in opposite direction
            uint256 absOldSize = FixedPointMath.abs(pos.size);
            realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, fillPrice, absOldSize);
            vault.unlockMargin(account, pos.collateral);
            vault.realizePnl(account, realizedPnl);

            int256 remainingSize = pos.size + sizeDelta;
            uint256 absRemaining = FixedPointMath.abs(remainingSize);

            IMarginEngine.MarketConfig memory cfg = marginEngine.getConfig(marketId);
            uint256 newNotional = FixedPointMath.mulFp(absRemaining, fillPrice);
            uint256 newCollateral = FixedPointMath.mulFp(newNotional, cfg.initialMarginRate);

            vault.lockMargin(account, newCollateral);

            pos.size = remainingSize;
            pos.entryPrice = fillPrice;
            pos.collateral = newCollateral;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        }
    }

    function _liquidateInternal(address account, uint256 marketId, int256 sizeDelta, uint256 liquidationPrice)
        internal
        returns (uint256 deficit)
    {
        Position storage pos = _positions[account][marketId];
        if (pos.size == 0) revert NoPosition();

        uint256 closeSize = FixedPointMath.abs(sizeDelta);
        uint256 absOldSize = FixedPointMath.abs(pos.size);

        int256 realizedPnl = _calculateClosePnl(pos.size, pos.entryPrice, liquidationPrice, closeSize);

        if (closeSize == absOldSize) {
            // Full liquidation — unlockMargin BEFORE realizePnl (invariant from Phase 2)
            vault.unlockMargin(account, pos.collateral);
            deficit = vault.realizePnl(account, realizedPnl);

            emit PositionClosed(account, marketId, realizedPnl);
            delete _positions[account][marketId];
            _positionHolders[marketId].remove(account);
        } else {
            // Partial liquidation
            uint256 proportionalCollateral = FixedPointMath.mulDiv(pos.collateral, closeSize, absOldSize);
            pos.collateral -= proportionalCollateral;
            vault.unlockMargin(account, proportionalCollateral);
            deficit = vault.realizePnl(account, realizedPnl);
            pos.size = pos.size + sizeDelta;
            pos.lastUpdated = block.timestamp;

            emit PositionUpdated(account, marketId, pos.size, pos.entryPrice, pos.collateral, realizedPnl);
        }
    }

    function getPosition(address account, uint256 marketId) external view returns (Position memory) {
        return _positions[account][marketId];
    }

    function getUnrealizedPnl(address account, uint256 marketId) external view returns (int256) {
        Position memory pos = _positions[account][marketId];
        if (pos.size == 0) return 0;

        uint256 markPrice = oracle.getMarkPrice(marketId);
        return _computeUnrealizedPnl(pos.size, pos.entryPrice, markPrice);
    }

    function getMarginRatio(address account, uint256 marketId) external view returns (uint256) {
        Position memory pos = _positions[account][marketId];
        if (pos.size == 0) return type(uint256).max;

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 notional = FixedPointMath.mulFp(FixedPointMath.abs(pos.size), markPrice);
        int256 unrealizedPnl = _computeUnrealizedPnl(pos.size, pos.entryPrice, markPrice);

        int256 equity = int256(pos.collateral) + unrealizedPnl;
        if (equity <= 0) return 0;

        return FixedPointMath.divFp(uint256(equity), notional);
    }

    function getPositionHolders(uint256 marketId) external view returns (address[] memory) {
        return _positionHolders[marketId].values();
    }

    function getPositionCount(uint256 marketId) external view returns (uint256) {
        return _positionHolders[marketId].length();
    }

    function _sameDirection(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _calculateClosePnl(int256 posSize, uint256 entryPrice, uint256 closePrice, uint256 closeSize)
        internal
        pure
        returns (int256)
    {
        int256 priceDiff = int256(closePrice) - int256(entryPrice);
        int256 sign = posSize > 0 ? int256(1) : int256(-1);
        return FixedPointMath.mulFpSigned(priceDiff * sign, int256(closeSize));
    }

    function _computeUnrealizedPnl(int256 posSize, uint256 entryPrice, uint256 markPrice)
        internal
        pure
        returns (int256)
    {
        int256 priceDiff = int256(markPrice) - int256(entryPrice);
        return FixedPointMath.mulFpSigned(priceDiff, posSize);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
