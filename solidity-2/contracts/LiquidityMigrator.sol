// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {INonfungiblePositionManager} from "@velodrome-finance/slipstream/periphery/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "@velodrome-finance/slipstream/core/libraries/TickMath.sol";
import {ICLFactory} from "@velodrome-finance/slipstream/core/interfaces/ICLFactory.sol";
import {ICLPool} from "@velodrome-finance/slipstream/core/interfaces/ICLPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {IBondingCurvesStorage} from "src/interfaces/IBondingCurvesStorage.sol";
import {IFeeAccount} from "src/FeeAccount.sol";
import {ILiquidityMigrator, IWETH9} from "src/interfaces/ILiquidityMigrator.sol";
import {ICLLockerFactory} from "@velodrome-finance/pool-launcher/interfaces/extensions/cl/ICLLockerFactory.sol";
import {ILiquidityLocker} from "src/interfaces/ILiquidityLocker.sol";

contract LiquidityMigrator is Ownable, ILiquidityMigrator {
    using Math for uint256;

    string public constant LIQUIDITY_LOCKER_FEE_NAME = "LLP";
    uint32 private constant ETERNAL_LOCK = type(uint32).max;
    uint256 private constant Q96 = 2 ** 96;
    int24 private constant TICK_SPACING = 2000; // 1% fee tier
    address public constant AERO_LOCKER_FACTORY =
        0x8BF02b8da7a6091Ac1326d6db2ed25214D812219;
    address payable private immutable i_feeAccount;
    address private immutable i_wethAdress;
    IWETH9 private immutable i_weth;
    INonfungiblePositionManager private immutable i_nonfungiblePositionManager;
    ICLFactory private immutable i_iclFactory;
    ILiquidityLocker private immutable i_liquidityLocker;
    IBondingCurvesStorage private s_bondingCurvesStorage;

    modifier onlyBondingCurve() {
        if (!s_bondingCurvesStorage.bondingCurves(msg.sender)) {
            revert LiquidityMigrator__NotBondingCurve();
        }
        _;
    }

    /**
     * @dev Constructor to initialize the liquidity migrator with the necessary contracts and addresses.
     * @param feeAccount The address of the fee account that will receive fees.
     * @param _nonfungiblePositionManager The address of the NonfungiblePositionManager contract (see Aerodrome Concentrated Liquidity periphery).
     * @param poolFactory The address of the Aerodrome Concentrated Liquidity factory contract.
     * @param wethAdress The address of the WETH contract.
     * @param liquidityLocker The address of the liquidity locker contract.
     * @param bondingCurvesStorage The address of the bonding curves storage contract.
     */
    constructor(
        address payable feeAccount,
        address _nonfungiblePositionManager,
        address poolFactory,
        address wethAdress,
        address liquidityLocker,
        address bondingCurvesStorage
    ) Ownable(msg.sender) {
        i_feeAccount = feeAccount;
        i_nonfungiblePositionManager = INonfungiblePositionManager(
            _nonfungiblePositionManager
        );
        i_iclFactory = ICLFactory(poolFactory);
        i_wethAdress = wethAdress;
        i_weth = IWETH9(i_wethAdress);
        i_liquidityLocker = ILiquidityLocker(liquidityLocker);
        s_bondingCurvesStorage = IBondingCurvesStorage(bondingCurvesStorage);
    }

    function setBondingCurveStorage(
        address newBondingCurveFactory
    ) external onlyOwner {
        s_bondingCurvesStorage = IBondingCurvesStorage(newBondingCurveFactory);
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function getBondingCurveStorage() external view returns (address) {
        return address(s_bondingCurvesStorage);
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function getWethAddress() external view returns (address) {
        return i_wethAdress;
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function getWeth() external view returns (IWETH9) {
        return i_weth;
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function getLiquidityLocker() external view returns (ILiquidityLocker) {
        return i_liquidityLocker;
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function createPoolAndLockLiquidity(
        address payable token,
        uint256 amountToAdd
    )
        external
        payable
        onlyBondingCurve
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            address locker
        )
    {
        Token memory token0Struct = Token({
            tokenAddress: i_wethAdress,
            instance: IERC20(i_wethAdress),
            isWeth: true
        });
        Token memory token1Struct = Token({
            tokenAddress: token,
            instance: IERC20(token),
            isWeth: false
        });
        Pool memory poolStruct = Pool({
            poolAddress: address(0),
            instance: ICLPool(address(0)),
            token0: token0Struct,
            token1: token1Struct,
            amount0: msg.value,
            amount1: amountToAdd
        });

        Pool memory pool = _orderPoolTokens(poolStruct);
        uint256 amountWethDeposit = pool.token0.isWeth
            ? pool.amount0
            : pool.amount1;
        _depositEthInWeth(amountWethDeposit);
        (tokenId, liquidity, amount0, amount1) = _mintNewPosition(pool);
        pool.poolAddress = i_iclFactory.getPool(
            pool.token0.tokenAddress,
            pool.token1.tokenAddress,
            TICK_SPACING
        );
        pool.instance = ICLPool(pool.poolAddress);
        locker = _lockLiquidity(tokenId, pool.poolAddress);
        IFeeAccount(i_feeAccount).addCompetingToken(
            token,
            i_wethAdress,
            pool.poolAddress,
            locker
        );
        // avoiding stack too deep
        {
            (uint160 sqrtPriceX96, int24 tick, , , , ) = pool.instance.slot0();
            // initializing pool entity in the subgraph
            emit PoolCreated(
                pool.poolAddress,
                pool.token0.tokenAddress,
                pool.token1.tokenAddress,
                tick,
                block.timestamp,
                sqrtPriceX96
            );
        }

        emit PoolMigrated(
            pool.poolAddress,
            token,
            tokenId,
            locker,
            amount0,
            amount1,
            liquidity,
            block.timestamp
        );

        return (tokenId, liquidity, amount0, amount1, locker);
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function getFeeAccount() external view returns (address) {
        return i_feeAccount;
    }

    /**
     * @inheritdoc ILiquidityMigrator
     */
    function nonfungiblePositionManager()
        external
        view
        returns (INonfungiblePositionManager)
    {
        return i_nonfungiblePositionManager;
    }

    function _depositEthInWeth(uint256 amount) internal {
        i_weth.deposit{value: amount}();
    }

    function _mintNewPosition(
        Pool memory pool
    )
        internal
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (!pool.token0.isWeth) {
            pool.token0.instance.transferFrom(
                msg.sender,
                address(this),
                pool.amount0
            );
        }
        if (!pool.token1.isWeth) {
            pool.token1.instance.transferFrom(
                msg.sender,
                address(this),
                pool.amount1
            );
        }

        pool.token0.instance.approve(
            address(i_nonfungiblePositionManager),
            pool.amount0
        );
        pool.token1.instance.approve(
            address(i_nonfungiblePositionManager),
            pool.amount1
        );

        uint160 sqrtPriceX96 = _calculatesqrtPriceX96(
            pool.amount0,
            pool.amount1
        );
        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: pool.token0.tokenAddress,
                token1: pool.token1.tokenAddress,
                tickSpacing: TICK_SPACING,
                tickLower: (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING,
                tickUpper: (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING,
                amount0Desired: pool.amount0,
                amount1Desired: pool.amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                sqrtPriceX96: sqrtPriceX96
            });

        (tokenId, liquidity, amount0, amount1) = i_nonfungiblePositionManager
            .mint(params);

        if (amount0 < pool.amount0) {
            _manageSpareTokens(
                payable(pool.token0.tokenAddress),
                pool.amount0,
                amount0
            );
        }
        if (amount1 < pool.amount1) {
            _manageSpareTokens(
                payable(pool.token1.tokenAddress),
                pool.amount1,
                amount1
            );
        }
    }

    function _lockLiquidity(
        uint256 tokenId,
        address poolAddress
    ) internal returns (address locker) {
        IERC721(address(i_nonfungiblePositionManager)).approve(
            address(i_liquidityLocker),
            tokenId
        );
        i_liquidityLocker.lock(tokenId, poolAddress);

        emit LiquidityLocked(locker, tokenId, block.timestamp);
        return locker;
    }

    function _manageSpareTokens(
        address payable token,
        uint256 initialAmount,
        uint256 usedAmount
    ) internal {
        uint256 spareAmount = initialAmount - usedAmount;
        if (token != i_wethAdress) {
            BurnableToken burnable = BurnableToken(token);
            burnable.approve(address(i_nonfungiblePositionManager), 0);
            burnable.burn(spareAmount);
            return;
        }
        i_weth.approve(address(i_nonfungiblePositionManager), 0);

        if (i_weth.balanceOf(address(this)) > 0.1 ether) {
            _transferEtherToFeeAccount();
        }
    }

    function _transferEtherToFeeAccount() internal {
        i_weth.withdraw(i_weth.balanceOf(address(this)));
        (bool success, ) = payable(i_feeAccount).call{
            value: address(this).balance
        }("");
        if (!success) {
            revert LiquidityMigrator__TransferFailed();
        }
    }

    function _orderPoolTokens(
        Pool memory pool
    ) internal pure returns (Pool memory orderedPool) {
        orderedPool = pool;
        if (pool.token0.tokenAddress > pool.token1.tokenAddress) {
            orderedPool = Pool({
                poolAddress: pool.poolAddress,
                instance: pool.instance,
                token0: pool.token1,
                token1: pool.token0,
                amount0: pool.amount1,
                amount1: pool.amount0
            });
        }

        return orderedPool;
    }

    function _calculatesqrtPriceX96(
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint160) {
        if (amount1 > 18 ether) {
            uint256 priceRatio = (amount1 * Q96) / amount0;
            return uint160((priceRatio * Q96).sqrt());
        }

        uint256 scaledAmount1 = amount1 * (Q96 ** 2);
        return uint160((scaledAmount1 / amount0).sqrt());
    }
}
