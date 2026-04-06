// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {IBurnableTokenActions, BurnableToken} from "src/BurnableToken.sol";
import {Test} from "forge-std/Test.sol";
import {LiquidityMigratorMock} from "test/mocks/LiquidityMigratorMock.t.sol";
import {AddressChecker} from "src/AddressChecker.sol";
import {BondingCurveFactory} from "src/BondingCurveFactory.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {LockManager} from "src/LockManager.sol";
import {LockPositionsNFT} from "src/LockPositionsNFT.sol";

contract FactoryManagerTest is Test {
    address DEV = makeAddr("dev");
    address FEE_ACCOUNT = makeAddr("feeAccount");
    string TOKEN_NAME = "Test";
    string TOKEN_SYMBOL = "TEST";
    BondingCurveFactory bondingCurveFactory;
    BondingCurvesStorage bondingCurvesStorage;
    FactoryManager factoryManager;
    address[] dexes;

    function setUp() public {
        LiquidityMigratorMock liquidityMigrator = new LiquidityMigratorMock(
            FEE_ACCOUNT
        );

        dexes.push(address(0));
        AddressChecker addressChecker = new AddressChecker(dexes);
        BondingCurvesStorage bondingCurvesStorageImpl = new BondingCurvesStorage();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bondingCurvesStorageImpl),
            ""
        );
        BondingCurve bondingCurveImpl = new BondingCurve();
        BurnableToken burnableTokenImpl = new BurnableToken();
        LockManager lockManagerImpl = new LockManager();
        LockPositionsNFT lockPositionsNFTImpl = new LockPositionsNFT();
        bondingCurvesStorage = BondingCurvesStorage(address(proxy));
        bondingCurvesStorage.initialize(
            address(liquidityMigrator),
            address(addressChecker),
            address(bondingCurveImpl),
            address(burnableTokenImpl),
            address(lockManagerImpl),
            address(lockPositionsNFTImpl)
        );
        FactoryManager factoryManagerImpl = new FactoryManager();
        proxy = new ERC1967Proxy(address(factoryManagerImpl), "");
        factoryManager = FactoryManager(address(proxy));
        bondingCurveFactory = new BondingCurveFactory(
            address(bondingCurvesStorage)
        );
        factoryManager.initialize(address(bondingCurveFactory));
        bondingCurvesStorage.setFactoryManager(address(factoryManager));
    }

    function testCreateBondingCurve() external {
        vm.prank(DEV);
        BondingCurve bondingCurve = BondingCurve(
            payable(
                factoryManager.createBondingCurve(
                    TOKEN_NAME,
                    TOKEN_SYMBOL,
                    "",
                    false,
                    ""
                )
            )
        );
        IBurnableTokenActions burnableToken = bondingCurve.token();

        assertEq(burnableToken.name(), TOKEN_NAME);
        assertEq(burnableToken.symbol(), TOKEN_SYMBOL);
        assertEq(burnableToken.dev(), DEV);
    }

    function testSetBondingCurveFactoryOk() external {
        BondingCurveFactory newBondingCurveFactory = new BondingCurveFactory(
            address(bondingCurvesStorage)
        );
        factoryManager.setBondingCurveFactory(address(newBondingCurveFactory));

        assertEq(
            factoryManager.getBondingCurveFactory(),
            address(newBondingCurveFactory)
        );
        assertTrue(!bondingCurveFactory.isActive());
    }

    function testSetBondingCurveFactoryRevertsIfZeroAddress() external {
        vm.expectRevert(FactoryManager.FactoryManager__ZeroAddress.selector);
        factoryManager.setBondingCurveFactory(address(0));
    }

    function testSetBondingCurveFactoryRevertsIfFactoryNotActive() external {
        bondingCurveFactory.disable();

        vm.expectRevert(
            FactoryManager.FactoryManager__FactoryIsNotActive.selector
        );
        factoryManager.setBondingCurveFactory(address(bondingCurveFactory));
    }
}
