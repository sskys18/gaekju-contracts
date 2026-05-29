// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Router } from "../../src/Router.sol";
import { Settlement } from "../../src/Settlement.sol";
import { MarketFactory } from "../../src/MarketFactory.sol";
import { Vault } from "../../src/Vault.sol";
import { PositionManager } from "../../src/PositionManager.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { IMarketFactory } from "../../src/interfaces/IMarketFactory.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { MockSP1Verifier } from "../mocks/MockSP1Verifier.sol";

contract RouterTest is Test {
    uint256 internal constant FORCE_INCLUDE_FEE_USDC = 1e6;
    uint256 internal constant MARKET_ID = 1;

    Router public router;
    Settlement public settlement;
    MarketFactory public marketFactory;
    Vault public vault;
    PositionManager public positionManager;
    MarginEngine public marginEngine;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;
    MockSP1Verifier public verifier;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();
        verifier = new MockSP1Verifier();

        vault = Vault(
            address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(usdc), admin))))
        );
        oracle = OracleAdapter(
            address(
                new ERC1967Proxy(
                    address(new OracleAdapter()), abi.encodeCall(OracleAdapter.initialize, (address(mockPyth), admin))
                )
            )
        );
        marginEngine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );
        positionManager = PositionManager(
            address(
                new ERC1967Proxy(
                    address(new PositionManager()),
                    abi.encodeCall(
                        PositionManager.initialize, (address(vault), address(marginEngine), address(oracle), admin)
                    )
                )
            )
        );
        settlement = Settlement(
            address(
                new ERC1967Proxy(
                    address(new Settlement()),
                    abi.encodeCall(
                        Settlement.initialize,
                        (
                            admin,
                            address(verifier),
                            address(vault),
                            address(positionManager),
                            address(0),
                            bytes32(0),
                            bytes32(0)
                        )
                    )
                )
            )
        );
        marketFactory = MarketFactory(
            address(
                new ERC1967Proxy(
                    address(new MarketFactory()),
                    abi.encodeCall(MarketFactory.initialize, (admin, address(marginEngine), address(oracle)))
                )
            )
        );
        router = Router(
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
                            address(usdc),
                            FORCE_INCLUDE_FEE_USDC
                        )
                    )
                )
            )
        );

        vm.startPrank(admin);
        vault.grantSettlement(address(settlement));
        positionManager.grantSettlement(address(settlement));
        vault.grantRouter(address(router));
        marginEngine.grantRole(0x00, address(marketFactory));
        oracle.grantRole(0x00, address(marketFactory));
        settlement.setMarketFactory(address(marketFactory));
        settlement.setRouter(address(router));
        marketFactory.createMarket(
            IMarketFactory.MarketParams({
                tickSize: 0.1e18,
                lotSize: 0.00001e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                pythPriceId: bytes32(uint256(1)),
                oracleStalenessThreshold: 60,
                fundingInterval: 1 hours,
                maxFundingRate: 5e15,
                minOrderSize: 0.001e18,
                maxOrderSize: 100e18,
                makerFeeRate: 5e14,
                takerFeeRate: 1e15
            })
        );
        vm.stopPrank();

        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_deposit_forwardsIntoVault() public {
        vm.prank(alice);
        router.deposit(100e6);

        assertEq(vault.balances(alice), 100e18);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_withdraw_forwardsFromVault() public {
        vm.startPrank(alice);
        router.deposit(100e6);
        router.withdraw(40e6);
        vm.stopPrank();

        assertEq(vault.balances(alice), 60e18);
        assertEq(usdc.balanceOf(alice), 940e6);
    }

    function test_forceInclude_chargesFeeAndQueuesIntent() public {
        bytes memory intent = abi.encode(MARKET_ID, uint256(1234));

        vm.prank(alice);
        router.forceInclude(intent, hex"1234");

        (address trader, bytes32 digest, uint64 deadline, bool resolved,,) = settlement.pendingForcedIntent(1);
        assertEq(trader, alice);
        assertEq(digest, keccak256(intent));
        assertEq(deadline, settlement.FORCE_INCLUDE_N());
        assertFalse(resolved);
        assertEq(vault.insuranceFund(), 1e18);
        assertEq(usdc.balanceOf(address(vault)), FORCE_INCLUDE_FEE_USDC);
    }

    function test_forceInclude_revertsForPausedMarket() public {
        vm.prank(admin);
        marketFactory.pauseMarket(MARKET_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Router.MarketPaused.selector, MARKET_ID));
        router.forceInclude(abi.encode(MARKET_ID), hex"");
    }
}
