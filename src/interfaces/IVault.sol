// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVault {
    // Per-account, per-fill balance delta emitted by the zkVM matcher and
    // applied by Vault.applyBatchDelta. Aggregate sum across a batch must
    // satisfy fills-conservation (spec §10, §15.3.1). `account == address(0)`
    // marks an insurance-fund-only row; all other rows use `account` as target.
    struct BalanceDelta {
        address account;
        int256 freeDelta;
        int256 lockedMarginDelta;
        int256 orderMarginDelta;
        int256 realizedPnlDelta; // informational; credited via freeDelta
        int256 insuranceFundDelta;
    }

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function depositFor(address account, uint256 usdcAmount) external;
    function withdrawTo(address account, uint256 usdcAmount, address recipient) external;
    function depositInsuranceFund(uint256 usdcAmount) external;

    function applyBatchDelta(uint64 batchNonce, BalanceDelta[] calldata deltas) external;
    function lastAppliedBatchNonce() external view returns (uint64);

    function balances(address account) external view returns (uint256);
    function lockedMargin(address account) external view returns (uint256);
    function orderMargin(address account) external view returns (uint256);
    function insuranceFund() external view returns (uint256);
    function totalDeposits() external view returns (uint256);

    function lockMargin(address account, uint256 amount) external;
    function unlockMargin(address account, uint256 amount) external;
    function lockOrderMargin(address account, uint256 amount) external;
    function unlockOrderMargin(address account, uint256 amount) external;
    function transferToInsuranceFund(uint256 amount) external;
    function drawFromInsuranceFund(uint256 amount) external;
    function realizePnl(address account, int256 pnl) external returns (uint256 deficit);

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event MarginLocked(address indexed account, uint256 amount);
    event MarginUnlocked(address indexed account, uint256 amount);
    event OrderMarginLocked(address indexed account, uint256 amount);
    event OrderMarginUnlocked(address indexed account, uint256 amount);
    event PnlRealized(address indexed account, int256 amount);
    event InsuranceFundDeposited(address indexed account, uint256 amount);
    event BatchDeltaApplied(uint64 indexed batchNonce, uint256 deltaCount);
}
