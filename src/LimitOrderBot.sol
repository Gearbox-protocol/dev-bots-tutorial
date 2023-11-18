// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Balance} from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

/// @title Limit order bot.
/// @notice Allows Gearbox users to submit limit sell orders. Arbitrary accounts can execute these orders.
/// @dev Not designed to handle quoted tokens.
contract LimitOrderBot {
    // ----- //
    // TYPES //
    // ----- //

    /// @notice Limit order data.
    struct Order {
        address borrower;
        address manager;
        address account;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 limitPrice;
        uint256 triggerPrice;
        uint256 deadline;
    }

    // --------------- //
    // STATE VARIABLES //
    // --------------- //

    /// @notice Pending orders.
    mapping(uint256 => Order) public orders;

    /// @dev Orders counter.
    uint256 internal _nextOrderId;

    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when user submits a new order.
    /// @param user User that submitted the order.
    /// @param orderId ID of the created order.
    event CreateOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when user cancels the order.
    /// @param user User that canceled the order.
    /// @param orderId ID of the canceled order.
    event CancelOrder(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when order is successfully executed.
    /// @param executor Account that executed the order.
    /// @param orderId ID of the executed order.
    event ExecuteOrder(address indexed executor, uint256 indexed orderId);

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice When user tries to submit/cancel other user's order.
    error CallerNotBorrower();

    /// @notice When order can't be executed because it's cancelled.
    error OrderIsCancelled();

    /// @notice When order can't be executed because it's incorrect.
    error InvalidOrder();

    /// @notice When trying to execute order after deadline.
    error Expired();

    /// @notice When trying to execute order while it's not triggered.
    error NotTriggered();

    /// @notice When user has no input token on their balance.
    error NothingToSell();

    /// @notice When the credit account's owner changed between order submission and execution.
    error CreditAccountBorrowerChanged();

    // ------------------ //
    // EXTERNAL FUNCTIONS //
    // ------------------ //

    /// @notice Submit new order.
    /// @param order Order to submit.
    /// @return orderId ID of created order.
    function submitOrder(Order calldata order) external returns (uint256 orderId) {
        if (
            order.borrower != msg.sender
                || ICreditManagerV3(order.manager).getBorrowerOrRevert(order.account) != order.borrower
        ) {
            revert CallerNotBorrower();
        }
        orderId = _useOrderId();
        orders[orderId] = order;
        emit CreateOrder(msg.sender, orderId);
    }

    /// @notice Cancel pending order.
    /// @param orderId ID of order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.borrower != msg.sender) {
            revert CallerNotBorrower();
        }
        delete orders[orderId];
        emit CancelOrder(msg.sender, orderId);
    }

    /// @notice Execute given order. Output token will be transferred from caller to this contract.
    /// @param orderId ID of order to execute.
    function executeOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        (uint256 amountIn, uint256 minAmountOut) = _validateOrder(order);

        IERC20(order.tokenOut).transferFrom(msg.sender, address(this), minAmountOut);
        IERC20(order.tokenOut).approve(order.manager, minAmountOut + 1);

        address facade = ICreditManagerV3(order.manager).creditFacade();

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (order.tokenOut, minAmountOut))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (order.tokenIn, amountIn, msg.sender))
        });
        ICreditFacadeV3(facade).botMulticall(order.account, calls);

        delete orders[orderId];
        emit ExecuteOrder(msg.sender, orderId);
    }

    // ------------------ //
    // INTERNAL FUNCTIONS //
    // ------------------ //

    /// @dev Increments the order counter and returns its previous value.
    function _useOrderId() internal returns (uint256 orderId) {
        orderId = _nextOrderId;
        _nextOrderId = orderId + 1;
    }

    /// @dev Checks if order can be executed:
    ///      * order must be correctly constructed and not expired;
    ///      * trigger condition must hold if trigger price is set;
    ///      * borrower must have an account in manager with non-empty input token balance.
    function _validateOrder(Order memory order) internal view returns (uint256 amountIn, uint256 minAmountOut) {
        if (order.account == address(0)) {
            revert OrderIsCancelled();
        }

        if (ICreditManagerV3(order.manager).getBorrowerOrRevert(order.account) != order.borrower) {
            revert CreditAccountBorrowerChanged();
        }

        if (order.tokenIn == order.tokenOut || order.amountIn == 0) {
            revert InvalidOrder();
        }

        if (order.deadline > 0 && block.timestamp > order.deadline) {
            revert Expired();
        }

        ICreditManagerV3 manager = ICreditManagerV3(order.manager);
        uint256 ONE = 10 ** IERC20Metadata(order.tokenIn).decimals();
        if (order.triggerPrice > 0) {
            uint256 price = IPriceOracleV3(manager.priceOracle()).convert(ONE, order.tokenIn, order.tokenOut);
            if (price > order.triggerPrice) {
                revert NotTriggered();
            }
        }

        uint256 balanceIn = IERC20(order.tokenIn).balanceOf(order.account);
        if (balanceIn <= 1) {
            revert NothingToSell();
        }

        amountIn = balanceIn > order.amountIn ? order.amountIn : balanceIn - 1;
        minAmountOut = amountIn * order.limitPrice / ONE;
    }
}
