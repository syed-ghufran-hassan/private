// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IBondingCurveFactory} from "src/interfaces/IBondingCurveFactory.sol";

contract FactoryManager is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IBondingCurveFactory private bondingCurveFactory;

    // Gap for future storage variables. If you add new variables, decrease the size of the gap.
    uint256[50] private __gap;

    error FactoryManager__ZeroAddress();
    error FactoryManager__FactoryIsNotActive();

    event FactoryUpdated(address indexed newFactory);

    modifier nonZeroAddress(address _addr) {
        if (_addr == address(0)) {
            revert FactoryManager__ZeroAddress();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the FactoryManager contract with the bonding curve factory address.
     * @param _bondingCurveFactory The address of the bonding curve factory contract.
     */
    function initialize(address _bondingCurveFactory) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        bondingCurveFactory = IBondingCurveFactory(_bondingCurveFactory);
    }

    function createBondingCurve(
        string memory name,
        string memory symbol,
        bytes memory metadata,
        bool isDevLocked,
        string memory id
    ) external payable returns (address) {
        return
            bondingCurveFactory.createBondingCurveFor{value: msg.value}(
                name,
                symbol,
                metadata,
                msg.sender,
                isDevLocked,
                id
            );
    }

    function getBondingCurveFactory() external view returns (address) {
        return address(bondingCurveFactory);
    }

    function setBondingCurveFactory(
        address _bondingCurveFactory
    ) external onlyOwner nonZeroAddress(_bondingCurveFactory) {
        IBondingCurveFactory newBondingCurveFactory = IBondingCurveFactory(
            _bondingCurveFactory
        );
        if (!newBondingCurveFactory.isActive()) {
            revert FactoryManager__FactoryIsNotActive();
        }

        bondingCurveFactory.disable();
        bondingCurveFactory = newBondingCurveFactory;

        emit FactoryUpdated(address(newBondingCurveFactory));
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
