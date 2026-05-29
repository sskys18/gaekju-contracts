// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

contract MarginEngine is IMarginEngine, UUPSUpgradeable, AccessControlUpgradeable {
    error OrderTooSmall();
    error OrderTooLarge();
    error PriceNotAligned();
    error MarketNotConfigured();

    IVault public vault;
    IOracleAdapter public oracle;

    mapping(uint256 => MarketConfig) internal _configs;

    uint256[50] private __gap;

    function initialize(address _vault, address _oracle, address _admin) external initializer {
        __AccessControl_init();
        vault = IVault(_vault);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setMarketConfig(uint256 marketId, MarketConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _configs[marketId] = config;
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
        )
    {
        MarketConfig storage c = _configs[marketId];
        return (
            c.maxLeverage,
            c.initialMarginRate,
            c.maintenanceMarginRate,
            c.tickSize,
            c.lotSize,
            c.maxOrderSize,
            c.minOrderSize
        );
    }

    function getConfig(uint256 marketId) external view returns (MarketConfig memory) {
        return _configs[marketId];
    }

    function getRequiredMargin(uint256 marketId, uint256 size, uint256 price) public view returns (uint256) {
        MarketConfig storage c = _configs[marketId];
        uint256 notional = FixedPointMath.mulFp(size, price);
        return FixedPointMath.mulFp(notional, c.initialMarginRate);
    }

    function getAvailableMargin(address account) public view returns (uint256) {
        return vault.balances(account);
    }

    function checkInitialMargin(address account, uint256 marketId, uint256 orderSize, uint256 price)
        external
        view
        returns (bool)
    {
        uint256 required = getRequiredMargin(marketId, orderSize, price);
        uint256 available = getAvailableMargin(account);
        return available >= required;
    }

    function validateOrder(uint256 marketId, uint256 size, uint256 price) external view {
        MarketConfig storage c = _configs[marketId];
        if (c.maxLeverage == 0) revert MarketNotConfigured();
        if (size < c.minOrderSize) revert OrderTooSmall();
        if (size > c.maxOrderSize) revert OrderTooLarge();
        if (c.tickSize != 0 && price % c.tickSize != 0) revert PriceNotAligned();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
