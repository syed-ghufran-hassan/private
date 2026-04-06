// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {DeployProject} from "script/DeployProject.s.sol";
import {LiquidityMigrator, IWETH9} from "src/LiquidityMigrator.sol";
import {BondingCurve} from "src/BondingCurve.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {FeeAccount} from "src/FeeAccount.sol";
import {BondingCurvesStorage} from "src/BondingCurvesStorage.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {ISwapRouter} from "@velodrome-finance/slipstream/periphery/interfaces/ISwapRouter.sol";
import {LiquidityLocker, ILiquidityLocker} from "src/LiquidityLocker.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ICLPool} from "@velodrome-finance/slipstream/core/interfaces/ICLPool.sol";

contract LockManagerTest is Test {
    uint256 constant MINIMAL_DIFF = 1 ether;
    uint256 constant BIG_DIFF = 100 ether;
    LiquidityMigrator liquidityMigrator;
    BondingCurvesStorage bondingCurvesStorage;
    FactoryManager factoryManager;
    FeeAccount feeAccount;
    BurnableToken burnableToken;
    IWETH9 weth;
    ISwapRouter swapRouter;
    address USER = address(1);
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
    LiquidityLocker liquidityLocker;
    BondingCurve bondingCurve;

    function setUp() external {
        DeployProject deployer = new DeployProject();
        liquidityMigrator = LiquidityMigrator(deployer.run());
        bondingCurvesStorage = BondingCurvesStorage(
            liquidityMigrator.getBondingCurveStorage()
        );
        vm.deal(USER, 10000 ether);
        factoryManager = bondingCurvesStorage.factoryManager();
        feeAccount = FeeAccount(payable(liquidityMigrator.getFeeAccount()));
        swapRouter = ISwapRouter(feeAccount.swapRouter());
        weth = liquidityMigrator.getWeth();
        vm.prank(USER, USER);
        vm.warp(0);
        bondingCurve = BondingCurve(
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
        vm.warp(6 seconds);
        vm.roll(block.number + 3);
        burnableToken = BurnableToken(payable(address(bondingCurve.token())));
        liquidityLocker = LiquidityLocker(
            address(liquidityMigrator.getLiquidityLocker())
        );
    }

    function testLockOk() public returns (uint256 tokenId, address pool) {
        vm.prank(USER, USER);
        bondingCurve.buyToken{value: USER.balance}(0, ID);
        pool = liquidityLocker.poolAt(0);
        tokenId = liquidityLocker.lockedPosition(pool);

        assertTrue(pool != address(0));
        assertEq(liquidityLocker.lockedPositionsCount(), 1);
        assertEq(
            IERC721(liquidityMigrator.nonfungiblePositionManager()).ownerOf(
                tokenId
            ),
            address(liquidityLocker)
        );

        return (tokenId, pool);
    }

    function testCollectFeesOk() external {
        (, address pool) = testLockOk();

        uint256 amountIn = 10 ether;
        address feeAccountAddress = address(feeAccount);
        uint256 startingAmountWeth = weth.balanceOf(feeAccountAddress);
        weth.deposit{value: amountIn}();
        weth.approve(address(swapRouter), amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: address(burnableToken),
                tickSpacing: ICLPool(pool).tickSpacing(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        ISwapRouter(swapRouter).exactInputSingle(params);

        vm.prank(feeAccountAddress);
        liquidityLocker.collectFees(pool);
        assertGt(weth.balanceOf(feeAccountAddress), startingAmountWeth);
    }

    function testMigrateLiquidityRevertsNoPools() external {
        testLockOk();
        vm.expectRevert(
            ILiquidityLocker.LiquidityLocker__NotValidPool.selector
        );
        liquidityLocker.migrateLiquidity(address(0));
    }

    function testCollectFeesRevertsNotValidPool() external {
        vm.expectRevert(
            ILiquidityLocker.LiquidityLocker__NotFeeAccount.selector
        );
        liquidityLocker.collectFees(address(0));
    }
}
