// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IRouter } from "./interfaces/IRouter.sol";
import { IVault } from "./interfaces/IVault.sol";
import { ISettlement } from "./interfaces/ISettlement.sol";
import { IMarketFactory } from "./interfaces/IMarketFactory.sol";

contract Router is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IRouter {
    using SafeERC20 for IERC20;

    error InvalidIntent();
    error MarketPaused(uint256 marketId);

    IVault private _vault;
    ISettlement private _settlement;
    IMarketFactory private _marketFactory;
    IERC20 private _usdc;
    uint256 private _forceIncludeFeeUsdc;

    uint256[45] private __gap;

    function initialize(
        address admin,
        address vault_,
        address settlement_,
        address marketFactory_,
        address usdc_,
        uint256 forceIncludeFeeUsdc_
    ) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        _vault = IVault(vault_);
        _settlement = ISettlement(settlement_);
        _marketFactory = IMarketFactory(marketFactory_);
        _usdc = IERC20(usdc_);
        _forceIncludeFeeUsdc = forceIncludeFeeUsdc_;

        _usdc.forceApprove(vault_, type(uint256).max);
    }

    function deposit(uint256 usdcAmount) external {
        _usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        _vault.depositFor(msg.sender, usdcAmount);
    }

    function withdraw(uint256 usdcAmount) external {
        _vault.withdrawTo(msg.sender, usdcAmount, msg.sender);
    }

    function forceInclude(bytes calldata intent, bytes calldata sig) external {
        uint256 marketId = _decodeMarketId(intent);
        if (!_marketFactory.marketActive(marketId)) revert MarketPaused(marketId);

        if (_forceIncludeFeeUsdc != 0) {
            _usdc.safeTransferFrom(msg.sender, address(this), _forceIncludeFeeUsdc);
            _vault.depositInsuranceFund(_forceIncludeFeeUsdc);
        }

        _settlement.forceIncludeFor(msg.sender, intent, sig);
    }

    function _decodeMarketId(bytes calldata intent) internal pure returns (uint256 marketId) {
        if (intent.length < 32) revert InvalidIntent();
        assembly ("memory-safe") {
            marketId := calldataload(intent.offset)
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
