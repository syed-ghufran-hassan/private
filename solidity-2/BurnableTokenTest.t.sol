// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {DeployProject} from "script/DeployProject.s.sol";
import {LiquidityMigrator, IWETH9} from "src/LiquidityMigrator.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {BurnableToken, IBurnableTokenContext} from "src/BurnableToken.sol";
import {FeeAccount, IFeeAccount} from "src/FeeAccount.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {ISwapRouter} from "@velodrome-finance/slipstream/periphery/interfaces/ISwapRouter.sol";

contract SmartWalletMock {
    receive() external payable {}
}

contract BurnableTokenTest is Test {
    uint256 constant MINIMAL_DIFF = 1 ether;
    uint256 constant BIG_DIFF = 100 ether;
    LiquidityMigrator liquidityMigrator;
    BondingCurvesStorage bondingCurvesStorage;
    FactoryManager factoryManager;
    FeeAccount feeAccount;
    BurnableToken burnableToken;
    IWETH9 weth;
    ISwapRouter swapRouter;
    address USER1 = address(1);
    address USER2 = address(2);
    address DEV = makeAddr("dev");
    SmartWalletMock smartWalletMock;
    uint256 VESTING_DURATION_DEV = 6_840_004; // update if DEV share or duration calculation is changed
    string constant ID = "1";
    bytes metadata =
        abi.encode(
            "Test Token",
            "https://example.com/image.png",
            "https://t.me/example",
            "https://twitter.com/example",
            "https://farcast.xyz/example",
            "https://example.com"
        );

    function setUp() external {
        smartWalletMock = new SmartWalletMock();
        DeployProject deployer = new DeployProject();
        liquidityMigrator = LiquidityMigrator(deployer.run());
        bondingCurvesStorage = BondingCurvesStorage(
            liquidityMigrator.getBondingCurveStorage()
        );
        vm.deal(USER1, 10000 ether);
        vm.deal(USER2, 10000 ether);
        vm.deal(DEV, 10000 ether);
        factoryManager = bondingCurvesStorage.factoryManager();
        feeAccount = FeeAccount(payable(liquidityMigrator.getFeeAccount()));
        swapRouter = ISwapRouter(feeAccount.swapRouter());
        weth = liquidityMigrator.getWeth();
        vm.prank(DEV, DEV);
        BondingCurve bondingCurve = BondingCurve(
            payable(
                factoryManager.createBondingCurve(
                    "Test",
                    "TEST",
                    metadata,
                    false,
                    ID
                )
            )
        );
        vm.warp(block.timestamp + 6 seconds);
        vm.roll(block.number + 3);
        burnableToken = BurnableToken(payable(address(bondingCurve.token())));
        vm.prank(USER1, USER1);
        bondingCurve.buyToken{value: MINIMAL_DIFF}(0, ID);
        vm.prank(USER2, USER2);
        bondingCurve.buyToken{value: MINIMAL_DIFF}(0, ID);
        vm.prank(DEV, DEV);
        bondingCurve.buyToken{value: DEV.balance}(0, ID);
    }

    function testCollectsFees() public {
        _buyToken(BIG_DIFF, address(this));
        _sellToken(burnableToken.balanceOf(address(this)), address(this));
        address CALLER = makeAddr("caller");

        vm.prank(CALLER);
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));

        assertGt(weth.balanceOf(feeAccount.treasury()), 0);
        // assertGt(weth.balanceOf(CALLER), 0);
    }

    function testBurnDoesntAffectDividends() external {
        testCollectsFees();

        uint256 dividendsBefore = burnableToken.withdrawableDividendOf(DEV);
        vm.startPrank(DEV);
        burnableToken.burn(burnableToken.balanceOf(DEV));
        vm.stopPrank();

        uint256 dividendsAfter = burnableToken.withdrawableDividendOf(DEV);

        assertEq(burnableToken.balanceOf(DEV), 0);
        assertEq(dividendsBefore, dividendsAfter);
    }

    function testTransferWithdrawsDividends() external {
        testCollectsFees();

        uint256 dividendsBeforeDev = burnableToken.withdrawableDividendOf(DEV);
        uint256 dividendsBeforeUser = burnableToken.withdrawableDividendOf(
            USER2
        );
        vm.startPrank(DEV);
        vm.warp(block.timestamp + VESTING_DURATION_DEV);
        vm.roll(block.number + 1);
        burnableToken.transfer(USER2, burnableToken.balanceOf(DEV));
        vm.stopPrank();

        uint256 dividendsAfterDev = burnableToken.withdrawableDividendOf(DEV);
        uint256 dividendsAfterUser = burnableToken.withdrawableDividendOf(
            USER2
        );

        assertEq(dividendsAfterDev, 0);
        assertGt(dividendsBeforeDev, dividendsAfterDev);
        assertEq(dividendsBeforeUser, dividendsAfterUser);
    }

    function testTransferFromWithdrawsDividends() external {
        testCollectsFees();

        uint256 dividendsBeforeDev = burnableToken.withdrawableDividendOf(DEV);
        uint256 dividendsBeforeUser = burnableToken.withdrawableDividendOf(
            USER2
        );
        uint256 transferAmount = burnableToken.balanceOf(DEV);

        vm.prank(DEV);
        burnableToken.approve(USER2, transferAmount);
        vm.warp(block.timestamp + VESTING_DURATION_DEV);
        vm.roll(block.number + 1);
        vm.prank(USER2);
        burnableToken.transferFrom(DEV, USER2, transferAmount);

        uint256 dividendsAfterDev = burnableToken.withdrawableDividendOf(DEV);
        uint256 dividendsAfterUser = burnableToken.withdrawableDividendOf(
            USER2
        );

        assertEq(dividendsAfterDev, 0);
        assertGt(dividendsBeforeDev, dividendsAfterDev);
        assertEq(dividendsBeforeUser, dividendsAfterUser);
    }

    function testDevCanWithdrawDividend() public {
        testCollectsFees();
        uint256 startingBalanceDev = DEV.balance;

        vm.prank(DEV);
        burnableToken.withdrawDividend();

        assertGt(DEV.balance, startingBalanceDev);
    }

    function testHoldersWithdrawProportionateDividend() public {
        testCollectsFees();

        vm.prank(USER1);
        burnableToken.withdrawDividend();

        vm.prank(USER2);
        burnableToken.withdrawDividend();

        assertGt(USER2.balance, 0);
        assertGt(USER1.balance, USER2.balance);
    }

    function testHoldersWithdrawEquelDividend() public {
        uint256 diff = burnableToken.balanceOf(USER1) -
            burnableToken.balanceOf(USER2);
        vm.prank(USER1);
        burnableToken.burn(diff);
        testCollectsFees();

        vm.prank(USER1);
        burnableToken.withdrawDividend();

        vm.prank(USER2);
        burnableToken.withdrawDividend();

        assertGt(USER1.balance, 0);
        assertEq(USER1.balance, USER2.balance);
    }

    function testHoldersWithdrawTheirDividend() public {
        testCollectsFees();

        vm.prank(USER1);
        burnableToken.withdrawDividend();

        vm.prank(USER2);
        burnableToken.withdrawDividend();

        assertGt(USER1.balance, 0);
        assertGt(USER2.balance, 0);
        assertGt(USER1.balance, USER2.balance);
    }

    function testHoldersWithdrawEquelDividendAfterDevSells() public {
        testHoldersWithdrawEquelDividend();

        vm.startPrank(DEV);
        (, uint256 unlockTimePostMigration, , ) = burnableToken.holdersVesting(
            DEV
        );
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + 1);
        _buyToken(BIG_DIFF, DEV);
        _sellToken(burnableToken.balanceOf(DEV), DEV);
        vm.stopPrank();
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));

        vm.prank(USER1);
        burnableToken.withdrawDividend();

        vm.prank(USER2);
        burnableToken.withdrawDividend();

        assertGt(USER1.balance, 0);
        assertEq(USER1.balance, USER2.balance);
    }

    function testSmartWalletsCanWithdrawDividendIfPayable() external {
        vm.deal(address(smartWalletMock), BIG_DIFF);
        vm.startPrank(address(smartWalletMock));
        _buyToken(BIG_DIFF, address(smartWalletMock));
        vm.stopPrank();
        _buyToken(BIG_DIFF, address(this));
        uint256 startingBalance = address(smartWalletMock).balance;
        vm.prank(DEV);
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));

        vm.prank(address(smartWalletMock));
        burnableToken.withdrawDividend();

        assertGt(burnableToken.balanceOf(address(smartWalletMock)), 0);
        assertGt(address(smartWalletMock).balance, startingBalance);
    }

    function testSmartWalletsCantWithdrawDividendIfNotPayable() external {
        _buyToken(BIG_DIFF, address(this));
        vm.startPrank(DEV);
        _buyToken(BIG_DIFF, DEV);
        vm.stopPrank();
        uint256 startingBalance = address(this).balance;
        vm.prank(DEV);
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));

        vm.prank(address(this));
        burnableToken.withdrawDividend();

        assertGt(burnableToken.balanceOf(address(this)), 0);
        assertEq(address(this).balance, startingBalance);
    }

    function testSmartWalletsUncollectedDividendsRedistribute() external {
        _buyToken(BIG_DIFF, address(this));
        vm.prank(USER1);
        burnableToken.withdrawDividend();
        vm.prank(USER2);
        burnableToken.withdrawDividend();
        vm.startPrank(DEV);
        _buyToken(BIG_DIFF, DEV);
        vm.stopPrank();
        uint256 startingBalanceContract = address(this).balance;
        uint256 startingBalanceUser1 = USER1.balance;
        uint256 startingBalanceUser2 = USER2.balance;
        vm.prank(DEV);
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));

        vm.prank(address(this));
        burnableToken.withdrawDividend();
        vm.prank(USER1);
        burnableToken.withdrawDividend();
        vm.prank(USER2);
        burnableToken.withdrawDividend();

        assertEq(address(this).balance, startingBalanceContract);
        assertGt(USER1.balance, startingBalanceUser1);
        assertGt(USER2.balance, startingBalanceUser2);
    }

    function testChangeDev() external {
        vm.prank(DEV);
        burnableToken.setDev(address(0));
        assertEq(address(0), burnableToken.dev());
    }

    function testTransfersRevertIfAmountNotVestedDev() external {
        uint256 transferAmount = burnableToken.balanceOf(DEV);

        vm.prank(DEV);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBurnableTokenContext.BurnableToken__UnvestedAmount.selector,
                block.timestamp + VESTING_DURATION_DEV,
                transferAmount
            )
        );
        burnableToken.transfer(USER2, transferAmount);
    }

    function testTransfersOkIfAmountNotVestedDev()
        public
        returns (uint256 startingBlockTimestamp, uint256 transferAmount)
    {
        transferAmount = burnableToken.balanceOf(DEV);
        uint256 startingAmount = burnableToken.balanceOf(USER2);
        startingBlockTimestamp = block.timestamp;
        uint256 unlockTimeDev = block.timestamp + VESTING_DURATION_DEV;

        vm.warp(unlockTimeDev);
        vm.roll(block.number + 1);
        vm.prank(DEV);
        burnableToken.transfer(USER2, transferAmount);

        assertEq(burnableToken.balanceOf(DEV), 0);
        assertEq(
            burnableToken.balanceOf(USER2),
            startingAmount + transferAmount
        );

        return (startingBlockTimestamp, transferAmount);
    }

    function testTransfersOkIfAmountVestedUser2() public returns (uint256) {
        (
            uint256 startingBlockTimestamp,
            uint256 transferAmount
        ) = testTransfersOkIfAmountNotVestedDev();
        uint256 startingAmount = burnableToken.balanceOf(USER2);

        vm.prank(USER2);
        burnableToken.transfer(DEV, transferAmount);

        assertEq(burnableToken.balanceOf(DEV), transferAmount);
        assertEq(
            burnableToken.balanceOf(USER2),
            startingAmount - transferAmount
        );

        return startingBlockTimestamp;
    }

    function testGetVestedAmount() public {
        (, uint256 transferAmount) = testTransfersOkIfAmountNotVestedDev();
        uint256 lockAmount = burnableToken.balanceOf(USER2) -
            transferAmount +
            1;

        address expectedLockManagerAddress = address(
            0x2e6fb9A2ec7161dB1DC40caCD8C9b323F3973fB7
        ); // precompiled address, can change
        address expectedLockNftAddress = address(
            0x5669B6Fd17F09499bb06ea47aAE339A2081fE8B8
        ); // precompiled address, can change

        vm.startPrank(USER2, USER2);
        burnableToken.approve(address(burnableToken), lockAmount);
        vm.expectEmit(true, true, true, false, address(feeAccount));
        emit IFeeAccount.NewLockManagerAndNFT(
            expectedLockManagerAddress,
            expectedLockNftAddress,
            address(burnableToken)
        );
        uint256 lockId = burnableToken.lock(lockAmount, 365);
        vm.stopPrank();

        assertEq(burnableToken.balanceOf(USER2), transferAmount - 1);
        assertEq(burnableToken.getVestedAmount(USER2), transferAmount - 1);

        vm.warp(block.timestamp + 365 days + 1);
        vm.roll(block.number + 1);
        vm.startPrank(DEV);
        uint256 boughtAmount = _buyToken(BIG_DIFF, DEV);
        _sellToken(boughtAmount, DEV);
        vm.stopPrank();

        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));
        vm.startPrank(USER2, USER2);
        burnableToken.lockManager().claimRewards(lockId);
        vm.stopPrank();

        assertGt(burnableToken.getVestedAmount(USER2), transferAmount);

        // vm.startPrank(USER2);
        // burnableToken.burn(
        //     burnableToken.balanceOf(USER2) -
        //         burnableToken.getVestedAmount(USER2)
        // );
        // vm.stopPrank();

        assertEq(
            burnableToken.balanceOf(USER2),
            burnableToken.getVestedAmount(USER2)
        );
    }

    function testTransfersRevertIfAmountNotVestedUser2() external {
        uint256 startingBlockTimestamp = testTransfersOkIfAmountVestedUser2();

        uint256 transferAmount = burnableToken.balanceOf(USER2);
        (uint256 unlockTime, ) = burnableToken
            .calculateHolderVestingPostMigration(USER2);

        vm.warp(unlockTime - 1);
        vm.prank(USER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBurnableTokenContext.BurnableToken__UnvestedAmount.selector,
                unlockTime,
                transferAmount
            )
        );
        burnableToken.transfer(DEV, transferAmount);
    }

    function testAllTransfersOkAfterMaxVestingPeriod() external {
        testGetVestedAmount();
        vm.warp(block.timestamp + burnableToken.MAX_VESTING_PERIOD());
        vm.roll(block.number + 1);

        assertEq(
            burnableToken.balanceOf(DEV),
            burnableToken.getVestedAmount(DEV)
        );
        assertEq(
            burnableToken.balanceOf(USER1),
            burnableToken.getVestedAmount(USER1)
        );
        assertEq(
            burnableToken.balanceOf(USER2),
            burnableToken.getVestedAmount(USER2)
        );
    }

    function _buyToken(
        uint256 amount,
        address recepient
    ) private returns (uint256) {
        weth.deposit{value: amount}();
        weth.approve(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(burnableToken),
                tickSpacing: feeAccount
                    .getCompetingTokenRefferences(address(burnableToken))
                    .pool
                    .tickSpacing(),
                recipient: recepient,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        return swapRouter.exactInputSingle(params);
    }

    function _sellToken(
        uint256 amount,
        address recepient
    ) private returns (uint256 amountOut) {
        burnableToken.approve(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(burnableToken),
                tokenOut: address(weth),
                tickSpacing: feeAccount
                    .getCompetingTokenRefferences(address(burnableToken))
                    .pool
                    .tickSpacing(),
                recipient: recepient,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);
        return amountOut;
    }
}
