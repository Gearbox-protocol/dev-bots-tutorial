// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import {IContractsRegister} from "@gearbox-protocol/core-v2/contracts/interfaces/IContractsRegister.sol";
import {
    AP_CONTRACTS_REGISTER,
    AP_BOT_LIST,
    AP_PRICE_ORACLE,
    IAddressProviderV3,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {IBotListV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IBotListV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

contract BotTestHelper is Test {
    // core contracts
    IAddressProviderV3 addressProvider;
    IBotListV3 botList;
    IContractsRegister contractsRegister;
    IPriceOracleV3 priceOracle;

    // credit contracts
    ICreditFacadeV3 creditFacade;
    ICreditManagerV3 creditManager;
    IERC20 underlying;

    error CreditManagerNotFoundException();

    // ----- //
    // SETUP //
    // ----- //

    function setUpGearbox(string memory creditManagerName) internal {
        vm.createSelectFork(vm.envString("FORK_RPC_URL"), vm.envUint("FORK_BLOCK_NUMBER"));

        addressProvider = IAddressProviderV3(vm.envAddress("ADDRESS_PROVIDER"));
        _setUpGearboxCoreContracts();
        _setUpGearboxCreditContracts(creditManagerName);
    }

    function _setUpGearboxCoreContracts() private {
        botList = IBotListV3(addressProvider.getAddressOrRevert(AP_BOT_LIST, 3_00));
        // forgefmt: disable-next-item
        contractsRegister = IContractsRegister(
            addressProvider.getAddressOrRevert(AP_CONTRACTS_REGISTER, NO_VERSION_CONTROL)
        );
        priceOracle = IPriceOracleV3(addressProvider.getAddressOrRevert(AP_PRICE_ORACLE, 3_00));
    }

    function _setUpGearboxCreditContracts(string memory creditManagerName) private {
        creditManager = getCreditManagerByName(creditManagerName);
        creditFacade = ICreditFacadeV3(creditManager.creditFacade());
        underlying = IERC20(creditManager.underlying());
    }

    // -------------- //
    // CREDIT ACCOUNT //
    // -------------- //

    function openCreditAccount(address user, uint256 collateralAmount, uint256 debtAmount)
        internal
        returns (ICreditAccountV3 creditAccount)
    {
        deal({token: address(underlying), to: user, give: collateralAmount});

        vm.startPrank(user);
        underlying.approve(address(creditManager), collateralAmount);
        creditAccount = ICreditAccountV3(
            creditFacade.openCreditAccount(
                user,
                makeMultiCall(
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (debtAmount))
                    }),
                    MultiCall({
                        target: address(creditFacade),
                        callData: abi.encodeCall(
                            ICreditFacadeV3Multicall.addCollateral, (address(underlying), collateralAmount)
                            )
                    })
                ),
                0
            )
        );
        vm.stopPrank();
    }

    // --------- //
    // MULTICALL //
    // --------- //

    function makeMultiCall() internal pure returns (MultiCall[] memory calls) {}

    function makeMultiCall(MultiCall memory call0) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](1);
        calls[0] = call0;
    }

    function makeMultiCall(MultiCall memory call0, MultiCall memory call1)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](2);
        calls[0] = call0;
        calls[1] = call1;
    }

    function makeMultiCall(MultiCall memory call0, MultiCall memory call1, MultiCall memory call2)
        internal
        pure
        returns (MultiCall[] memory calls)
    {
        calls = new MultiCall[](3);
        calls[0] = call0;
        calls[1] = call1;
        calls[2] = call2;
    }

    function makeMultiCall(
        MultiCall memory call0,
        MultiCall memory call1,
        MultiCall memory call2,
        MultiCall memory call3
    ) internal pure returns (MultiCall[] memory calls) {
        calls = new MultiCall[](4);
        calls[0] = call0;
        calls[1] = call1;
        calls[2] = call2;
        calls[3] = call3;
    }

    // ----- //
    // UTILS //
    // ----- //

    function getCreditManagerByName(string memory name) internal view returns (ICreditManagerV3) {
        address[] memory creditManagers = contractsRegister.getCreditManagers();
        for (uint256 i; i < creditManagers.length; ++i) {
            ICreditManagerV3 _creditManager = ICreditManagerV3(creditManagers[i]);
            if (_creditManager.version() == 3_00 && _equal(_creditManager.name(), name)) {
                return _creditManager;
            }
        }
        revert CreditManagerNotFoundException();
    }

    function _equal(string memory s1, string memory s2) private pure returns (bool) {
        if (bytes(s1).length != bytes(s2).length) return false;
        return keccak256(abi.encode(s1)) == keccak256(abi.encode(s2));
    }
}
