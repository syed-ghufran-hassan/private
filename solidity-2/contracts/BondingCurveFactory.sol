// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBondingCurveFactory} from "src/interfaces/IBondingCurveFactory.sol";
import {IBondingCurvesStorage} from "src/interfaces/IBondingCurvesStorage.sol";
import {ILiquidityMigrator} from "src/interfaces/ILiquidityMigrator.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract BondingCurveFactory is Ownable, IBondingCurveFactory {
    bool public isActive = true;
    IBondingCurvesStorage private immutable i_bondingCurvesStorage;

    modifier active() {
        if (!isActive) {
            revert BondingCurveFactory__NotActive();
        }
        _;
    }
    modifier onlyOwnerOrFactoryManager() {
        if (
            msg.sender != owner() &&
            msg.sender != address(i_bondingCurvesStorage.factoryManager())
        ) {
            revert BondingCurveFactory__NotActive();
        }
        _;
    }
    modifier isFactoryManger() {
        if (msg.sender != address(i_bondingCurvesStorage.factoryManager())) {
            revert BondingCurveFactory__NotFactoryManager();
        }
        _;
    }

    /**
     * @dev Constructor to initialize the bonding curve factory with the bonding curves storage contract.
     * @param _bondingCurvesStorage The address of the bonding curves storage contract.
     */
    constructor(address _bondingCurvesStorage) Ownable(msg.sender) {
        i_bondingCurvesStorage = IBondingCurvesStorage(_bondingCurvesStorage);
    }

    /**
     * @inheritdoc IBondingCurveFactory
     */
    function createBondingCurve(
        string memory name,
        string memory symbol,
        bytes memory metadata,
        bool isDevLocked,
        string memory id
    ) external payable active returns (address) {
        return
            _createBondingCurve(
                name,
                symbol,
                metadata,
                msg.sender,
                isDevLocked,
                id
            );
    }

    /**
     * @inheritdoc IBondingCurveFactory
     */
    function createBondingCurveFor(
        string memory name,
        string memory symbol,
        bytes memory metadata,
        address dev,
        bool isDevLocked,
        string memory id
    ) external payable active isFactoryManger returns (address) {
        return
            _createBondingCurve(name, symbol, metadata, dev, isDevLocked, id);
    }

    /**
     * @inheritdoc IBondingCurveFactory
     */
    function bondingCurvesStorage() external view returns (address) {
        return address(i_bondingCurvesStorage);
    }

    /**
     * @inheritdoc IBondingCurveFactory
     */
    function disable() external onlyOwnerOrFactoryManager {
        isActive = false;
    }

    function _createBondingCurve(
        string memory name,
        string memory symbol,
        bytes memory _metadata,
        address dev,
        bool isDevLocked,
        string memory id
    ) private returns (address) {
        ILiquidityMigrator liquidityMigrator = ILiquidityMigrator(
            i_bondingCurvesStorage.liquidityMigrator()
        );

        address bondingCurveClone = Clones.clone(
            i_bondingCurvesStorage.bondingCurveImplementation()
        );
        IBondingCurve(bondingCurveClone).initialize(
            name,
            symbol,
            _metadata,
            i_bondingCurvesStorage.feePercent(),
            address(liquidityMigrator),
            liquidityMigrator.getFeeAccount(),
            isDevLocked,
            dev
        );

        i_bondingCurvesStorage.addBondingCurve(bondingCurveClone);
        i_bondingCurvesStorage.emitNewBondingCurveCreated(
            bondingCurveClone,
            address(IBondingCurve(bondingCurveClone).token()),
            dev,
            name,
            symbol,
            isDevLocked,
            id,
            _metadata
        );

        emit NewBondingCurveCreated(bondingCurveClone);
        if (msg.value > 0) {
            IBondingCurve(bondingCurveClone).buyTokenForDev{value: msg.value}(
                dev,
                0,
                id
            );
        }

        return bondingCurveClone;
    }
}
