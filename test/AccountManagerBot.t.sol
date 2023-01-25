// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Test } from "@forge-std/Test.sol";

import { AccountManagerBot, UserData } from "../src/AccountManagerBot.sol";

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { BotList } from "@gearbox-protocol/core-v2/contracts/support/BotList.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { CreditFacade } from "@gearbox-protocol/core-v2/contracts/credit/CreditFacade.sol";
import { CreditManager } from "@gearbox-protocol/core-v2/contracts/credit/CreditManager.sol";
import { ICreditManagerV2Exceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";

import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";


contract AccountManagerBotTest is Test {
    AccountManagerBot private bot;
    CreditManager private manager;
    CreditFacade private facade;
    BotList private botList;

    address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant ADDRESS_PROVIDER = 0xcF64698AFF7E5f27A11dff868AF228653ba53be0;
    address private constant WETH_CREDIT_MANAGER = 0x5887ad4Cb2352E7F01527035fAa3AE0Ef2cE2b9B;

    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address private constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address private constant MANAGER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    /// ----- ///
    /// SETUP ///
    /// ----- ///

    function setUp() public {
        bot = new AccountManagerBot();

        manager = CreditManager(WETH_CREDIT_MANAGER);
        vm.startPrank(manager.creditConfigurator());

        // since V2.1 is not live yet, we need to deploy new CreditFacade
        facade = new CreditFacade(WETH_CREDIT_MANAGER, address(0), address(0), false);

        // let's disable facade limits for more convenient testing
        facade.setLimitPerBlock(type(uint128).max);
        facade.setCreditAccountLimits(0, type(uint128).max);

        // also need to deploy BotList and connect it to the facade
        botList = new BotList(ADDRESS_PROVIDER);
        facade.setBotList(address(botList));

        // connect the new facade to the manager
        manager.upgradeCreditFacade(address(facade));
        vm.stopPrank();
    }

    /// ----------------- ///
    /// PERMISSIONS TESTS ///
    /// ----------------- ///

    function test_bot_has_correct_owner() public {
        assertEq(bot.owner(), self());

        bot.transferOwnership(USER);
        assertEq(bot.owner(), USER);

        vm.prank(USER);
        bot.renounceOwnership();
        assertEq(bot.owner(), address(0));
    }

    function test_setManager_reverts_when_called_by_non_owner() public {
        vm.prank(USER);
        vm.expectRevert("Ownable: caller is not the owner");
        bot.setManager(MANAGER, true);
    }

    function test_setManager_works_correctly() public {
        bot.setManager(MANAGER, true);
        assertTrue(bot.managers(MANAGER));

        bot.setManager(MANAGER, false);
        assertFalse(bot.managers(MANAGER));
    }

    /// ----------------- ///
    /// USER CONFIG TESTS ///
    /// ----------------- ///

    function test_register_reverts_if_user_has_no_account() public {
        vm.prank(USER);
        vm.expectRevert(ICreditManagerV2Exceptions.HasNoOpenedAccountException.selector);
        bot.register(WETH_CREDIT_MANAGER, 0, 0);
    }

    function test_register_reverts_on_zero_loss_cap() public {
        _createTestAccount(USER);

        vm.prank(USER);
        vm.expectRevert(AccountManagerBot.ZeroLossCap.selector);
        bot.register(WETH_CREDIT_MANAGER, 1, 0);

        vm.prank(USER);
        vm.expectRevert(AccountManagerBot.ZeroLossCap.selector);
        bot.register(WETH_CREDIT_MANAGER, 0, 1);
    }

    function test_register_and_deregister_work_correctly() public {
        address account = _createTestAccount(USER);
        (uint256 initialValue, ) = facade.calcTotalValue(account);

        uint256 totalLossCap = 10 ether;
        uint256 intraOpLossCap = 1 ether;
        uint256 userTotalLossCap;
        uint256 userIntraOpLossCap;
        uint256 userInitialValue;

        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, 10 ether, 1 ether);
        (userTotalLossCap, userIntraOpLossCap, userInitialValue, , ) = bot.userData(USER, WETH_CREDIT_MANAGER);
        assertEq(userTotalLossCap, totalLossCap);
        assertEq(userIntraOpLossCap, intraOpLossCap);
        assertEq(userInitialValue, initialValue);

        vm.prank(USER);
        bot.deregister(WETH_CREDIT_MANAGER);
        (userTotalLossCap, userIntraOpLossCap, userInitialValue, , ) = bot.userData(USER, WETH_CREDIT_MANAGER);
        assertEq(userTotalLossCap, 0);
        assertEq(userIntraOpLossCap, 0);
        assertEq(userInitialValue, 0);
    }

    /// ---------------- ///
    /// OPERATIONS TESTS ///
    /// ---------------- ///

    function test_performOperation_reverts_on_non_manager_caller() public {
        _createTestAccount(USER);

        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, 10 ether, 1 ether);

        vm.prank(MANAGER);
        MultiCall[] memory calls;
        vm.expectRevert(AccountManagerBot.CallerNotManager.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);
    }

    function test_performOperation_reverts_on_not_registered_user() public {
        bot.setManager(MANAGER, true);
        
        _createTestAccount(USER);

        vm.prank(MANAGER);
        MultiCall[] memory calls;
        vm.expectRevert(AccountManagerBot.UserNotRegistered.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);
    }

    function test_performOperation_reverts_on_change_debt_calls() public {
        bot.setManager(MANAGER, true);

        _createTestAccount(USER);
        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, 10 ether, 1 ether);

        MultiCall[] memory calls = new MultiCall[](1);

        vm.prank(MANAGER);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                CreditFacade.increaseDebt.selector,
                10 ether
            )
        });
        vm.expectRevert(AccountManagerBot.ChangeDebtForbidden.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);

        vm.prank(MANAGER);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                CreditFacade.decreaseDebt.selector,
                10 ether
            )
        });
        vm.expectRevert(AccountManagerBot.ChangeDebtForbidden.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);
    }

    function test_perform_operation_reverts_on_reaching_intra_op_loss_cap() public {
        bot.setManager(MANAGER, true);

        _createTestAccount(USER);

        uint256 totalLossCap = 10 ether;
        uint256 intraOpLossCap = 0.1 ether;

        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, totalLossCap, intraOpLossCap);

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInputSingle.selector,
                IUniswapV3Adapter.ExactAllInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: 10000, // pool with thin liquidity
                    deadline: block.timestamp,
                    rateMinRAY: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        vm.prank(MANAGER);
        vm.expectRevert(AccountManagerBot.IntraOpLossCapReached.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);
    }

    function test_performOperation_reverts_on_reaching_total_loss_cap() public {
        bot.setManager(MANAGER, true);

        address account = _createTestAccount(USER);
        (uint256 initialValue, ) = facade.calcTotalValue(account);

        uint256 totalLossCap = 10 ether;
        uint256 intraOpLossCap = 1 ether;

        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, totalLossCap, intraOpLossCap);

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInputSingle.selector,
                IUniswapV3Adapter.ExactAllInputSingleParams({
                    tokenIn: DAI,
                    tokenOut: WETH,
                    fee: 500,
                    deadline: block.timestamp,
                    rateMinRAY: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        vm.prank(MANAGER);
        vm.mockCall(
            address(facade),
            abi.encodeWithSelector(
                CreditFacade.calcTotalValue.selector,
                address(account)
            ),
            abi.encode(initialValue - totalLossCap - 1, 0)
        );
        vm.expectRevert(AccountManagerBot.TotalLossCapReached.selector);
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);
    }

    function test_performOperation_works_correctly() public {
        bot.setManager(MANAGER, true);

        address account = _createTestAccount(USER);
        (uint256 initialValue, ) = facade.calcTotalValue(account);

        uint256 totalLossCap = 10 ether;
        uint256 intraOpLossCap = 1 ether;

        vm.prank(USER);
        bot.register(WETH_CREDIT_MANAGER, totalLossCap, intraOpLossCap);

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInputSingle.selector,
                IUniswapV3Adapter.ExactAllInputSingleParams({
                    tokenIn: DAI,
                    tokenOut: WETH,
                    fee: 500,
                    deadline: block.timestamp,
                    rateMinRAY: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        vm.prank(MANAGER);
        vm.expectCall(address(facade), abi.encodePacked(CreditFacade.botMulticall.selector));
        bot.performOperation(USER, WETH_CREDIT_MANAGER, calls);

        (uint256 totalValueAfter, ) = facade.calcTotalValue(account);
        ( , , , uint256 intraOpLoss, uint256 intraOpGain) = bot.userData(USER, WETH_CREDIT_MANAGER);

        assertGt(totalValueAfter + totalLossCap, initialValue);
        if (intraOpLoss > 0) {
            assertLt(intraOpLoss, intraOpLossCap);
            assertEq(totalValueAfter + intraOpLoss, initialValue);
        }
        if (intraOpGain > 0)
            assertEq(initialValue + intraOpGain, totalValueAfter);
    }

    /// ------- ///
    /// HELPERS ///
    /// ------- ///

    /// @dev Returns address of this test contract.
    function self() internal view returns (address) {
        return address(this);
    }

    /// @dev Opens an account for the user with 50K USDC collateral and 100 WETH
    ///      borrowed and swapped into DAI.
    function _createTestAccount(address user)
        internal
        returns (address account)
    {
        uint256 wethAmount = 100 ether;
        uint256 usdcBalance = 50_000 * 10**6;

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                CreditFacade.addCollateral.selector,
                user,
                USDC,
                usdcBalance
            )
        });
        calls[1] = MultiCall({
            target: manager.contractToAdapter(UNISWAP_V3_ROUTER),
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInputSingle.selector,
                IUniswapV3Adapter.ExactAllInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: DAI,
                    fee: 500,
                    deadline: block.timestamp,
                    rateMinRAY: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        deal(USDC, user, usdcBalance);
        vm.startPrank(user);
        IERC20(USDC).approve(WETH_CREDIT_MANAGER, usdcBalance);
        facade.openCreditAccountMulticall(wethAmount, user, calls, 0);
        botList.setBotStatus(address(bot), true);
        vm.stopPrank();

        account = manager.getCreditAccountOrRevert(user);
    }
}
