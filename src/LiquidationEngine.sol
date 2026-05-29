// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ILiquidationEngine } from "./interfaces/ILiquidationEngine.sol";
import { IPositionManager } from "./interfaces/IPositionManager.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IMarginEngine } from "./interfaces/IMarginEngine.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

contract LiquidationEngine is ILiquidationEngine, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    error NotLiquidatable();
    error NoPosition();
    error NotBankrupt();
    error NoCounterparties();

    IVault public vault;
    IPositionManager public positionManager;
    IMarginEngine public marginEngine;
    IOracleAdapter public oracle;

    mapping(uint256 => LiquidationConfig) public liquidationConfigs;

    uint256[50] private __gap;

    function initialize(
        address _vault,
        address _positionManager,
        address _marginEngine,
        address _oracle,
        address _admin
    ) external initializer {
        __AccessControl_init();
        vault = IVault(_vault);
        positionManager = IPositionManager(_positionManager);
        marginEngine = IMarginEngine(_marginEngine);
        oracle = IOracleAdapter(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setLiquidationConfig(uint256 marketId, LiquidationConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        liquidationConfigs[marketId] = config;
    }

    function isLiquidatable(address account, uint256 marketId) public view returns (bool) {
        IPositionManager.Position memory pos = positionManager.getPosition(account, marketId);
        if (pos.size == 0) return false;

        uint256 marginRatio = positionManager.getMarginRatio(account, marketId);
        (,, uint256 mmr,,,,) = marginEngine.configs(marketId);

        return marginRatio < mmr;
    }

    function liquidate(address account, uint256 marketId) external nonReentrant {
        IPositionManager.Position memory pos = positionManager.getPosition(account, marketId);
        if (pos.size == 0) revert NoPosition();

        // Stub: settleFunding would go here in Phase 3

        if (!isLiquidatable(account, marketId)) revert NotLiquidatable();

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 absSize = FixedPointMath.abs(pos.size);
        uint256 notional = FixedPointMath.mulFp(absSize, markPrice);

        LiquidationConfig memory config = liquidationConfigs[marketId];
        uint256 totalFeeRate = config.liquidatorFeeRate + config.insuranceFundFeeRate;

        IMarginEngine.MarketConfig memory mktCfg = marginEngine.getConfig(marketId);

        // Calculate equity
        int256 unrealizedPnl = positionManager.getUnrealizedPnl(account, marketId);
        int256 equity = int256(pos.collateral) + unrealizedPnl;

        bool isFullLiquidation;
        uint256 reduceSize;

        if (equity <= 0 || absSize <= mktCfg.minOrderSize) {
            isFullLiquidation = true;
            reduceSize = absSize;
        } else {
            // Partial liquidation formula:
            //   equity - reduceSize * markPrice * feeRate = IMR * (notional - reduceSize * markPrice)
            //   reduceSize = (IMR * notional - equity) / (markPrice * (IMR - feeRate))
            uint256 imrTimesNotional = FixedPointMath.mulFp(mktCfg.initialMarginRate, notional);
            int256 numerator = int256(imrTimesNotional) - equity;

            if (numerator <= 0) revert NotLiquidatable();

            if (mktCfg.initialMarginRate <= totalFeeRate) {
                isFullLiquidation = true;
                reduceSize = absSize;
            } else {
                uint256 denom = FixedPointMath.mulFp(markPrice, mktCfg.initialMarginRate - totalFeeRate);
                reduceSize = FixedPointMath.divFp(uint256(numerator), denom);

                if (reduceSize >= absSize || (absSize - reduceSize) < mktCfg.minOrderSize) {
                    isFullLiquidation = true;
                    reduceSize = absSize;
                }
            }
        }

        // Calculate fees
        uint256 liqNotional = FixedPointMath.mulFp(reduceSize, markPrice);
        uint256 liquidatorFee = FixedPointMath.mulFp(liqNotional, config.liquidatorFeeRate);
        uint256 insuranceFee = FixedPointMath.mulFp(liqNotional, config.insuranceFundFeeRate);
        uint256 totalFee = liquidatorFee + insuranceFee;

        // Execute liquidation via PositionManager; capture any uncovered deficit
        int256 sizeDelta = pos.size > 0 ? -int256(reduceSize) : int256(reduceSize);
        uint256 positionDeficit = positionManager.liquidatePosition(account, marketId, sizeDelta, markPrice);

        // Distribute fees from account's released balance
        if (vault.balances(account) >= totalFee) {
            vault.realizePnl(account, -int256(totalFee));
        } else {
            uint256 available = vault.balances(account);
            if (available > 0) {
                vault.realizePnl(account, -int256(available));
            }
            totalFee = available;
            if (totalFee > 0) {
                liquidatorFee =
                    (totalFee * config.liquidatorFeeRate) / (config.liquidatorFeeRate + config.insuranceFundFeeRate);
                insuranceFee = totalFee - liquidatorFee;
            } else {
                liquidatorFee = 0;
                insuranceFee = 0;
            }
        }

        if (liquidatorFee > 0) {
            vault.realizePnl(msg.sender, int256(liquidatorFee));
        }
        if (insuranceFee > 0) {
            vault.transferToInsuranceFund(insuranceFee);
        }

        // Cover any position deficit from insurance fund
        if (positionDeficit > 0) {
            uint256 fundBalance = vault.insuranceFund();
            if (fundBalance >= positionDeficit) {
                vault.drawFromInsuranceFund(positionDeficit);
                vault.realizePnl(account, int256(positionDeficit));
            }
            // If insurance fund insufficient, position remains underwater — ADL handles it
        }

        emit PositionLiquidated(
            account, marketId, msg.sender, sizeDelta, markPrice, liquidatorFee, insuranceFee, isFullLiquidation
        );
    }

    function autoDeleverage(uint256 marketId, address bankruptAccount) external nonReentrant {
        IPositionManager.Position memory bankruptPos = positionManager.getPosition(bankruptAccount, marketId);
        if (bankruptPos.size == 0) revert NoPosition();

        int256 unrealizedPnl = positionManager.getUnrealizedPnl(bankruptAccount, marketId);
        int256 equity = int256(bankruptPos.collateral) + unrealizedPnl;
        if (equity > 0) revert NotBankrupt();

        uint256 markPrice = oracle.getMarkPrice(marketId);
        uint256 absSize = FixedPointMath.abs(bankruptPos.size);

        address[] memory holders = positionManager.getPositionHolders(marketId);
        if (holders.length == 0) revert NoCounterparties();

        // Find most profitable opposite-side position
        address bestTarget;
        int256 bestPnl = type(int256).min;

        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == bankruptAccount) continue;

            IPositionManager.Position memory pos = positionManager.getPosition(holders[i], marketId);
            bool isOpposite = (bankruptPos.size > 0 && pos.size < 0) || (bankruptPos.size < 0 && pos.size > 0);
            if (!isOpposite) continue;

            int256 pnl = positionManager.getUnrealizedPnl(holders[i], marketId);
            if (pnl > bestPnl) {
                bestPnl = pnl;
                bestTarget = holders[i];
            }
        }

        if (bestTarget == address(0)) revert NoCounterparties();

        IPositionManager.Position memory targetPos = positionManager.getPosition(bestTarget, marketId);
        uint256 adlSize = FixedPointMath.min(absSize, FixedPointMath.abs(targetPos.size));

        int256 bankruptDelta = bankruptPos.size > 0 ? -int256(adlSize) : int256(adlSize);
        uint256 bankruptDeficit = positionManager.liquidatePosition(bankruptAccount, marketId, bankruptDelta, markPrice);

        int256 targetDelta = targetPos.size > 0 ? -int256(adlSize) : int256(adlSize);
        positionManager.liquidatePosition(bestTarget, marketId, targetDelta, markPrice);

        // Cover bankrupt account deficit from insurance fund if possible
        if (bankruptDeficit > 0) {
            uint256 fundBalance = vault.insuranceFund();
            if (fundBalance >= bankruptDeficit) {
                vault.drawFromInsuranceFund(bankruptDeficit);
                vault.realizePnl(bankruptAccount, int256(bankruptDeficit));
            }
        }

        emit AutoDeleveraged(bankruptAccount, bestTarget, marketId, bankruptDelta, markPrice);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
