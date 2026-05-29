# gaekju-contracts

ZK-settlement-layer contracts for Korean tokenized securities (STO), targeting Giwa Chain (OP Stack L2).

> **Version:** v0.1 (initial public release, pre-audit).
> **Status:** Pre-mainnet. Testnet deploy 2026-05-29. Pre-audit. Use at your own risk.
> **License:** MIT.
> **Pivot context:** This codebase originated as a perpetual-DEX project and pivoted to RWA settlement on 2026-05-27. Perp-era contracts (`PositionManager`, `MarginEngine`, `LiquidationEngine`) are **Phase 1 baseline** and will be removed during the Phase 2 RWA refactor.

## What this is

- The **contract surface** for a planned ZK settlement pipeline: signed EIP-712 intents → off-chain Rust sequencer → SP1 zkVM proof → `Settlement.sol` verifies and applies state delta.
- v0.1 ships **contracts only**. The off-chain Rust sequencer and SP1 prover are private (Phase 1 sequencer exists; prover is planned but not yet built).
- Intended deployment: settlement and audit overlay for licensed Korean operators (증권사, 계좌관리기관, KSD). Not a venue operator. Not the legal book of record.

## What this is not

- Not a token launch. No governance token. No KR ICO.
- Not a derivatives product (perp era is being unwound).
- Not retail-facing.

## Build

```
git clone https://github.com/sskys18/gaekju-contracts.git
cd gaekju-contracts
forge build
forge test -vvv
```

Dependencies (`forge-std`, OpenZeppelin contracts + upgradeable, Pyth SDK) are vendored under `lib/` — no `forge install` or submodule init needed. Requires Foundry (`foundryup`), solc 0.8.28, via-IR enabled, optimizer 200 runs.

## Deployments

| Network | Settlement.sol | Vault.sol | OracleAdapter.sol | Router.sol | Block |
|---------|----------------|-----------|-------------------|------------|-------|
| Giwa testnet | pending 2026-05-29 deploy | pending | pending | pending | pending |

Canonical deployment addresses will be published under [`deployments/`](./deployments/) after the D-2 testnet deploy. v0.1 ships with the directory empty.

## Intended architecture

```
              ┌──────────────────────────────┐
investor ──▶ │ Rust sequencer (private, P1) │ ──▶ batch ──┐
              └──────────────────────────────┘            │
                                                          ▼
              ┌──────────────────────────────┐    ┌────────────────┐
              │ SP1 zkVM prover (planned)    │──▶ │ Settlement.sol │  ← this repo (v0.1)
              └──────────────────────────────┘    └────────────────┘
                                                          │
                                                          ▼
                                                 Vault.sol / Router.sol / OracleAdapter.sol  ← this repo (v0.1)
```

Off-chain components (sequencer in development, prover planned) live in a private repo. v0.1 of this public repo is **contracts-only**; off-chain pipeline is not included.

## Disclosures

- **Unaudited.** Testnet only. No production use.
- **Phase 1 contracts (perp) present but deprecated** — removed in Phase 2.
- **Active refactor.** Public `main` will track Phase 2 work.

## Contact

`jcs25822@gmail.com` — 정산 도입 문의
