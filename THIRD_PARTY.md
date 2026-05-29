# Third-Party Notices

This repository vendors the following dependencies under `lib/`. Each retains its upstream license. v0.1 ships vendored copies for deterministic builds; Phase 2 may convert to git submodules.

| Dependency | Path | License | License file | Upstream |
|------------|------|---------|--------------|----------|
| forge-std | `lib/forge-std` | MIT | `lib/forge-std/LICENSE-MIT` (also Apache-2.0 at `lib/forge-std/LICENSE-APACHE`) | https://github.com/foundry-rs/forge-std |
| OpenZeppelin Contracts | `lib/openzeppelin-contracts` | MIT | `lib/openzeppelin-contracts/LICENSE` | https://github.com/OpenZeppelin/openzeppelin-contracts |
| OpenZeppelin Contracts (Upgradeable) | `lib/openzeppelin-contracts-upgradeable` | MIT | `lib/openzeppelin-contracts-upgradeable/LICENSE` | https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable |
| Pyth SDK (Solidity) | `lib/pyth-sdk-solidity` | Apache-2.0 | `THIRD_PARTY_LICENSES/pyth-sdk-solidity-LICENSE.txt` (Pyth's upstream package declares license in `package.json` only; canonical Apache-2.0 text vendored separately) | https://github.com/pyth-network/pyth-sdk-solidity |
