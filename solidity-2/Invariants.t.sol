// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {DeployProject} from "script/DeployProject.s.sol";
import {LiquidityMigrator, IWETH9} from "src/LiquidityMigrator.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {FeeAccount} from "src/FeeAccount.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {ISwapRouter} from "@velodrome-finance/slipstream/periphery/interfaces/ISwapRouter.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract Invariants is StdInvariant, Test {
    uint256 constant CHECK_IS_RECEIVER_AMOUNT = 0.0001 ether;
    uint256 constant MINIMAL_DIFF = 1 ether;
    uint256 constant MAX_VESTING_DURATION = 365 days;
    DeployProject deployer;
    FeeAccount feeAccount;
    ISwapRouter swapRouter;
    IWETH9 weth;
    address USER1 = makeAddr("user1");
    address USER2 = makeAddr("user2");
    address DEV = makeAddr("dev");
    BurnableToken burnableToken;
    Handler handler;
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
    uint256 totalClaimedDividends;
    uint256 totalDividends;
    uint256 lastTokenBalance;

    function setUp() external {
        deployer = new DeployProject();
        LiquidityMigrator liquidityMigrator = LiquidityMigrator(deployer.run());
        BondingCurvesStorage bondingCurvesStorage = BondingCurvesStorage(
            liquidityMigrator.getBondingCurveStorage()
        );
        vm.deal(USER1, 10000 ether);
        vm.deal(USER2, 10000 ether);
        vm.deal(DEV, 10000 ether);
        FactoryManager factoryManager = bondingCurvesStorage.factoryManager();
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
        burnableToken = BurnableToken(payable(address(bondingCurve.token())));
        vm.warp(block.timestamp + 6 seconds);
        vm.roll(block.number + 3);

        vm.prank(USER1, USER1);
        bondingCurve.buyToken{value: MINIMAL_DIFF}(0, ID);
        vm.prank(USER2, USER2);
        bondingCurve.buyToken{value: MINIMAL_DIFF}(0, ID);
        vm.prank(DEV, DEV);
        bondingCurve.buyToken{value: DEV.balance}(0, ID);
        handler = new Handler(
            swapRouter,
            weth,
            USER1,
            USER2,
            burnableToken,
            feeAccount,
            address(this)
        );
        vm.warp(block.timestamp + MAX_VESTING_DURATION + 1);
        vm.roll(block.number + (MAX_VESTING_DURATION + 1) / 2); // 2 blocks per second
        targetContract(address(handler));
    }

    function invariant_dividendsMustAddUp() public {
        console2.log("ENTER invariant_dividendsMustAddUp");
        uint256 unclaimedDividends = getTokenBalance();
        console2.log("unclaimedDividends before: ", unclaimedDividends);
        console2.log("lastTokenBalance before: ", lastTokenBalance);

        collectFeesAndDistribute(USER1);
        checkTotalDividendsAndSetLastBalance();

        unclaimedDividends = getTokenBalance();
        console2.log("totalDividends: ", totalDividends);
        console2.log("totalClaimedDividends: ", totalClaimedDividends);
        console2.log("unclaimedDividends after: ", unclaimedDividends);
        console2.log("lastTokenBalance after: ", lastTokenBalance);

        assertEq(totalDividends, unclaimedDividends + totalClaimedDividends);
    }

    function collectFeesAndDistribute(address caller) public {
        console2.log("ENTER collectFeesAndDistribute", caller);

        uint256 ethBalanceBeforeToken = getTokenBalance();
        console2.log("ethBalanceBeforeToken before: ", ethBalanceBeforeToken);
        console2.log("lastTokenBalance before: ", lastTokenBalance);
        vm.prank(caller);
        feeAccount.collectFeesAndDistribute(payable(address(burnableToken)));
    }

    function claimDividend(address holder) public {
        console2.log("ENTER claimDividend", holder);
        if (_checkIfCanReceiveEther(holder)) {
            totalClaimedDividends += burnableToken.withdrawableDividendOf(
                holder
            );
        }

        vm.prank(holder);
        burnableToken.withdrawDividend();
    }

    function transfer(address from, address to, uint256 amount) public {
        console2.log("ENTER transfer", from, to, amount);
        if (_checkIfCanReceiveEther(to)) {
            totalClaimedDividends += burnableToken.withdrawableDividendOf(from);
        }

        vm.prank(from);
        burnableToken.transfer(to, amount);
    }

    function swapToken(
        uint256 amount,
        address recepient,
        bool isBuy
    ) external returns (uint256) {
        address tokenIn = address(weth);
        address tokenOut = address(burnableToken);
        if (_checkIfCanReceiveEther(recepient) && !isBuy) {
            totalClaimedDividends += burnableToken.withdrawableDividendOf(
                recepient
            );
        }
        if (!isBuy) {
            (tokenIn, tokenOut) = (tokenOut, tokenIn);
            vm.prank(recepient);
            burnableToken.approve(address(swapRouter), amount);
        } else {
            vm.startPrank(recepient);
            weth.deposit{value: amount}();
            weth.approve(address(swapRouter), amount);
            vm.stopPrank();
        }

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
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

        vm.prank(recepient);
        try swapRouter.exactInputSingle(params) returns (uint256 amountOut) {
            return amountOut;
        } catch {
            console2.log("Swap failed, returning 0.");
            return 0;
        }
    }

    function getTokenBalance() public view returns (uint256) {
        return address(burnableToken).balance;
    }

    function setLastTokenBalance(uint256 tokenBalance) external {
        lastTokenBalance = tokenBalance;
    }

    function _checkIfCanReceiveEther(
        address addressSeed
    ) private returns (bool isReceiver) {
        (isReceiver, ) = addressSeed.call{value: CHECK_IS_RECEIVER_AMOUNT}("");

        return isReceiver;
    }

    function checkTotalDividendsAndSetLastBalance() public {
        uint256 ethBalanceAfterToken = getTokenBalance();
        console2.log("lastTokenBalance:", lastTokenBalance);
        console2.log("ethBalanceAfterToken:", ethBalanceAfterToken);

        if (ethBalanceAfterToken > lastTokenBalance) {
            totalDividends += ethBalanceAfterToken - lastTokenBalance;
        }
        lastTokenBalance = ethBalanceAfterToken;
    }
}
