// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MarginEngine } from "../../src/MarginEngine.sol";
import { Vault } from "../../src/Vault.sol";
import { OracleAdapter } from "../../src/OracleAdapter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPyth } from "../mocks/MockPyth.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IMarginEngine } from "../../src/interfaces/IMarginEngine.sol";

contract MarginEngineTest is Test {
    MarginEngine public engine;
    Vault public vault;
    OracleAdapter public oracle;
    MockERC20 public usdc;
    MockPyth public mockPyth;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    uint256 public constant MARKET_BTC = 0;
    bytes32 public constant BTC_PYTH_ID = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        mockPyth = new MockPyth();

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

        engine = MarginEngine(
            address(
                new ERC1967Proxy(
                    address(new MarginEngine()),
                    abi.encodeCall(MarginEngine.initialize, (address(vault), address(oracle), admin))
                )
            )
        );

        vm.prank(admin);
        vault.grantSettlement(address(engine));

        vm.prank(admin);
        engine.setMarketConfig(
            MARKET_BTC,
            IMarginEngine.MarketConfig({
                maxLeverage: 50e18,
                initialMarginRate: 2e16,
                maintenanceMarginRate: 1e16,
                tickSize: 0.1e18,
                lotSize: 0.00001e18,
                maxOrderSize: 100e18,
                minOrderSize: 0.001e18
            })
        );

        vm.prank(admin);
        oracle.setMarketOracle(MARKET_BTC, BTC_PYTH_ID, 60);
        mockPyth.setPrice(BTC_PYTH_ID, 6_000_000_000_000, 60_000_000, -8);

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(10_000e6);
    }

    function test_getRequiredMargin() public view {
        uint256 margin = engine.getRequiredMargin(MARKET_BTC, 1e18, 60_000e18);
        assertEq(margin, 1_200e18);
    }

    function test_getRequiredMargin_small() public view {
        uint256 margin = engine.getRequiredMargin(MARKET_BTC, 0.01e18, 60_000e18);
        assertEq(margin, 12e18);
    }

    function test_getAvailableMargin() public view {
        assertEq(engine.getAvailableMargin(alice), 10_000e18);
    }

    function test_checkInitialMargin_sufficient() public view {
        assertTrue(engine.checkInitialMargin(alice, MARKET_BTC, 0.1e18, 60_000e18));
    }

    function test_checkInitialMargin_insufficient() public view {
        assertFalse(engine.checkInitialMargin(alice, MARKET_BTC, 10e18, 60_000e18));
    }

    function test_validateOrder_tooSmall() public {
        vm.expectRevert(MarginEngine.OrderTooSmall.selector);
        engine.validateOrder(MARKET_BTC, 0.0001e18, 60_000e18);
    }

    function test_validateOrder_tooLarge() public {
        vm.expectRevert(MarginEngine.OrderTooLarge.selector);
        engine.validateOrder(MARKET_BTC, 200e18, 60_000e18);
    }

    function test_validateOrder_priceNotAligned() public {
        vm.expectRevert(MarginEngine.PriceNotAligned.selector);
        engine.validateOrder(MARKET_BTC, 1e18, 60_000.05e18);
    }

    function test_validateOrder_valid() public view {
        engine.validateOrder(MARKET_BTC, 1e18, 60_000e18);
    }
}
