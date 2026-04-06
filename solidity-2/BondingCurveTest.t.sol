// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {DeployProject} from "script/DeployProject.s.sol";
import {LiquidityMigrator} from "src/LiquidityMigrator.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {IBurnableTokenActions, IBurnableTokenContext} from "src/BurnableToken.sol";
import {FeeAccount} from "src/FeeAccount.sol";
import {TickMath} from "@uncx-network/contracts/uniswap-updated/TickMath.sol";
import {BancorBondingCurve} from "src/BancorBondingCurve.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";

contract BondingCurveTest is Test {
    using TickMath for int24;

    uint256 constant MINIMAL_DIFF = 1 ether;
    string constant TOKEN_NAME = "Test1";
    string constant TOKEN_SYMBOL = "TEST";
    LiquidityMigrator liquidityMigrator;
    BondingCurvesStorage bondingCurvesStorage;
    FactoryManager factoryManager;
    FeeAccount feeAccount;
    address USER1 = address(1);
    address USER2 = address(2);
    string constant ID = "1";
    bytes metadata =
        abi.encode(
            "Test Token",
            "https://example.com/image.png",
            "https://t.me/example"
            "https://twitter.com/example",
            "https://farcast.xyz/example",
            "https://example.com"
        );

    function setUp() external {
        DeployProject deployer = new DeployProject();
        liquidityMigrator = LiquidityMigrator(deployer.run());
        bondingCurvesStorage = BondingCurvesStorage(
            liquidityMigrator.getBondingCurveStorage()
        );
        factoryManager = bondingCurvesStorage.factoryManager();
        feeAccount = FeeAccount(payable(liquidityMigrator.getFeeAccount()));
        vm.deal(USER1, 10 ether);
        vm.deal(USER2, 10 ether);
    }

    function testDevBuy() public {
        vm.prank(USER1, USER1);
        BondingCurve newBondingCurve = BondingCurve(
            payable(
                factoryManager.createBondingCurve{value: MINIMAL_DIFF}(
                    "Test",
                    "TEST",
                    metadata,
                    true,
                    ID
                )
            )
        );

        assertGt(newBondingCurve.token().balanceOf(USER1), 0);
        assertGt(newBondingCurve.getReserveBalance(), 0);
    }

    function testSmartContractBuy() public {
        (, BondingCurve bondingCurve) = _createBondingCurve(
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        vm.prank(address(this), address(this));
        bondingCurve.buyToken{value: 1 ether}(0, ID);

        assertGt(bondingCurve.token().balanceOf(address(this)), 0);
        assertGt(bondingCurve.getReserveBalance(), 0);
    }

    function testEarlyBuyersWin() external {
        (, BondingCurve bondingCurve) = _createBondingCurve(
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        IBurnableTokenActions token = bondingCurve.token();
        uint256 deposit = 1 ether;
        uint256 startingBalanceUser1 = USER1.balance;
        uint256 startingBalanceUser2 = USER2.balance;

        vm.startPrank(USER1, USER1);
        bondingCurve.buyToken{value: deposit}(0, ID);
        uint256 user1Balance = token.balanceOf(USER1);
        token.approve(address(bondingCurve), user1Balance);
        vm.stopPrank();
        vm.startPrank(USER2, USER2);
        bondingCurve.buyToken{value: deposit}(0, ID);
        uint256 user2Balance = token.balanceOf(USER2);
        token.approve(address(bondingCurve), user2Balance);
        vm.stopPrank();
        _unlockTokens();
        vm.prank(USER1, USER1);
        bondingCurve.sellToken(user1Balance, 0, ID);
        vm.prank(USER2, USER2);
        bondingCurve.sellToken(user2Balance, 0, ID);

        assertGt(USER1.balance, startingBalanceUser1);
        assertLt(USER2.balance, startingBalanceUser2);
    }

    function testFirstSellerDoesntLooseMoney()
        public
        returns (BondingCurve, IBurnableTokenActions)
    {
        (, BondingCurve bondingCurve) = _createBondingCurve(
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        IBurnableTokenActions token = bondingCurve.token();
        uint256 deposit = 1 ether;
        uint256 expectedUser2Balance = deposit -
            bondingCurve.calculateFee(deposit);
        expectedUser2Balance -= bondingCurve.calculateFee(expectedUser2Balance);
        uint256 user2RemainingBalance = USER2.balance - deposit;

        vm.prank(USER1, USER1);
        bondingCurve.buyToken{value: deposit}(0, ID);
        uint256 startBalance = address(bondingCurve).balance;
        vm.startPrank(USER2, USER2);
        bondingCurve.buyToken{value: deposit}(0, ID);
        uint256 userBalance = token.balanceOf(USER2);
        _unlockTokens();
        token.approve(address(bondingCurve), userBalance);
        bondingCurve.sellToken(userBalance, 0, ID);
        vm.stopPrank();

        assertGe(address(bondingCurve).balance, startBalance);
        assertLe(USER2.balance - user2RemainingBalance, expectedUser2Balance);

        return (bondingCurve, token);
    }

    function testBuysAndSellsOk(
        uint256 amount
    ) public returns (BondingCurve, IBurnableTokenActions) {
        (, BondingCurve bondingCurve) = _createBondingCurve(
            TOKEN_NAME,
            TOKEN_SYMBOL
        );
        IBurnableTokenActions token = bondingCurve.token();
        amount = amount % 4.51 ether;
        if (amount < 102) {
            amount += 102;
        }
        uint256 userRemainingBalance = USER1.balance - amount;
        uint256 expectedUserBalance = amount -
            bondingCurve.calculateFee(amount);
        expectedUserBalance -= bondingCurve.calculateFee(expectedUserBalance);

        vm.startPrank(USER1, USER1);
        bondingCurve.buyToken{value: amount}(0, ID);
        uint256 userBalance = token.balanceOf(USER1);
        _unlockTokens();
        token.approve(address(bondingCurve), userBalance);
        bondingCurve.sellToken(userBalance, 0, ID);
        vm.stopPrank();

        assertLe(address(bondingCurve).balance, MINIMAL_DIFF);
        assertLe(USER1.balance - userRemainingBalance, expectedUserBalance);
        return (bondingCurve, token);
    }

    function testSecondSellerDoesntLooseMoney() external {
        (
            BondingCurve bondingCurve,
            IBurnableTokenActions token
        ) = testFirstSellerDoesntLooseMoney();
        uint256 deposit = 1 ether;
        uint256 expectedUserBalance = deposit -
            bondingCurve.calculateFee(deposit);
        expectedUserBalance -= bondingCurve.calculateFee(expectedUserBalance);
        uint256 userRemainingBalance = USER1.balance;

        vm.startPrank(USER1, USER1);
        uint256 userBalance = token.balanceOf(USER1);
        token.approve(address(bondingCurve), userBalance);
        bondingCurve.sellToken(userBalance, 0, ID);
        vm.stopPrank();

        assertLe(address(bondingCurve).balance, MINIMAL_DIFF);
        assertLe(USER1.balance - userRemainingBalance, expectedUserBalance);
    }

    function testKingOfTheCastsCantRepeat()
        public
        returns (BondingCurve, BondingCurve)
    {
        (
            address payable bondingCurveAddress1,
            BondingCurve bondingCurve1
        ) = _createBondingCurve(TOKEN_NAME, TOKEN_SYMBOL);
        (
            address payable bondingCurveAddress2,
            BondingCurve bondingCurve2
        ) = _createBondingCurve("Test2", "TEST2");
        IBurnableTokenActions token1 = bondingCurve1.token();

        vm.startPrank(USER1, USER1);
        bondingCurve1.buyToken{value: 3 ether}(0, ID);
        bondingCurve2.buyToken{value: 3 ether}(0, ID);
        _unlockTokens();
        token1.approve(address(bondingCurve1), token1.balanceOf(USER1));
        bondingCurve1.sellToken(token1.balanceOf(USER1), 0, ID);
        bondingCurve1.buyToken{value: 3 ether}(0, ID);
        vm.stopPrank();

        assertEq(
            bondingCurvesStorage.currentKingOfTheCasts(),
            bondingCurveAddress2
        );
        assertEq(
            bondingCurvesStorage.lastKingOfTheCasts(),
            bondingCurveAddress1
        );

        return (bondingCurve1, bondingCurve2);
    }

    function testKingOfTheCastsIsDetronedOnMigration() external {
        (
            BondingCurve bondingCurve1,
            BondingCurve bondingCurve2
        ) = testKingOfTheCastsCantRepeat();

        vm.prank(USER1, USER1);
        bondingCurve2.buyToken{value: 2 ether}(0, ID);

        assertEq(
            bondingCurvesStorage.currentKingOfTheCasts(),
            address(bondingCurve1)
        );
        assertEq(bondingCurvesStorage.lastKingOfTheCasts(), address(0));
    }

    function testMaxBuyDoesntExceedCurveSupply() external {
        (, BondingCurve bondingCurve) = _createBondingCurve("Test", "TEST");
        IBurnableTokenActions token = bondingCurve.token();
        uint256 curveSupply = 8e8 ether;

        vm.prank(USER1, USER1);
        bondingCurve.buyToken{value: 10 ether}(0, ID);
        uint256 maxBuy = bondingCurve.calculateMaxBuy();
        uint256 fee = bondingCurve.calculateFee(maxBuy);

        assertLe(token.balanceOf(USER1), curveSupply);
        assertGe(maxBuy - fee, 4.5 ether);
    }

    function testDevCanWithdrawWhenMigrates() external {
        vm.prank(USER1, USER1);
        address payable bondingCurveAddress = payable(
            factoryManager.createBondingCurve(
                "Test",
                "TEST",
                metadata,
                false,
                ID
            )
        );
        BondingCurve bondingCurve = BondingCurve(bondingCurveAddress);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 3);

        vm.startPrank(USER1, USER1);
        bondingCurve.buyToken{value: 10 ether}(0, ID);
        uint256 startingBalance = USER1.balance;
        bondingCurvesStorage.withdrawDevRewards();
        vm.stopPrank();

        assertEq(startingBalance + bondingCurve.DEV_REWARD(), USER1.balance);
        assertEq(bondingCurvesStorage.devRewards(USER1), 0);
    }

    function testLastKingOfTheCastsSwitches()
        public
        returns (BondingCurve, BondingCurve)
    {
        (
            address payable bondingCurveAddress1,
            BondingCurve bondingCurve1
        ) = _createBondingCurve(TOKEN_NAME, TOKEN_SYMBOL);
        (
            address payable bondingCurveAddress2,
            BondingCurve bondingCurve2
        ) = _createBondingCurve("Test2", "TEST2");
        (, BondingCurve bondingCurve3) = _createBondingCurve("Test3", "TEST3");

        vm.startPrank(USER1, USER1);
        bondingCurve1.buyToken{value: 3 ether}(0, ID);
        bondingCurve2.buyToken{value: 3 ether}(0, ID);
        bondingCurve3.buyToken{value: 3 ether}(0, ID);
        vm.stopPrank();
        vm.startPrank(USER2, USER2);
        bondingCurve3.buyToken{value: 3 ether}(0, ID);
        vm.stopPrank();

        assertEq(
            bondingCurvesStorage.currentKingOfTheCasts(),
            bondingCurveAddress2
        );
        assertEq(
            bondingCurvesStorage.lastKingOfTheCasts(),
            bondingCurveAddress1
        );

        return (bondingCurve1, bondingCurve2);
    }

    function testLastKingOfTheCastsSetsToZero() public returns (BondingCurve) {
        (
            BondingCurve bondingCurve1,
            BondingCurve bondingCurve2
        ) = testLastKingOfTheCastsSwitches();

        vm.startPrank(USER2, USER2);
        bondingCurve2.buyToken{value: 3 ether}(0, ID);
        vm.stopPrank();

        assertEq(
            bondingCurvesStorage.currentKingOfTheCasts(),
            address(bondingCurve1)
        );
        assertEq(bondingCurvesStorage.lastKingOfTheCasts(), address(0));
        return bondingCurve1;
    }

    function testCurrentKingOfTheCastsSetsToZero() external {
        BondingCurve bondingCurve = testLastKingOfTheCastsSetsToZero();

        vm.startPrank(USER2, USER2);
        bondingCurve.buyToken{value: 3 ether}(0, ID);
        vm.stopPrank();

        assertEq(bondingCurvesStorage.currentKingOfTheCasts(), address(0));
        assertEq(bondingCurvesStorage.lastKingOfTheCasts(), address(0));
    }

    function testEarlierBuyerCantDumpWhenLocked() external {
        (, BondingCurve bondingCurve) = _createBondingCurve(
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        IBurnableTokenActions token = bondingCurve.token();
        uint256 deposit = 1 ether;
        uint256 expectedUnlockTime = block.timestamp + 24 hours;

        vm.prank(USER1, USER1);
        bondingCurve.buyToken{value: deposit}(0, ID);
        vm.startPrank(USER2, USER2);
        bondingCurve.buyToken{value: deposit}(0, ID);
        uint256 userBalance = token.balanceOf(USER2);
        vm.warp(block.timestamp + 24 hours - 1 seconds);
        vm.roll(block.number + 1);
        token.approve(address(bondingCurve), userBalance);
        bondingCurve.sellToken(userBalance, 0, ID);
        vm.stopPrank();

        vm.startPrank(USER1, USER1);
        userBalance = token.balanceOf(USER1);
        token.approve(address(bondingCurve), userBalance);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBurnableTokenContext.BurnableToken__TransfersLocked.selector,
                expectedUnlockTime
            )
        );
        bondingCurve.sellToken(userBalance, 0, ID);
        vm.stopPrank();
    }

    function _createBondingCurve(
        string memory name,
        string memory symbol
    )
        internal
        returns (address payable bondingCurveAddress, BondingCurve bondingCurve)
    {
        bondingCurveAddress = payable(
            factoryManager.createBondingCurve(name, symbol, metadata, false, ID)
        );
        bondingCurve = BondingCurve(bondingCurveAddress);

        vm.warp(block.timestamp + 6 seconds);
        vm.roll(block.number + 3);
        return (bondingCurveAddress, bondingCurve);
    }

    function _unlockTokens() private {
        vm.warp(block.timestamp + 24 hours);
        vm.roll(block.number + 1);
    }
}
