// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Vault } from "../src/Vault.sol";
import { PositionManager } from "../src/PositionManager.sol";
import { MarginEngine } from "../src/MarginEngine.sol";
import { LiquidationEngine } from "../src/LiquidationEngine.sol";
import { OracleAdapter } from "../src/OracleAdapter.sol";
import { Settlement } from "../src/Settlement.sol";
import { Router } from "../src/Router.sol";
import { MarketFactory } from "../src/MarketFactory.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { MockPyth } from "../test/mocks/MockPyth.sol";
import { MockSP1Verifier } from "../test/mocks/MockSP1Verifier.sol";

contract DeployCore is Script {
    uint256 internal constant FORCE_INCLUDE_FEE_USDC = 1e6;

    function run() external returns (address[] memory deployed) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.envOr("ADMIN", vm.addr(privateKey));

        vm.startBroadcast(privateKey);

        address usdc = vm.envOr("USDC", address(0));
        if (usdc == address(0)) {
            usdc = address(new MockERC20("USDC", "USDC", 6));
        }

        address pyth = vm.envOr("PYTH", address(0));
        if (pyth == address(0)) {
            pyth = address(new MockPyth());
        }

        address verifier = address(new MockSP1Verifier());

        Vault vault =
            Vault(address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (usdc, admin)))));
        OracleAdapter oracle = OracleAdapter(
            address(
                new ERC1967Proxy(address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (pyth, admin)))
            )
        );
        MarginEngine marginEngine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );
        PositionManager positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize, (address(vault), address(marginEngine), address(oracle), admin)
                    )
                )
            )
        );
        LiquidationEngine liquidationEngine = LiquidationEngine(
            address(
                new ERC1967Proxy(
                    address(new LiquidationEngine()),
                    abi.encodeCall(
                        LiquidationEngine.initialize,
                        (address(vault), address(positionManager), address(marginEngine), address(oracle), admin)
                    )
                )
            )
        );
        Settlement settlement = Settlement(
            address(
                new ERC1967Proxy(
                    address(new Settlement()),
                    abi.encodeCall(
                        Settlement.initialize,
                        (
                            admin,
                            verifier,
                            address(vault),
                            address(positionManager),
                            address(0),
                            bytes32(vm.envOr("PROGRAM_VKEY", uint256(0))),
                            bytes32(vm.envOr("INITIAL_STATE_ROOT", uint256(0)))
                        )
                    )
                )
            )
        );
        MarketFactory marketFactory = MarketFactory(
            address(
                new ERC1967Proxy(
                    address(new MarketFactory()),
                    abi.encodeCall(MarketFactory.initialize, (admin, address(marginEngine), address(oracle)))
                )
            )
        );
        Router router = Router(
            address(
                new ERC1967Proxy(
                    address(new Router()),
                    abi.encodeCall(
                        Router.initialize,
                        (
                            admin,
                            address(vault),
                            address(settlement),
                            address(marketFactory),
                            usdc,
                            FORCE_INCLUDE_FEE_USDC
                        )
                    )
                )
            )
        );

        vault.grantSettlement(address(settlement));
        positionManager.grantSettlement(address(settlement));
        vault.grantRouter(address(router));
        positionManager.setLiquidationEngine(address(liquidationEngine));
        marginEngine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        settlement.setMarketFactory(address(marketFactory));
        settlement.setRouter(address(router));

        require(vault.hasRole(vault.SETTLEMENT_ROLE(), address(settlement)), "vault settlement role missing");
        require(
            positionManager.hasRole(positionManager.SETTLEMENT_ROLE(), address(settlement)),
            "pm settlement role missing"
        );
        require(vault.hasRole(vault.ROUTER_ROLE(), address(router)), "vault router role missing");

        vm.stopBroadcast();

        console2.log("admin", admin);
        console2.log("usdc", usdc);
        console2.log("pyth", pyth);
        console2.log("verifier", verifier);
        console2.log("vault", address(vault));
        console2.log("oracle", address(oracle));
        console2.log("marginEngine", address(marginEngine));
        console2.log("positionManager", address(positionManager));
        console2.log("liquidationEngine", address(liquidationEngine));
        console2.log("settlement", address(settlement));
        console2.log("marketFactory", address(marketFactory));
        console2.log("router", address(router));

        deployed = new address[](12);
        deployed[0] = admin;
        deployed[1] = usdc;
        deployed[2] = pyth;
        deployed[3] = verifier;
        deployed[4] = address(vault);
        deployed[5] = address(oracle);
        deployed[6] = address(marginEngine);
        deployed[7] = address(positionManager);
        deployed[8] = address(liquidationEngine);
        deployed[9] = address(settlement);
        deployed[10] = address(marketFactory);
        deployed[11] = address(router);
    }
}
