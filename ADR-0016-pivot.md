# ADR-0016: Pivot from perpetual DEX to RWA settlement layer (public summary)

> **Date:** 2026-05-27
> **Status:** Accepted
> **Scope of this file:** public summary. The full internal ADR remains in the private `gaekju-core` repo; this file is the public summary.

## Decision

Pivot the project from a perpetual derivatives DEX (ADR-0001 – ADR-0015) to a ZK settlement and audit layer for Korean tokenized securities (STO).

## What stays

- Off-chain Rust sequencer + SP1 zkVM prover + on-chain `Settlement.sol` architecture (domain-agnostic for orderbook-settled assets).
- `Vault.sol`, `OracleAdapter.sol`, `Router.sol`, `MarketFactory.sol`, `Settlement.sol` — refactored in Phase 2 (see ADR-0017 §Phase 2 public summary).
- UUPS proxy pattern; 18-decimal fixed-point math; Foundry build pipeline.

## What gets dropped (Phase 2)

- `PositionManager.sol`, `MarginEngine.sol`, `LiquidationEngine.sol` — perp-era contracts; no leverage in the spot RWA product.
- `crates/gaekju-mirror` — Lighter.xyz liquidity bridge; perp-era artifact.
- (Note: `FundingRate.sol` is referenced in the original internal ADR table as a drop target, but the contract was never actually written.)

## What is new

- `Holdings.sol` (balance-only), `AssetRegistry.sol`, role-separated `Router`, NAV-attestor `OracleAdapter`, KRW-shaped `Vault` cash leg.
- `crates/gaekju-prover` (SP1 zkVM prover) — planned, not yet built. v0.1 of this public repo ships the contract surface only; the off-chain pipeline is private and incomplete.

## Why

The product moves to ZK-proven settlement for tokenized Korean securities. Specifics on the Korean regulatory landscape, broker/KSD positioning, and timing are kept in the private full ADR. Public reviewers wanting more should contact `jcs25822@gmail.com`.

## Status of this codebase

- v0.1 (this public repo) ships the Phase 1 baseline as-is: 103/103 tests pass, perp-era contracts still compiled but deprecated.
- Phase 2 refactor schedule and scope: see [ADR-0017](./ADR-0017-repo-split.md) §Phase 2 public summary.
