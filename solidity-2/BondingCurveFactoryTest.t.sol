// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondingCurve, IBondingCurve} from "src/BondingCurve.sol";
import {Test} from "forge-std/Test.sol";
import {LiquidityMigratorMock} from "test/mocks/LiquidityMigratorMock.t.sol";
import {AddressChecker} from "src/AddressChecker.sol";
import {BondingCurveFactory, IBondingCurveFactory} from "src/BondingCurveFactory.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {BurnableToken, IBurnableTokenActions} from "src/BurnableToken.sol";
import {LockPositionsNFT} from "src/LockPositionsNFT.sol";
import {LockManager} from "src/LockManager.sol";

contract FactoryManagerTest is Test {
    address DEV = makeAddr("dev");
    address FEE_ACCOUNT = makeAddr("feeAccount");
    string TOKEN_NAME = "Test";
    string TOKEN_SYMBOL = "TEST";
    BondingCurveFactory bondingCurveFactory;
    FactoryManager factoryManager;
    address[] dexes;
    string constant ID = "1";
    bytes constant METADATA =
        abi.encode(
            "Test Token",
            "https://example.com/image.png",
            "https://t.me/example"
            "https://twitter.com/example",
            "https://farcast.xyz/example",
            "https://example.com"
        );

    function setUp() public {
        LiquidityMigratorMock liquidityMigrator = new LiquidityMigratorMock(
            FEE_ACCOUNT
        );

        AddressChecker addressChecker = new AddressChecker(dexes);
        BondingCurvesStorage bondingCurvesStorageImpl = new BondingCurvesStorage();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(bondingCurvesStorageImpl),
            ""
        );
        BondingCurvesStorage bondingCurvesStorage = BondingCurvesStorage(
            address(proxy)
        );

        BondingCurve bondingCurveImpl = new BondingCurve();
        BurnableToken burnableTokenImpl = new BurnableToken();
        LockManager lockManagerImpl = new LockManager();
        LockPositionsNFT lockPositionsNFTImpl = new LockPositionsNFT();
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

    function testCreateBondingCurve() public {
        vm.prank(DEV);
        BondingCurve bondingCurve = BondingCurve(
            payable(
                bondingCurveFactory.createBondingCurve(
                    TOKEN_NAME,
                    TOKEN_SYMBOL,
                    METADATA,
                    false,
                    ID
                )
            )
        );
        IBurnableTokenActions burnableToken = bondingCurve.token();

        assertEq(burnableToken.name(), TOKEN_NAME);
        assertEq(burnableToken.symbol(), TOKEN_SYMBOL);
        assertEq(burnableToken.dev(), DEV);
    }

    function testCreateBondingCurveFor() public {
        vm.prank(address(factoryManager));
        BondingCurve bondingCurve = BondingCurve(
            payable(
                bondingCurveFactory.createBondingCurveFor(
                    TOKEN_NAME,
                    TOKEN_SYMBOL,
                    METADATA,
                    DEV,
                    false,
                    ID
                )
            )
        );
        IBurnableTokenActions burnableToken = bondingCurve.token();

        assertEq(burnableToken.name(), TOKEN_NAME);
        assertEq(burnableToken.symbol(), TOKEN_SYMBOL);
        assertEq(burnableToken.dev(), DEV);
    }

    function testCreateBondingCurveForRevertsWhenNotFactoryManager() public {
        vm.expectRevert(
            IBondingCurveFactory.BondingCurveFactory__NotFactoryManager.selector
        );

        bondingCurveFactory.createBondingCurveFor(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            METADATA,
            DEV,
            false,
            ID
        );
    }
}
