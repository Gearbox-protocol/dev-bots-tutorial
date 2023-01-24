// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { ICreditManagerV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import { ICreditFacade, MultiCall } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";


/// @notice User data.
struct UserData {
    uint256 totalLossCap;
    uint256 intraOpLossCap;
    uint256 initialValue;
    uint256 intraOpLoss;
    uint256 intraOpGain;
}


/// @title Account manager bot.
/// @notice Allows Gearbox users to transfer control over account to permissioned managers.
contract AccountManagerBot is Ownable {

    /// --------------- ///
    /// STATE VARIABLES ///
    /// --------------- ///

    /// @dev Approved managers.
    mapping(address => bool) public managers;

    /// @notice Registered users data (user => manager => data).
    mapping(address => mapping(address => UserData)) public userData;

    /// ------ ///
    /// ERRORS ///
    /// ------ ///

    /// @dev When operation is executed not by approved manager.
    error CallerNotManager();

    /// @dev When user tries to set any of loss caps to zero upon registration.
    error ZeroLossCap();

    /// @dev When trying to perform an operation with unregistered user's account.
    error UserNotRegistered();

    /// @dev When operation cannot be executed because total loss cap is reached.
    error TotalLossCapReached();

    /// @dev When operation cannot be executed because intra-operation loss cap is reached.
    error IntraOpLossCapReached();

    /// @dev When operation cannot be executed because it tries to manipulate account's debt.
    error ChangeDebtForbidden();

    /// --------- ///
    /// MODIFIERS ///
    /// --------- ///

    /// @dev Reverts if caller is not one of approved managers.
    modifier onlyManager() {
        if (!managers[msg.sender])
            revert CallerNotManager();
        _;
    }

    /// ------------------ ///
    /// EXTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @notice Add or remove manager.
    /// @param manager Account to change the status for.
    /// @param status New status.
    function setManager(address manager, bool status) external onlyOwner {
        managers[manager] = status;
    }

    /// @notice Allow bot to perform operations on account in given credit manager.
    /// @param creditManager Credit manager.
    /// @param totalLossCap Cap on drop of account total value
    ///        in credit manager's underlying currency. Can't be 0.
    /// @param intraOpLossCap Cap on cumulative intra-operation drop of account total value
    ///        in credit manager's underlying currency. Can't be 0.
    function register(
        address creditManager,
        uint256 totalLossCap,
        uint256 intraOpLossCap
    ) external {
        UserData storage data = userData[msg.sender][creditManager];

        address account = ICreditManagerV2(creditManager).getCreditAccountOrRevert(msg.sender);
        address facade = ICreditManagerV2(creditManager).creditFacade();

        (data.initialValue, ) = ICreditFacade(facade).calcTotalValue(account);

        if (totalLossCap == 0 || intraOpLossCap == 0)
            revert ZeroLossCap();
        data.totalLossCap = totalLossCap;
        data.intraOpLossCap = intraOpLossCap;
    }

    /// @notice Revoke bot's allowance to manage account in given credit manager.
    /// @param creditManager Credit manager.
    function deregister(address creditManager) external {
        delete userData[msg.sender][creditManager];
    }

    /// @notice Perform operation on user's account.
    /// @param user User address.
    /// @param creditManager Credit manager.
    /// @param calls Operation to execute.
    function performOperation(
        address user,
        address creditManager,
        MultiCall[] calldata calls
    ) external onlyManager {
        UserData storage data = userData[user][creditManager];
        if (data.totalLossCap == 0)
            revert UserNotRegistered();

        address account = ICreditManagerV2(creditManager).getCreditAccountOrRevert(user);
        address facade = ICreditManagerV2(creditManager).creditFacade();

        (uint256 totalValueBefore, ) = ICreditFacade(facade).calcTotalValue(account);
        _validateLosses(totalValueBefore, data);

        _validateCalls(facade, calls);
        ICreditFacade(facade).botMulticall(user, calls);

        (uint256 totalValueAfter, ) = ICreditFacade(facade).calcTotalValue(account);
        if (totalValueAfter < totalValueBefore) {
            uint256 intraOpLoss;
            unchecked {
                intraOpLoss = totalValueBefore - totalValueAfter;
            }
            data.intraOpLoss += intraOpLoss;
        } else {
            uint256 intraOpGain;
            unchecked {
                intraOpGain = totalValueAfter - totalValueBefore;
            }
            data.intraOpGain += intraOpGain;
        }
        _validateLosses(totalValueAfter, data);
    }

    /// ------------------ ///
    /// INTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @dev Checks that none of loss caps are reached.
    function _validateLosses(uint256 totalValue, UserData memory data) internal pure {
        if (totalValue + data.totalLossCap < data.initialValue)
            revert TotalLossCapReached();
        if (data.intraOpGain + data.intraOpLossCap < data.intraOpLoss)
            revert IntraOpLossCapReached();
    }

    /// @dev Checks that calls don't try to change account's debt.
    function _validateCalls(address facade, MultiCall[] calldata calls) internal pure {
        for (uint256 i = 0; i < calls.length; ) {
            MultiCall calldata mcall = calls[i];
            if (mcall.target == facade) {
                bytes4 method = bytes4(mcall.callData);
                if (
                    method == ICreditFacade.increaseDebt.selector
                    || method == ICreditFacade.decreaseDebt.selector
                )
                    revert ChangeDebtForbidden();
            }
            unchecked {
                ++i;
            }
        }
    }
}
