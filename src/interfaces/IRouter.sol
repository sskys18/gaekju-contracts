// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRouter {
    function deposit(uint256 usdcAmount) external;
    function withdraw(uint256 usdcAmount) external;
    function forceInclude(bytes calldata intent, bytes calldata sig) external;
}
