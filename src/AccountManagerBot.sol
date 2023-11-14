// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {
    ICreditManagerV3,
    CollateralDebtData,
    CollateralCalcTask
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";

/// @notice User data.
struct CreditAccountData {
    address owner;
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

    /// @notice Registered users data (creditAccount => manager => data).
    mapping(address => mapping(address => CreditAccountData)) public creditAccountData;

    /// ------ ///
    /// ERRORS ///
    /// ------ ///

    /// @dev When operation is executed not by approved manager.
    error CallerNotManager();

    /// @dev When the operation is executed by other than the Credit Account's owner.
    error IncorrectAccountOwner();

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
        if (!managers[msg.sender]) {
            revert CallerNotManager();
        }
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

    /// @notice Register the Credit Account to set loss caps.
    /// @param creditManager Credit manager.
    /// @param creditAccount Credit Account.
    /// @param totalLossCap Cap on drop of account total value
    ///        in credit manager's underlying currency. Can't be 0.
    /// @param intraOpLossCap Cap on cumulative intra-operation drop of account total value
    ///        in credit manager's underlying currency. Can't be 0.
    function register(address creditManager, address creditAccount, uint256 totalLossCap, uint256 intraOpLossCap)
        external
    {
        if (ICreditManagerV3(order.manager).getBorrowerOrRevert(order.creditAccount) != msg.sender) {
            revert IncorrectAccountOwner();
        }

        delete creditAccountData[creditAccount][creditManager];
        CreditAccountData storage data = creditAccountData[creditAccount][creditManager];

        address facade = ICreditManagerV3(creditManager).creditFacade();

        data.initialValue = _getAccountTotalValue(creditManager, creditAccount);

        if (totalLossCap == 0 || intraOpLossCap == 0) {
            revert ZeroLossCap();
        }
        data.totalLossCap = totalLossCap;
        data.intraOpLossCap = intraOpLossCap;
    }

    /// @notice Perform operation on user's account.
    /// @param user User address.
    /// @param creditManager Credit manager.
    /// @param calls Operation to execute.
    function performOperation(address creditAccount, address creditManager, MultiCall[] calldata calls)
        external
        onlyManager
    {
        CreditAccountData storage data = creditAccountData[creditAccount][creditManager];
        if (data.totalLossCap == 0) {
            revert UserNotRegistered();
        }
        if (ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount) != data.owner) {
            revert IncorrectAccountOwner();
        }

        address facade = ICreditManagerV3(creditManager).creditFacade();
        _validateCallsDontChangeDebt(facade, calls);

        uint256 totalValueBefore = _getAccountTotalValue(creditManager, creditAccount);

        ICreditFacade(facade).botMulticall(user, calls);

        uint256 totalValueAfter = _getAccountTotalValue(creditManager, creditAccount);

        bool isLoss = _updateIntraOpLossOrGain(totalValueBefore, totalValueAfter, data);
        if (isLoss && data.intraOpGain + data.intraOpLossCap < data.intraOpLoss) {
            revert IntraOpLossCapReached();
        }
        if (totalValueAfter + data.totalLossCap < data.initialValue) {
            revert TotalLossCapReached();
        }
    }

    /// ------------------ ///
    /// INTERNAL FUNCTIONS ///
    /// ------------------ ///

    /// @dev Retrieves the current total value of account
    function _getAccountTotalValue(address creditManager, address creditAccount) internal view returns (uint256) {
        CollateralDebtData memory cdd =
            ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);

        return cdd.totalValue;
    }

    /// @dev Checks that calls don't try to change account's debt.
    function _validateCallsDontChangeDebt(address facade, MultiCall[] calldata calls) internal pure {
        for (uint256 i = 0; i < calls.length;) {
            MultiCall calldata mcall = calls[i];
            if (mcall.target == facade) {
                bytes4 method = bytes4(mcall.callData);
                if (
                    method == ICreditFacadeV3Multicall.increaseDebt.selector
                        || method == ICreditFacadeV3Multicall.decreaseDebt.selector
                ) {
                    revert ChangeDebtForbidden();
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Updates intra-operation loss/gain given account's value before and after the operation.
    ///      Returns true if value decreased during the operation and false otherwise.
    function _updateIntraOpLossOrGain(uint256 totalValueBefore, uint256 totalValueAfter, CreditAccountData storage data)
        internal
        returns (bool)
    {
        if (totalValueAfter < totalValueBefore) {
            uint256 intraOpLoss;
            unchecked {
                intraOpLoss = totalValueBefore - totalValueAfter;
            }
            data.intraOpLoss += intraOpLoss;
            return true;
        } else {
            uint256 intraOpGain;
            unchecked {
                intraOpGain = totalValueAfter - totalValueBefore;
            }
            data.intraOpGain += intraOpGain;
            return false;
        }
    }
}
