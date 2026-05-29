// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import { IMarketFactory } from "./interfaces/IMarketFactory.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";

contract MarketFactory is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IMarketFactory {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    error MarketNotFound(uint256 marketId);

    IMarginEngine public marginEngine;
    IOracleAdapter public oracle;

    uint256 private _nextMarketId;
    mapping(uint256 => MarketParams) private _marketParams;
    mapping(uint256 => bool) private _marketActive;
    mapping(uint256 => bool) private _marketExists;

    uint256[45] private __gap;

    event MarketCreated(uint256 indexed marketId, MarketParams params);
    event MarketPaused(uint256 indexed marketId);
    event MarketUnpaused(uint256 indexed marketId);

    function initialize(address admin, address marginEngine_, address oracle_) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        marginEngine = IMarginEngine(marginEngine_);
        oracle = IOracleAdapter(oracle_);
        _nextMarketId = 1;
    }

    function createMarket(MarketParams calldata params) external onlyRole(ADMIN_ROLE) returns (uint256 marketId) {
        marketId = _nextMarketId++;
        _marketParams[marketId] = params;
        _marketActive[marketId] = true;
        _marketExists[marketId] = true;

        marginEngine.setMarketConfig(
            marketId,
            IMarginEngine.MarketConfig({
                maxLeverage: _deriveMaxLeverage(params.initialMarginRate),
                initialMarginRate: params.initialMarginRate,
                maintenanceMarginRate: params.maintenanceMarginRate,
                tickSize: params.tickSize,
                lotSize: params.lotSize,
                maxOrderSize: params.maxOrderSize,
                minOrderSize: params.minOrderSize
            })
        );
        oracle.setMarketOracle(marketId, params.pythPriceId, params.oracleStalenessThreshold);
        oracle.setTickSize(marketId, params.tickSize);

        emit MarketCreated(marketId, params);
    }

    function pauseMarket(uint256 marketId) external onlyRole(ADMIN_ROLE) {
        _requireMarket(marketId);
        _marketActive[marketId] = false;
        emit MarketPaused(marketId);
    }

    function unpauseMarket(uint256 marketId) external onlyRole(ADMIN_ROLE) {
        _requireMarket(marketId);
        _marketActive[marketId] = true;
        emit MarketUnpaused(marketId);
    }

    function marketActive(uint256 marketId) external view returns (bool) {
        return _marketActive[marketId];
    }

    function marketParams(uint256 marketId) external view returns (MarketParams memory params) {
        _requireMarket(marketId);
        return _marketParams[marketId];
    }

    function _deriveMaxLeverage(uint256 initialMarginRate) internal pure returns (uint256) {
        if (initialMarginRate == 0) return 0;
        return 1e36 / initialMarginRate;
    }

    function _requireMarket(uint256 marketId) internal view {
        if (!_marketExists[marketId]) revert MarketNotFound(marketId);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
