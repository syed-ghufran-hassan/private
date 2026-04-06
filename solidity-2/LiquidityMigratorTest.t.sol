// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0;

import {Test} from "forge-std/Test.sol";
import {DeployProject} from "script/DeployProject.s.sol";
import {LiquidityMigrator, IWETH9, ILiquidityMigrator} from "src/LiquidityMigrator.sol";
import {BondingCurveFactory} from "src/BondingCurveFactory.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {FeeAccount} from "src/FeeAccount.sol";
import {AddressChecker} from "src/AddressChecker.sol";
import {TickMath} from "@uncx-network/contracts/uniswap-updated/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {IFeeAccount} from "src/interfaces/IFeeAccount.sol";
import {IBondingCurvesStorage} from "src/interfaces/IBondingCurvesStorage.sol";
import {SoulboundNFT} from "src/SoulboundNFT.sol";

contract LiquidityMigratorTest is Test {
    using TickMath for int24;
    using Math for uint256;

    LiquidityMigrator liquidityMigrator;
    BondingCurveFactory bondingCurveFactory;
    BondingCurvesStorage bondingCurvesStorage;
    FactoryManager factoryManager;
    FeeAccount feeAccount;
    address USER = makeAddr("user");
    IWETH9 weth;
    BurnableToken memeCoin;

    address[] subscriptions;
    uint96[] minBalances;
    uint96[] topUpLevels;

    function setUp() external {
        DeployProject deployer = new DeployProject();
        liquidityMigrator = LiquidityMigrator(deployer.run());
        bondingCurvesStorage = BondingCurvesStorage(
            liquidityMigrator.getBondingCurveStorage()
        );
        factoryManager = FactoryManager(bondingCurvesStorage.factoryManager());
        bondingCurveFactory = BondingCurveFactory(
            factoryManager.getBondingCurveFactory()
        );
        feeAccount = FeeAccount(payable(liquidityMigrator.getFeeAccount()));
        vm.deal(USER, 10 ether);
    }

    // function testGetSelectors() external {
    //     assertNotEq(IBondingCurvesStorage.Buy.selector, "");
    //     assertNotEq(IBondingCurvesStorage.Sell.selector, "");
    //     assertNotEq(IBondingCurvesStorage.NewBondingCurveCreated.selector, "");
    //     assertNotEq(IBondingCurvesStorage.NewKingOfTheCasts.selector, "");
    //     assertNotEq(ILiquidityMigrator.PoolMigrated.selector, "");
    //     assertNotEq(IFeeAccount.NewLockManagerAndNFT.selector, "");
    //     assertNotEq(IFeeAccount.Rewarded.selector, "");
    //     assertNotEq(SoulboundNFT.Minted.selector, "");
    // }

    function _createBondingCurve(
        string memory name,
        string memory symbol
    )
        internal
        returns (address payable bondingCurveAddress, BondingCurve bondingCurve)
    {
        bondingCurveAddress = payable(
            factoryManager.createBondingCurve(name, symbol, "", false, "")
        );
        bondingCurve = BondingCurve(bondingCurveAddress);
        return (bondingCurveAddress, bondingCurve);
    }
}
