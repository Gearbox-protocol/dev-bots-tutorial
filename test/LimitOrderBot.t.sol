// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.10;

// import { Test } from "@forge-std/Test.sol";

// import { LimitOrderBot, Order } from "../src/LimitOrderBot.sol";

// import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
// import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

// import { BotList } from "@gearbox-protocol/core-v2/contracts/support/BotList.sol";
// import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
// import { CreditFacade } from "@gearbox-protocol/core-v2/contracts/credit/CreditFacade.sol";
// import { CreditManager } from "@gearbox-protocol/core-v2/contracts/credit/CreditManager.sol";
// import { IPriceOracleV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
// import { ICreditFacadeExceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";
// import { ICreditManagerV2Exceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";

// import { IQuoter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IQuoter.sol";
// import { ISwapRouter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV3.sol";
// import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
// import { IUniswapV2Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV2Adapter.sol";
// import { IUniswapV2Router01 } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV2Router01.sol";


// contract LimitOrderBotTest is Test {
//     LimitOrderBot private bot;
//     CreditManager private manager;
//     CreditFacade private facade;
//     BotList private botList;

//     address private constant UNISWAP_V3_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
//     address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
//     address private constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
//     address private constant SUSHISWAP_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
//     address private constant ADDRESS_PROVIDER = 0xcF64698AFF7E5f27A11dff868AF228653ba53be0;
//     address private constant CREDIT_MANAGER = 0x5887ad4Cb2352E7F01527035fAa3AE0Ef2cE2b9B; // WETH credit manager

//     address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
//     address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
//     address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
//     address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

//     address private constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
//     address private constant OTHER_USER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
//     address private constant EXECUTOR = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

//     event OrderCreated(address indexed user, uint256 indexed orderId);
//     event OrderCanceled(address indexed user, uint256 indexed orderId);
//     event OrderExecuted(address indexed executor, uint256 indexed orderId);

//     /// ----- ///
//     /// SETUP ///
//     /// ----- ///

//     function setUp() public {
//         bot = new LimitOrderBot(
//             UNISWAP_V3_ROUTER,
//             UNISWAP_V2_ROUTER,
//             SUSHISWAP_ROUTER
//         );

//         manager = CreditManager(CREDIT_MANAGER);
//         vm.startPrank(manager.creditConfigurator());

//         // since V2.1 is not live yet, we need to deploy new CreditFacade
//         facade = new CreditFacade(CREDIT_MANAGER, address(0), address(0), false);

//         // let's disable facade limits for more convenient testing
//         facade.setLimitPerBlock(type(uint128).max);
//         facade.setCreditAccountLimits(0, type(uint128).max);

//         // also need to deploy BotList and connect it to the facade
//         botList = new BotList(ADDRESS_PROVIDER);
//         facade.setBotList(address(botList));

//         // connect the new facade to the manager
//         manager.upgradeCreditFacade(address(facade));
//         vm.stopPrank();
//     }

//     /// ---------------------- ///
//     /// ORDER SUBMISSION TESTS ///
//     /// ---------------------- ///

//     function test_submitOrder_reverts_when_caller_not_borrower() public {
//         Order memory order = Order({
//             borrower: USER,
//             manager: CREDIT_MANAGER,
//             tokenIn: address(0),
//             tokenOut: address(0),
//             amountIn: 0,
//             limitPrice: 0,
//             triggerPrice: 0,
//             deadline: 0
//         });

//         vm.prank(OTHER_USER);
//         vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);
//         bot.submitOrder(order);
//     }

//     function test_submitOrder_works_correctly() public {
//         Order memory order = Order({
//             borrower: USER,
//             manager: CREDIT_MANAGER,
//             tokenIn: address(0),
//             tokenOut: address(0),
//             amountIn: 0,
//             limitPrice: 0,
//             triggerPrice: 0,
//             deadline: 0
//         });
//         uint256 expectedOrderId = 0;

//         vm.prank(USER);
//         vm.expectEmit(true, true, false, false);
//         emit OrderCreated(USER, expectedOrderId);

//         uint256 orderId = bot.submitOrder(order);

//         assertEq(orderId, expectedOrderId);
//         (address borrower, , , , , , , ) = bot.orders(orderId);
//         assertEq(borrower, USER);
//     }

//     function test_cancelOrder_reverts_when_caller_not_borrower() public {
//         Order memory order = Order({
//             borrower: USER,
//             manager: CREDIT_MANAGER,
//             tokenIn: address(0),
//             tokenOut: address(0),
//             amountIn: 0,
//             limitPrice: 0,
//             triggerPrice: 0,
//             deadline: 0
//         });

//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         vm.prank(OTHER_USER);
//         vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);
//         bot.cancelOrder(orderId);
//     }

//     function test_cancelOrder_reverts_when_order_does_not_exist() public {
//         uint256 wrongOrderId = 2;

//         vm.prank(USER);
//         vm.expectRevert(LimitOrderBot.CallerNotBorrower.selector);

//         bot.cancelOrder(wrongOrderId);
//     }

//     function test_cancelOrder_works_correctly() public {
//         Order memory order = Order({
//             borrower: USER,
//             manager: CREDIT_MANAGER,
//             tokenIn: address(0),
//             tokenOut: address(0),
//             amountIn: 0,
//             limitPrice: 0,
//             triggerPrice: 0,
//             deadline: 0
//         });

//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);       

//         vm.prank(USER);
//         vm.expectEmit(true, true, false, false);
//         emit OrderCanceled(USER, orderId);

//         bot.cancelOrder(orderId);

//         (address borrower, , , , , , , ) = bot.orders(orderId);
//         assertEq(borrower, address(0));
//     }

//     /// ----------------------------- ///
//     /// ORDER-RELATED EXECUTION TESTS ///
//     /// ----------------------------- ///

//     function test_executeOrder_reverts_on_invalid_order() public {
//         MultiCall[] memory calls;

//         // try to execute an order that does not exist
//         vm.expectRevert(LimitOrderBot.InvalidOrder.selector);
//         bot.executeOrder(42, calls);

//         // try to execute an order with 0 input amount
//         Order memory order1 = _createTestOrder();
//         order1.amountIn = 0;
//         vm.prank(USER);
//         uint256 order1Id = bot.submitOrder(order1);

//         vm.expectRevert(LimitOrderBot.InvalidOrder.selector);
//         bot.executeOrder(order1Id, calls);

//         // try to execute an order with tokenIn = tokenOut
//         Order memory order2 = _createTestOrder();
//         order2.tokenOut = order2.tokenIn;
//         vm.prank(USER);
//         uint256 order2Id = bot.submitOrder(order2);

//         vm.expectRevert(LimitOrderBot.InvalidOrder.selector);
//         bot.executeOrder(order2Id, calls);
//     }

//     function test_executeOrder_reverts_on_expired_order() public {
//         Order memory order = _createTestOrder();
//         // set order deadline prior to current timestamp
//         order.deadline = block.timestamp - 1;

//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls;
//         vm.expectRevert(LimitOrderBot.Expired.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_not_triggered_order() public {
//         Order memory order = _createTestOrder();
//         // set order trigger price below the current chainlink price
//         order.triggerPrice = _oraclePrice(order.tokenIn, order.tokenOut) * 9 / 10;

//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls;
//         vm.expectRevert(LimitOrderBot.NotTriggered.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_user_without_account() public {
//         // this time order is fine, but our user doesn't have an account in the manager
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls;
//         vm.expectRevert(ICreditManagerV2Exceptions.HasNoOpenedAccountException.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_user_with_empty_tokenIn_balance() public {
//         // this time the user does have an account in the manager
//         _createTestAccount(USER);
//         // but has set tokenIn to the token they doesn't own
//         Order memory order = _createTestOrder();
//         order.tokenIn = WBTC;
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls;
//         vm.expectRevert(LimitOrderBot.NothingToSell.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     /// --------------------------------- ///
//     /// MULTICALL-RELATED EXECUTION TESTS ///
//     /// --------------------------------- ///

//     function test_executeOrder_reverts_on_invalid_call_target() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls = new MultiCall[](1);
//         // create a subcall to an address that's not any of 3 supported adapters of a manager
//         calls[0] = MultiCall({
//             target: address(0),
//             callData: bytes("dummy calldata")
//         });
//         vm.expectRevert(LimitOrderBot.InvalidCallTarget.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_invalid_call_method() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls = new MultiCall[](1);

//         // wrong calldata for uni v3 adapter
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: bytes("dummy calldata")
//         });
//         vm.expectRevert(LimitOrderBot.InvalidCallMethod.selector);
//         bot.executeOrder(orderId, calls);

//         // wrong calldata for uni v2 adapter
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V2_ROUTER),
//             callData: bytes("dummy calldata")
//         });
//         vm.expectRevert(LimitOrderBot.InvalidCallMethod.selector);
//         bot.executeOrder(orderId, calls);

//         // wrong calldata for sushi adapter
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(SUSHISWAP_ROUTER),
//             callData: bytes("dummy calldata")
//         });
//         vm.expectRevert(LimitOrderBot.InvalidCallMethod.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     /// ------------------------------- ///
//     /// BALANCE-RELATED EXECUTION TESTS ///
//     /// ------------------------------- ///

//     function test_executeOrder_reverts_on_spending_side_tokens() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // problem with this multicall is that the second subcall swaps **all** USDC
//         // but account had some USDC before
//         MultiCall[] memory calls = new MultiCall[](2);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(DAI, uint24(100), USDC),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn,
//                     amountOutMinimum: 0
//                 })
//             )
//         });
//         calls[1] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 IUniswapV3Adapter.exactAllInput.selector,
//                 IUniswapV3Adapter.ExactAllInputParams({
//                     path: abi.encodePacked(USDC, uint24(500), WETH),
//                     deadline: block.timestamp,
//                     rateMinRAY: 0
//                 })
//             )
//         });

//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 ICreditFacadeExceptions.BalanceLessThanMinimumDesiredException.selector,
//                 USDC
//             )
//         );
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_selling_below_min_price() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         // set limit price above current market price
//         order.limitPrice = _oraclePrice(DAI, WETH) * 12 / 10;
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // unless 20% deviation between Uniswap and Chainlink, the order cannot
//         // be executed by any multicall
//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 ICreditFacadeExceptions.BalanceLessThanMinimumDesiredException.selector,
//                 WETH
//             )
//         );
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_selling_more_than_required() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // the multicall indeed swaps DAI for WETH and does so at price better than limit
//         // however, it sells more than it was allowed to
//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn * 11 / 10,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectRevert(LimitOrderBot.IncorrectAmountSpent.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     function test_executeOrder_reverts_on_selling_less_than_required() public {
//         _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // similar to the previous case, but this time multicall sells less than needed
//         // (and even meets the min output amount condition, but we want to limit this behavior)
//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn * 9 / 10,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectRevert(LimitOrderBot.IncorrectAmountSpent.selector);
//         bot.executeOrder(orderId, calls);
//     }

//     /// ------------------------- ///
//     /// SUCESSFUL EXECUTION TESTS ///
//     /// ------------------------- ///

//     function test_executeOrder_works_currectly() public {
//         (
//             address account,
//             uint256 usdcBefore,
//             uint256 daiBefore
//         ) = _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(
//                         DAI, uint24(100), USDC, uint24(500), WETH
//                     ),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectEmit(true, true, false, false);
//         emit OrderExecuted(address(this), orderId);

//         bot.executeOrder(orderId, calls);

//         // check that account received at least the required amount of WETH (input token)
//         uint256 minWethAmountOut = order.amountIn * order.limitPrice / 1 ether;
//         assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
//         // check that account has at least the same amount of USDC (side token) as before the call
//         assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
//         // check that account spent the correct amount of DAI (output token) in the call
//         assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
//     }

//     function test_executeOrder_works_correctly_with_trigger_price_set() public {
//         (
//             address account,
//             uint256 usdcBefore,
//             uint256 daiBefore
//         ) = _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         // set trigger price above current chainlink price, so that order could be executed now
//         order.triggerPrice = _oraclePrice(DAI, WETH) * 12 / 10;
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(
//                         DAI, uint24(100), USDC, uint24(500), WETH
//                     ),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectEmit(true, true, false, false);
//         emit OrderExecuted(address(this), orderId);

//         bot.executeOrder(orderId, calls);

//         // check that account received at least the required amount of WETH (input token)
//         uint256 minWethAmountOut = order.amountIn * order.limitPrice / 1 ether;
//         assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
//         // check that account has at least the same amount of USDC (side token) as before the call
//         assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
//         // check that account spent the correct amount of DAI (output token) in the call
//         assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
//     }

//     function test_executeOrder_works_correctly_with_order_size_larger_than_balance() public {
//         (
//             address account,
//             uint256 usdcBefore,
//             uint256 daiBefore
//         ) = _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         // set order size to be above account's balance of input token
//         order.amountIn = 2 * daiBefore;
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // multicall must sell all account's DAI balance
//         uint256 amountIn = daiBefore - 1;
//         uint256 minWethAmountOut = amountIn * order.limitPrice / 1 ether;

//         MultiCall[] memory calls = new MultiCall[](1);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInput.selector,
//                 ISwapRouter.ExactInputParams({
//                     path: abi.encodePacked(
//                         DAI, uint24(100), USDC, uint24(500), WETH
//                     ),
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: amountIn,
//                     amountOutMinimum: 0
//                 })
//             )
//         });

//         vm.expectEmit(true, true, false, false);
//         emit OrderExecuted(address(this), orderId);

//         bot.executeOrder(orderId, calls);

//         // check that account received at least the required amount of WETH (input token)
//         assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
//         // check that account has at least the same amount of USDC (side token) as before the call
//         assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
//         // check that account spent the correct amount of DAI (output token) in the call
//         assertEq(IERC20(DAI).balanceOf(account) + amountIn, daiBefore);
//     }

//     function test_executeOrder_works_correctly_with_calls_involving_side_tokens() public {
//         (
//             address account,
//             uint256 usdcBefore,
//             uint256 daiBefore
//         ) = _createTestAccount(USER);
//         Order memory order = _createTestOrder();
//         vm.prank(USER);
//         uint256 orderId = bot.submitOrder(order);

//         // let's say we want to split the execution into to swaps:
//         // DAI -> USDC via uni v3, and USDC -> WETH via sushi.
//         // notice that in the second subcall we can only sell USDC that is output of
//         // the first subcall and not USDC that is owned by account before the call.
//         uint256 minWethAmountOut = order.amountIn * order.limitPrice / 1 ether;
//         uint256 usdcOut = IQuoter(UNISWAP_V3_QUOTER).quoteExactInputSingle(
//             DAI, USDC, 100, order.amountIn, 0
//         );
//         address[] memory path = new address[](2);
//         (path[0], path[1]) = (USDC, WETH);
//         MultiCall[] memory calls = new MultiCall[](2);
//         calls[0] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 ISwapRouter.exactInputSingle.selector,
//                 ISwapRouter.ExactInputSingleParams({
//                     tokenIn: DAI,
//                     tokenOut: USDC,
//                     fee: 100,
//                     recipient: address(0),
//                     deadline: block.timestamp,
//                     amountIn: order.amountIn,
//                     amountOutMinimum: 0,
//                     sqrtPriceLimitX96: 0
//                 })
//             )
//         });
//         calls[1] = MultiCall({
//             target: manager.contractToAdapter(SUSHISWAP_ROUTER),
//             callData: abi.encodeWithSelector(
//                 IUniswapV2Router01.swapExactTokensForTokens.selector,
//                 usdcOut,
//                 0,
//                 path,
//                 address(0),
//                 block.timestamp
//             )
//         });

//         vm.expectEmit(true, true, false, false);
//         emit OrderExecuted(address(this), orderId);

//         bot.executeOrder(orderId, calls);

//         // check that account received at least the required amount of WETH (input token)
//         assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
//         // check that account has at least the same amount of USDC (side token) as before the call
//         assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
//         // check that account spent the correct amount of DAI (output token) in the call
//         assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
//     }

//     /// ------- ///
//     /// HELPERS ///
//     /// ------- ///

//     /// @dev Opens an account for the user with 50K USDC collateral and 100 WETH
//     ///      borrowed and swapped into DAI (tests assume it's at least 50K DAI).
//     function _createTestAccount(address user)
//         internal
//         returns (
//             address account,
//             uint256 usdcBalance,
//             uint256 daiBalance
//         )
//     {
//         uint256 wethAmount = 100 ether;
//         usdcBalance = 50_000 * 10**6;

//         MultiCall[] memory calls = new MultiCall[](2);
//         calls[0] = MultiCall({
//             target: address(facade),
//             callData: abi.encodeWithSelector(
//                 CreditFacade.addCollateral.selector,
//                 user,
//                 USDC,
//                 usdcBalance
//             )
//         });
//         calls[1] = MultiCall({
//             target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
//             callData: abi.encodeWithSelector(
//                 IUniswapV3Adapter.exactAllInputSingle.selector,
//                 IUniswapV3Adapter.ExactAllInputSingleParams({
//                     tokenIn: WETH,
//                     tokenOut: DAI,
//                     fee: 500,
//                     deadline: block.timestamp,
//                     rateMinRAY: 0,
//                     sqrtPriceLimitX96: 0
//                 })
//             )
//         });

//         deal(USDC, user, usdcBalance);
//         vm.startPrank(user);
//         IERC20(USDC).approve(CREDIT_MANAGER, usdcBalance);
//         facade.openCreditAccountMulticall(wethAmount, user, calls, 0);
//         botList.setBotStatus(address(bot), true);
//         vm.stopPrank();

//         account = manager.getCreditAccountOrRevert(user);
//         daiBalance = IERC20(DAI).balanceOf(account);
//     }

//     /// @dev Creates a limit order to sell 50K of DAI for WETH with minPrice 20% below
//     ///      the current oracle price, no trigger price and no deadline.
//     function _createTestOrder() internal view returns (Order memory order) {
//         order = Order({
//             borrower: USER,
//             manager: CREDIT_MANAGER,
//             tokenIn: DAI,
//             tokenOut: WETH,
//             amountIn: 50_000 ether,
//             limitPrice: 8 * _oraclePrice(DAI, WETH) / 10,
//             triggerPrice: 0,
//             deadline: 0
//         });
//     }

//     /// @dev Returns oracle price of one unit of tokenIn in units of tokenOut.
//     function _oraclePrice(address tokenIn, address tokenOut)
//         internal
//         view
//         returns (uint256)
//     {
//         uint256 ONE = 10 ** IERC20Metadata(tokenIn).decimals();
//         return manager.priceOracle().convert(ONE, tokenIn, tokenOut);
//     }
// }
