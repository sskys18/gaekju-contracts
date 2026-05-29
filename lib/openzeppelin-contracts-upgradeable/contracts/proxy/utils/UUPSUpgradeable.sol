// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {UUPSUpgradeable as UUPSUpgradeableBase} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

abstract contract UUPSUpgradeable is Initializable, UUPSUpgradeableBase {
    function __UUPSUpgradeable_init() internal onlyInitializing {}
    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {}
}
