// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Counters } from "@openzeppelin/contracts/utils/Counters.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Balance } from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { ICreditManagerV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import { ICreditFacade, ICreditFacadeExtended } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";

import { ISwapRouter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV3.sol";
import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import { IUniswapV2Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV2Adapter.sol";
import { IUniswapV2Router01 } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV2Router01.sol";


/// @notice Limit order data.
struct Order {
    address borrower;
    address manager;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 limitPrice;
    uint256 triggerPrice;
    uint256 deadline;
}


/// @title Limit order bot.
/// @notice Allows Gearbox users to submit limit sell orders.
///         Arbitrary accounts can execute orders by providing a multicall that swaps assets.
contract LimitOrderBot {
    using Counters for Counters.Counter;

    /// --------------- ///
    /// STATE VARIABLES ///
    /// --------------- ///

    /// @notice Pending orders.
    mapping(uint256 => Order) public orders;

    /// @dev Uniswap V3 router address.
    address private immutable _uniswapV3Router;
    /// @dev Uniswap V2 router address.
    address private immutable _uniswapV2Router;
    /// @dev Sushiswap router address.
    address private immutable _sushiswapRouter;

    /// @dev Orders counter.
    Counters.Counter private _nextOrderId;

    /// ------ ///
    /// EVENTS ///
    /// ------ ///

    /// @notice Emitted when user submits a new order.
    /// @param user User that submitted the order.
    /// @param orderId ID of the created order.
    event OrderCreated(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when user cancels the order.
    /// @param user User that canceled the order.
    /// @param orderId ID of the canceled order.
    event OrderCanceled(address indexed user, uint256 indexed orderId);

    /// @notice Emitted when order is successfully executed.
    /// @param executor Account that executed the order.
    /// @param orderId ID of the executed order.
    event OrderExecuted(address indexed executor, uint256 indexed orderId);

    /// ------ ///
    /// ERRORS ///
    /// ------ ///

    /// @notice When user tries to submit/cancel other user's order.
    error CallerNotBorrower();

    /// @notice 
    error InvalidOrder();

    /// @notice When trying to execute order after deadline.
    error Expired();

    /// @notice When trying to execute order while it's not triggered.
    error NotTriggered();

    /// @notice When user has no input token on their balance.
    error NothingToSell();

    /// @notice When subcall targets unsupported adapter.
    error InvalidCallTarget();

    /// @notice When subcall targets unsupported method.
    error InvalidCallMethod();

    /// @notice When multicall sells incorrect amount of input token.
    error IncorrectAmountSpent();

    /// ----------- ///
    /// CONSTRUCTOR ///
    /// ----------- ///

    /// @notice Bot constructor.
    /// @param uniswapV3Router Uniswap V3 router address.
    /// @param uniswapV2Router Uniswap V2 router address.
    /// @param sushiswapRouter Sushiswap router address.
    constructor(
        address uniswapV3Router,
        address uniswapV2Router,
        address sushiswapRouter
    ) {
        _uniswapV3Router = uniswapV3Router;
        _uniswapV2Router = uniswapV2Router;
        _sushiswapRouter = sushiswapRouter;
    }

    /// ------------------ ///
    /// EXTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @notice Submit new order.
    /// @param order Order to submit.
    /// @return orderId ID of created order.
    function submitOrder(Order calldata order) external returns (uint256 orderId) {
        if (order.borrower != msg.sender)
            revert CallerNotBorrower();
        orderId = _useOrderId();
        orders[orderId] = order;
        emit OrderCreated(msg.sender, orderId);
    }

    /// @notice Cancel pending order.
    /// @param orderId ID of order to cancel.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        if (order.borrower != msg.sender)
            revert CallerNotBorrower();
        delete orders[orderId];
        emit OrderCanceled(msg.sender, orderId);
    }

    /// @notice Execute given order using provided multicall.
    /// @param orderId ID of order to execute.
    /// @param calls Multicall needed to execute an order.
    function executeOrder(uint256 orderId, MultiCall[] calldata calls) external {
        Order storage order = orders[orderId];

        (
            address creditAccount,
            uint256 balanceBefore,
            uint256 amountIn,
            uint256 minAmountOut
        ) = _validateOrder(order);

        address[] memory tokensSpent = _validateCalls(
            calls, order.manager, order.tokenIn, order.tokenOut
        );

        address facade = ICreditManagerV2(order.manager).creditFacade();
        ICreditFacade(facade).botMulticall(
            order.borrower,
            _addBalanceCheck(
                calls,
                facade,
                tokensSpent,
                order.tokenOut,
                minAmountOut
            )
        );

        _validateAmountSpent(
            order.tokenIn, creditAccount, balanceBefore, amountIn
        );

        delete orders[orderId];
        emit OrderExecuted(msg.sender, orderId);
    }

    /// ------------------ ///
    /// INTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @dev Increments the order counter and returns its previous value.
    function _useOrderId() internal returns (uint256 orderId) {
        orderId = _nextOrderId.current();
        _nextOrderId.increment();
    }

    /// @dev Checks if order can be executed:
    ///      * order must be correctly constructed and not expired;
    ///      * trigger condition must hold if trigger price is set;
    ///      * borrower must have an account in manager with non-empty balance
    ///        of the input token.
    function _validateOrder(Order memory order)
        internal
        view
        returns (
            address creditAccount,
            uint256 balanceIn,
            uint256 amountIn,
            uint256 minAmountOut
        )
    {
        if (order.tokenIn == order.tokenOut || order.amountIn == 0)
            revert InvalidOrder();

        if (order.deadline > 0 && block.timestamp > order.deadline)
            revert Expired();

        ICreditManagerV2 manager = ICreditManagerV2(order.manager);
        uint256 ONE = 10 ** IERC20Metadata(order.tokenIn).decimals();
        if (order.triggerPrice > 0) {
            uint256 price = manager.priceOracle().convert(
                ONE, order.tokenIn, order.tokenOut
            );
            if (price > order.triggerPrice)
                revert NotTriggered();
        }

        creditAccount = manager.getCreditAccountOrRevert(order.borrower);
        balanceIn = IERC20(order.tokenIn).balanceOf(creditAccount);
        if (balanceIn <= 1)
            revert NothingToSell();

        amountIn = balanceIn > order.amountIn ? order.amountIn : balanceIn - 1;
        minAmountOut = amountIn * order.limitPrice / ONE;
    }

    /// @dev Checks that each subcall targets one of the allowed methods of allowed adapters.
    ///      Returns tokens spent during multicall (except input and output).
    function _validateCalls(
        MultiCall[] calldata calls,
        address manager,
        address tokenIn,
        address tokenOut
    )
        internal
        view
        returns (address[] memory tokensSpent)
    {
        address uniswapV3Adapter = ICreditManagerV2(manager).contractToAdapter(_uniswapV3Router);
        address uniswapV2Adapter = ICreditManagerV2(manager).contractToAdapter(_uniswapV2Router);
        address sushiswapAdapter = ICreditManagerV2(manager).contractToAdapter(_sushiswapRouter);

        uint256 numCalls = calls.length;
        address[] memory tokens = new address[](numCalls);
        uint256 numTokens = 0;
        for (uint256 i = 0; i < numCalls; ) {
            MultiCall calldata mcall = calls[i];
            unchecked {
                ++i;
            }

            address tokenSpent;
            if (mcall.target == uniswapV3Adapter) {
                tokenSpent = _validateUniV3AdapterCall(mcall.callData);
            } else if (mcall.target == uniswapV2Adapter || mcall.target == sushiswapAdapter) {
                tokenSpent = _validateUniV2AdapterCall(mcall.callData);
            } else {
                revert InvalidCallTarget();
            }
            if (tokenSpent == tokenIn || tokenSpent == tokenOut) continue;

            uint256 j;
            for (j = 0; j < numTokens; ) {
                if (tokens[j] == tokenSpent) break;
                unchecked {
                    ++j;
                }
            }
            if (j == numTokens) {
                tokens[numTokens] = tokenSpent;
                unchecked {
                    ++numTokens;
                }
            }
        }
        tokensSpent = _truncate(tokens, numTokens);
    }

    /// @dev Prepends a balance check subcall to the multicall to ensure that
    ///      (i) amount of `tokenOut` received is at least `minAmountOut` and
    ///      (ii) balance of any token spent in the multicall (except input)
    ///      is at least that before the call.
    function _addBalanceCheck(
        MultiCall[] calldata calls,
        address facade,
        address[] memory tokensSpent,
        address tokenOut,
        uint256 minAmountOut
    )
        internal
        pure
        returns (MultiCall[] memory callsWithBalanceCheck)
    {
        uint256 numTokens = tokensSpent.length;
        Balance[] memory balanceDeltas = new Balance[](numTokens + 1);
        for (uint256 i = 0; i < numTokens; ) {
            balanceDeltas[i] = Balance({token: tokensSpent[i], balance: 0});
            unchecked {
                ++i;
            }
        }
        balanceDeltas[numTokens] = Balance({token: tokenOut, balance: minAmountOut});

        uint256 numCalls = calls.length;
        callsWithBalanceCheck = new MultiCall[](numCalls + 1);
        callsWithBalanceCheck[0] = MultiCall({
            target: facade,
            callData: abi.encodeWithSelector(
                ICreditFacadeExtended.revertIfReceivedLessThan.selector,
                balanceDeltas
            )
        });
        for (uint256 i = 0; i < numCalls; ) {
            callsWithBalanceCheck[i + 1] = calls[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Checks if the amount of the input token spent in the multicall is correct.
    function _validateAmountSpent(
        address tokenIn,
        address creditAccount,
        uint256 balanceBefore,
        uint256 amountIn
    ) internal view {
        uint256 balanceAfter = IERC20(tokenIn).balanceOf(creditAccount);
        if (balanceAfter + amountIn != balanceBefore)
            revert IncorrectAmountSpent();
    }

    /// @dev Validates that call is made to the supported Uni V3 method,
    ///      returns the token spent in the call.
    function _validateUniV3AdapterCall(bytes calldata callData)
        internal
        pure
        returns (address tokenSpent)
    {
        bytes4 selector = bytes4(callData);
        if (selector == IUniswapV3Adapter.exactAllInputSingle.selector) {
            IUniswapV3Adapter.ExactAllInputSingleParams memory params = abi.decode(
                callData[4:],
                (IUniswapV3Adapter.ExactAllInputSingleParams)
            );
            tokenSpent = params.tokenIn;
        } else if (selector == IUniswapV3Adapter.exactAllInput.selector) {
            IUniswapV3Adapter.ExactAllInputParams memory params = abi.decode(
                callData[4:],
                (IUniswapV3Adapter.ExactAllInputParams)
            );
            tokenSpent = _parseTokenIn(params.path);
        } else if (selector == ISwapRouter.exactInputSingle.selector) {
            ISwapRouter.ExactInputSingleParams memory params = abi.decode(
                callData[4:],
                (ISwapRouter.ExactInputSingleParams)
            );
            tokenSpent = params.tokenIn;
        } else if (selector == ISwapRouter.exactInput.selector) {
            ISwapRouter.ExactInputParams memory params = abi.decode(
                callData[4:],
                (ISwapRouter.ExactInputParams)
            );
            tokenSpent = _parseTokenIn(params.path);
        } else {
            revert InvalidCallMethod();
        }
    }

    /// @dev Validates that call is made to the supported Uni V2 method,
    ///      returns the token spent in the call.
    function _validateUniV2AdapterCall(bytes calldata callData)
        internal
        pure
        returns (address tokenSpent)
    {
        bytes4 selector = bytes4(callData);
        address[] memory path;
        if (selector == IUniswapV2Adapter.swapAllTokensForTokens.selector) {
            (, path, ) = abi.decode(
                callData[4:],
                (uint256, address[], uint256)
            );
        } else if (selector == IUniswapV2Router01.swapExactTokensForTokens.selector) {
            (, , path, , ) = abi.decode(
                callData[4:],
                (uint256, uint256, address[], address, uint256)
            );
        } else {
            revert InvalidCallMethod();
        }
        tokenSpent = path[0];
    }

    /// @dev Truncates the address array to given length.
    function _truncate(address[] memory array, uint256 length)
        internal
        pure
        returns (address[] memory truncated)
    {
        require(array.length >= length);
        truncated = new address[](length);
        for (uint256 i = 0; i < length; ) {
            truncated[i] = array[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Parses input token address from bytes-encoded Uniswap V3 swap path.
    function _parseTokenIn(bytes memory path) internal pure returns (address tokenIn) {
        assembly {
            tokenIn := div(
                mload(add(path, 0x20)),
                0x1000000000000000000000000
            )
        }
        return tokenIn;
    }
}
