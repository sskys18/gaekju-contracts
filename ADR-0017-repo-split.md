# ADR-0017: Repo split — public contracts + private core

> **Status:** Accepted, 2026-05-28
> **Related:** ADR-0016 (perp → RWA pivot)

This ADR is self-contained. All reasoning needed for a public reviewer to understand the split appears below.

## Context

Pre-launch, Gaekju needs a public trust surface that reviewers can inspect. The original monorepo is private and mixes contracts with off-chain Rust components (proprietary). Verifying Settlement.sol on the giwa explorer is necessary but not sufficient — reviewers expect a code surface that exists outside a single explorer page.

## Decision

Two repositories:

1. **`gaekju-contracts`** (this repo, PUBLIC). Solidity contracts, tests, deploy scripts, Foundry config, README, LICENSE. Receives all future contract work.
2. **`gaekju-core`** (PRIVATE). Off-chain Rust components (sequencer; SP1 prover, planned); design + compliance documents; ADRs; plans; landing variants.

## Scope of v0.1

v0.1 ships the Phase 1 baseline as-is: contracts compile, 103/103 tests pass. Perp-era contracts (`PositionManager`, `MarginEngine`, `LiquidationEngine`) are present but deprecated per ADR-0016 and will be removed during Phase 2 (see below). Pre-audit. Testnet only.

Why ship perp-era contracts in v0.1? `Settlement.sol` and `MarketFactory.sol` have compile-time dependencies on `IPositionManager` and `IMarginEngine`. Removing them today breaks the 103/103 passing test suite. The refactor is Phase 2 work; the public repo carries the deprecation notice in plain sight.

## Phase 2 public summary

Phase 2 (estimated 2026-06-01 → 2026-07-15) will:

- Remove perp-era contracts (`PositionManager`, `MarginEngine`, `LiquidationEngine`) per ADR-0016. FundingRate is listed in ADR-0016 as a drop target but no `FundingRate.sol` was ever built; no removal step needed.
- Refactor `Settlement.sol` to drop `IPositionManager` and accept RWA `Trade` / `IssuanceFill` / `NavUpdate` types.
- Add `Holdings.sol` (balance-only) and `AssetRegistry.sol`.
- Retarget `OracleAdapter.sol` from Pyth to NAV-attestor signatures.
- Role-split `Router.sol` into issuer / investor / regulator entry points.
- Update `MarketFactory.sol` to drop `IMarginEngine` dependency.

Phase 2 work happens on `main` of this public repo; commits will be visible.

## License

MIT. Each first-party Solidity file carries `// SPDX-License-Identifier: MIT`; the repo-level `LICENSE` is the standard MIT template. Vendored dependencies under `lib/` retain their original licenses (forge-std MIT, OpenZeppelin MIT, Pyth Apache-2.0).

## Consequences

- **Pro:** public trust surface; clean IP boundary (matcher private); audit-readable contracts; aligns with Anchorage/Fireblocks/Polymarket pattern.
- **Con:** two-repo coordination overhead until Phase 2 consolidation; public repo carries perp-era contracts until Phase 2.
- **Mitigation:** Phase 2 refactor (above) eliminates dead perp surface.
