// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IVault } from "./interfaces/IVault.sol";

contract Vault is IVault, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    /// @dev USDC uses 6 decimals; internal accounting uses 18. Scale factor = 1e12.
    uint256 internal constant DECIMAL_SCALE = 1e12;

    error InsufficientBalance();
    error InsufficientLockedMargin();
    error InsufficientOrderMargin();
    error InsufficientInsuranceFund();
    error ZeroAmount();
    error StaleBatchNonce();
    error FillsConservationViolated();
    error NegativeBalance();

    IERC20 public usdc;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lockedMargin;
    mapping(address => uint256) public orderMargin;
    uint256 public insuranceFund;
    uint256 public totalDeposits;
    uint64 public lastAppliedBatchNonce;

    uint256[49] private __gap;

    function initialize(address _usdc, address _admin) external initializer {
        usdc = IERC20(_usdc);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function grantSettlement(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(SETTLEMENT_ROLE, account);
    }

    function grantRouter(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ROUTER_ROLE, account);
    }

    function deposit(uint256 usdcAmount) external nonReentrant {
        _deposit(msg.sender, usdcAmount);
    }

    function depositFor(address account, uint256 usdcAmount) external nonReentrant {
        _deposit(account, usdcAmount);
    }

    function withdraw(uint256 internalAmount) external nonReentrant {
        _withdrawInternal(msg.sender, internalAmount, msg.sender);
    }

    function withdrawTo(address account, uint256 usdcAmount, address recipient) external nonReentrant {
        if (msg.sender != account && !hasRole(ROUTER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ROUTER_ROLE);
        }
        _withdrawInternal(account, usdcAmount * DECIMAL_SCALE, recipient);
    }

    function depositInsuranceFund(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 internalAmount = usdcAmount * DECIMAL_SCALE;

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        insuranceFund += internalAmount;
        totalDeposits += internalAmount;

        emit InsuranceFundDeposited(msg.sender, internalAmount);
    }

    function lockMargin(address account, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        lockedMargin[account] += amount;
        emit MarginLocked(account, amount);
    }

    function unlockMargin(address account, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        if (lockedMargin[account] < amount) revert InsufficientLockedMargin();
        lockedMargin[account] -= amount;
        balances[account] += amount;
        emit MarginUnlocked(account, amount);
    }

    function lockOrderMargin(address account, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        if (balances[account] < amount) revert InsufficientBalance();
        balances[account] -= amount;
        orderMargin[account] += amount;
        emit OrderMarginLocked(account, amount);
    }

    function unlockOrderMargin(address account, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        if (orderMargin[account] < amount) revert InsufficientOrderMargin();
        orderMargin[account] -= amount;
        balances[account] += amount;
        emit OrderMarginUnlocked(account, amount);
    }

    function transferToInsuranceFund(uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        insuranceFund += amount;
    }

    function drawFromInsuranceFund(uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        if (insuranceFund < amount) revert InsufficientInsuranceFund();
        insuranceFund -= amount;
    }

    function realizePnl(address account, int256 pnl) external onlyRole(SETTLEMENT_ROLE) returns (uint256 deficit) {
        if (pnl >= 0) {
            balances[account] += uint256(pnl);
            totalDeposits += uint256(pnl);
            emit PnlRealized(account, pnl);
            return 0;
        }
        uint256 loss = uint256(-pnl);
        // Exhaust free balance first
        if (loss <= balances[account]) {
            balances[account] -= loss;
            totalDeposits -= loss;
            emit PnlRealized(account, pnl);
            return 0;
        }
        uint256 fromBalance = balances[account];
        loss -= fromBalance;
        totalDeposits -= fromBalance;
        balances[account] = 0;
        // Then exhaust locked margin
        uint256 fromLocked = loss <= lockedMargin[account] ? loss : lockedMargin[account];
        lockedMargin[account] -= fromLocked;
        totalDeposits -= fromLocked;
        deficit = loss - fromLocked; // uncovered loss — caller must draw from insurance fund
        emit PnlRealized(account, pnl);
    }

    /// @notice Apply a batch of per-account balance deltas proved by the matcher.
    /// @dev spec §15.3 step 10. Sole writer for free/order/position-margin and
    ///      realized-PnL under Path B. Fills-conservation (§10) enforced: the
    ///      sum of all account deltas plus insuranceFundDelta equals zero.
    function applyBatchDelta(uint64 batchNonce_, BalanceDelta[] calldata deltas) external onlyRole(SETTLEMENT_ROLE) {
        if (batchNonce_ <= lastAppliedBatchNonce) revert StaleBatchNonce();

        int256 conservationSum;

        for (uint256 i; i < deltas.length; ++i) {
            BalanceDelta calldata d = deltas[i];

            conservationSum += d.freeDelta + d.lockedMarginDelta + d.orderMarginDelta + d.insuranceFundDelta;

            if (d.insuranceFundDelta != 0) {
                if (d.insuranceFundDelta > 0) {
                    insuranceFund += uint256(d.insuranceFundDelta);
                } else {
                    uint256 dec = uint256(-d.insuranceFundDelta);
                    if (insuranceFund < dec) revert InsufficientInsuranceFund();
                    insuranceFund -= dec;
                }
            }

            if (d.account == address(0)) continue;

            _applyBucketDelta(balances, d.account, d.freeDelta);
            _applyBucketDelta(lockedMargin, d.account, d.lockedMarginDelta);
            _applyBucketDelta(orderMargin, d.account, d.orderMarginDelta);

            if (d.realizedPnlDelta != 0) emit PnlRealized(d.account, d.realizedPnlDelta);
        }

        if (conservationSum != 0) revert FillsConservationViolated();

        lastAppliedBatchNonce = batchNonce_;
        emit BatchDeltaApplied(batchNonce_, deltas.length);
    }

    function _applyBucketDelta(mapping(address => uint256) storage bucket, address account, int256 delta) internal {
        if (delta == 0) return;
        if (delta > 0) {
            bucket[account] += uint256(delta);
            totalDeposits += uint256(delta);
        } else {
            uint256 dec = uint256(-delta);
            if (bucket[account] < dec) revert NegativeBalance();
            bucket[account] -= dec;
            totalDeposits -= dec;
        }
    }

    function _deposit(address account, uint256 usdcAmount) internal {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 internalAmount = usdcAmount * DECIMAL_SCALE;

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        balances[account] += internalAmount;
        totalDeposits += internalAmount;

        emit Deposited(account, internalAmount);
    }

    function _withdrawInternal(address account, uint256 internalAmount, address recipient) internal {
        if (internalAmount == 0) revert ZeroAmount();
        if (balances[account] < internalAmount) revert InsufficientBalance();

        balances[account] -= internalAmount;
        totalDeposits -= internalAmount;

        usdc.safeTransfer(recipient, internalAmount / DECIMAL_SCALE);

        emit Withdrawn(account, internalAmount);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}
