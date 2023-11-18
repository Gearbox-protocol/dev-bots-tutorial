// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    ICreditFacadeV3Multicall,
    ALL_CREDIT_FACADE_CALLS_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

import {LimitOrderBot} from "../src/LimitOrderBot.sol";

import {BotTestHelper} from "./BotTestHelper.sol";

contract LimitOrderBotTest is BotTestHelper {
    // tested bot
    LimitOrderBot public bot;
    ICreditAccountV3 creditAccount;

    // tokens
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // actors
    address user;
    address executor;

    function setUp() public {
        user = makeAddr("USER");
        executor = makeAddr("EXECUTOR");

        setUpGearbox("Trade USDC -> Crypto v3");

        creditAccount = openCreditAccount(user, 50_000e6, 100_000e6);

        bot = new LimitOrderBot();
        vm.prank(user);
        creditFacade.setBotPermissions(
            address(creditAccount), address(bot), uint192(ALL_CREDIT_FACADE_CALLS_PERMISSION)
        );

        // let's make weth non-quoted for this test because bot doesn't work with quotas
        uint256 quotedTokensMask = creditManager.quotedTokensMask();
        uint256 wethMask = creditManager.getTokenMaskOrRevert(address(weth));

        vm.prank(creditManager.creditConfigurator());
        creditManager.setQuotedMask(quotedTokensMask & ~wethMask);
    }

    function test_LO_01_setUp_is_correct() public {
        assertEq(address(underlying), address(usdc), "Incorrect underlying");
        assertEq(creditManager.getBorrowerOrRevert(address(creditAccount)), user, "Incorrect account owner");
        assertEq(usdc.balanceOf(address(creditAccount)), 150_000e6, "Incorrect account balance of underlying");
        assertEq(creditFacade.botList(), address(botList), "Incorrect bot list");
        assertEq(
            botList.botPermissions(address(bot), address(creditManager), address(creditAccount)),
            ALL_CREDIT_FACADE_CALLS_PERMISSION,
            "Incorrect bot permissions"
        );
    }

    function test_LO_02_submitOrder_reverts_if_caller_is_not_borrower() public {
        LimitOrderBot.Order memory order;

        vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);
        vm.prank(user);
        bot.submitOrder(order);

        address caller = makeAddr("CALLER");
        order.borrower = caller;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.submitOrder(order);
    }

    function test_LO_03_submitOrder_works_as_expected_when_called_properly() public {
        LimitOrderBot.Order memory order = LimitOrderBot.Order({
            borrower: user,
            manager: address(creditManager),
            account: address(creditAccount),
            tokenIn: address(usdc),
            tokenOut: address(weth),
            amountIn: 200_000e6,
            limitPrice: 123,
            triggerPrice: 456,
            deadline: 789
        });
        order.borrower = user;

        vm.expectEmit(true, true, true, true);
        emit LimitOrderBot.CreateOrder(user, 0);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);
        assertEq(orderId, 0, "Incorrect orderId");

        _assertOrderIsEqual(orderId, order);
    }

    function test_LO_04_cancelOrder_reverts_if_caller_is_not_borrower() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        address caller = makeAddr("CALLER");
        vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);
        vm.prank(caller);
        bot.cancelOrder(orderId);
    }

    function test_LO_05_cancelOrder_works_as_expected_when_called_properly() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectEmit(true, true, true, true);
        emit LimitOrderBot.CancelOrder(user, orderId);

        vm.prank(user);
        bot.cancelOrder(orderId);

        _assertOrderIsEmpty(orderId);
    }

    function test_LO_06_executeOrder_reverts_if_order_is_cancelled() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.prank(user);
        bot.cancelOrder(orderId);

        vm.expectRevert(LimitOrderBot.OrderIsCancelled.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_07_executeOrder_reverts_if_account_borrower_changes() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.mockCall(
            address(creditManager),
            abi.encodeCall(ICreditManagerV3.getBorrowerOrRevert, (address(creditAccount))),
            abi.encode(makeAddr("OTHER_USER"))
        );

        vm.expectRevert(LimitOrderBot.CreditAccountBorrowerChanged.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_08_executeOrder_reverts_if_order_is_invalid() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenIn = address(usdc);
        order.tokenOut = address(usdc);
        order.amountIn = 123;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectRevert(LimitOrderBot.InvalidOrder.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);

        order.tokenOut = address(weth);
        order.amountIn = 0;

        vm.expectRevert(LimitOrderBot.InvalidOrder.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_09_executeOrder_reverts_if_order_is_expired() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenIn = address(usdc);
        order.tokenOut = address(weth);
        order.amountIn = 123;
        order.deadline = block.timestamp - 1;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectRevert(LimitOrderBot.Expired.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_10_executeOrder_reverts_if_order_is_not_triggered() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenIn = address(usdc);
        order.tokenOut = address(weth);
        order.amountIn = 123;
        order.triggerPrice = 1;
        order.deadline = block.timestamp;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectRevert(LimitOrderBot.NotTriggered.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_11_executeOrder_reverts_if_account_has_no_tokenIn() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenIn = address(weth);
        order.tokenOut = address(usdc);
        order.amountIn = 123;
        order.deadline = block.timestamp;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        vm.expectRevert(LimitOrderBot.NothingToSell.selector);
        vm.prank(executor);
        bot.executeOrder(orderId);
    }

    function test_LO_12_executeOrder_works_as_expected_when_called_properly() public {
        LimitOrderBot.Order memory order;
        order.borrower = user;
        order.manager = address(creditManager);
        order.account = address(creditAccount);
        order.tokenIn = address(usdc);
        order.tokenOut = address(weth);
        order.amountIn = 200_000e6;
        order.limitPrice = priceOracle.convert(1e6, address(usdc), address(weth)) * 95 / 100;
        order.deadline = block.timestamp;

        vm.prank(user);
        uint256 orderId = bot.submitOrder(order);

        uint256 wethAmount = (150_000e6 - 1) * order.limitPrice / 1e6;
        deal({token: address(weth), to: executor, give: wethAmount});
        vm.prank(executor);
        weth.approve(address(bot), wethAmount);

        vm.expectEmit(true, true, true, true);
        emit LimitOrderBot.ExecuteOrder(executor, orderId);

        vm.prank(executor);
        bot.executeOrder(orderId);

        _assertOrderIsEmpty(orderId);

        assertEq(usdc.balanceOf(executor), 150_000e6 - 1, "Incorrect executor USDC balance");
        assertEq(usdc.balanceOf(address(creditAccount)), 1, "Incorrect account USDC balance");
        assertEq(weth.balanceOf(executor), 0, "Incorrect executor WETH balance");
        assertEq(weth.balanceOf(address(creditAccount)), wethAmount, "Incorrect account WETH balance");
    }

    function _assertOrderIsEqual(uint256 orderId, LimitOrderBot.Order memory order) internal {
        (
            address borrower,
            address manager,
            address account,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 limitPrice,
            uint256 triggerPrice,
            uint256 deadline
        ) = bot.orders(orderId);
        assertEq(borrower, order.borrower, "Incorrect borrower");
        assertEq(manager, order.manager, "Incorrect manager");
        assertEq(account, order.account, "Incorrect account");
        assertEq(tokenIn, order.tokenIn, "Incorrect tokenIn");
        assertEq(tokenOut, order.tokenOut, "Incorrect tokenOut");
        assertEq(amountIn, order.amountIn, "Incorrect amountIn");
        assertEq(limitPrice, order.limitPrice, "Incorrect limitPrice");
        assertEq(triggerPrice, order.triggerPrice, "Incorrect triggerPrice");
        assertEq(deadline, order.deadline, "Incorrect deadline");
    }

    function _assertOrderIsEmpty(uint256 orderId) internal {
        (
            address borrower,
            address manager,
            address account,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 limitPrice,
            uint256 triggerPrice,
            uint256 deadline
        ) = bot.orders(orderId);
        assertEq(borrower, address(0), "Incorrect borrower");
        assertEq(manager, address(0), "Incorrect manager");
        assertEq(account, address(0), "Incorrect account");
        assertEq(tokenIn, address(0), "Incorrect tokenIn");
        assertEq(tokenOut, address(0), "Incorrect tokenOut");
        assertEq(amountIn, 0, "Incorrect amountIn");
        assertEq(limitPrice, 0, "Incorrect limitPrice");
        assertEq(triggerPrice, 0, "Incorrect triggerPrice");
        assertEq(deadline, 0, "Incorrect deadline");
    }
}
