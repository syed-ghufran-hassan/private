// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ICLPool} from "@velodrome-finance/slipstream/core/interfaces/ICLPool.sol";
import {INonfungiblePositionManager} from "@velodrome-finance/pool-launcher/external/INonfungiblePositionManager.sol";
import {ICLLockerFactory} from "@velodrome-finance/pool-launcher/interfaces/extensions/cl/ICLLockerFactory.sol";
import {ILiquidityLocker} from "src/interfaces/ILiquidityLocker.sol";
import {ILiquidityMigrator} from "src/interfaces/ILiquidityMigrator.sol";
import {IFeeAccount} from "src/interfaces/IFeeAccount.sol";

contract LiquidityLocker is ILiquidityLocker, Ownable {
    // Aero Concentrated Liquidity Locker Factory address. Constant, as it is immutable in Aero's PoolLauncher contract.
    address public constant override AERO_LOCKER_FACTORY =
        0x8BF02b8da7a6091Ac1326d6db2ed25214D812219;
    ILiquidityMigrator public liquidityMigrator;
    uint256 public override lockedPositionsCount;
    address[] private pools;
    mapping(address => uint256) private lockedPositions;
    uint128 private constant MAX_FEE_COLLECTED = type(uint128).max;
    uint32 private constant ETERNAL_LOCK = type(uint32).max;

    constructor(address _liquidityMigrator) Ownable(msg.sender) {
        liquidityMigrator = ILiquidityMigrator(_liquidityMigrator);
    }

    modifier onlyLiquidityMigrator() {
        if (msg.sender != address(liquidityMigrator)) {
            revert LiquidityLocker__NotLiquidityMigrator();
        }
        _;
    }
    modifier onlyFeeAccount() {
        if (msg.sender != liquidityMigrator.getFeeAccount()) {
            revert LiquidityLocker__NotFeeAccount();
        }
        _;
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function setLiquidityMigrator(
        address _liquidityMigrator
    ) external onlyOwner {
        liquidityMigrator = ILiquidityMigrator(_liquidityMigrator);
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function lock(
        uint256 tokenId,
        address pool
    ) external override onlyLiquidityMigrator {
        lockedPositions[pool] = tokenId;
        pools.push(pool);
        lockedPositionsCount += 1;

        IERC721(liquidityMigrator.nonfungiblePositionManager()).transferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        emit LiquidityLocked(tokenId, pool);
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function collectFees(
        address pool
    )
        external
        override
        onlyFeeAccount
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 tokenId = lockedPositions[pool];

        // Non-fungible position manager token IDs are positive, so 0 is an invalid token ID
        if (tokenId == 0) {
            revert LiquidityLocker__NotValidPool();
        }

        INonfungiblePositionManager.CollectParams
            memory collectParams = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: MAX_FEE_COLLECTED,
                amount1Max: MAX_FEE_COLLECTED
            });
        INonfungiblePositionManager nfpm = INonfungiblePositionManager(
            address(
                ILiquidityMigrator(liquidityMigrator)
                    .nonfungiblePositionManager()
            )
        );

        (amount0, amount1) = nfpm.collect(collectParams);

        if (amount0 > 0 || amount1 > 0) {
            emit CollectedFees(amount0, amount1);
        }

        return (amount0, amount1);
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function migrateLiquidity(address pool) external override {
        address feeAccount = liquidityMigrator.getFeeAccount();
        uint256 tokenId = lockedPositions[pool];

        if (pools.length == 0) {
            revert LiquidityLocker__EmptyLockedPositions();
        }
        // Non-fungible position manager token IDs are positive, so 0 is an invalid token ID
        if (tokenId == 0) {
            revert LiquidityLocker__NotValidPool();
        }
        address token = ICLPool(pool).token0();
        address weth = ICLPool(pool).token1();
        if (token == ILiquidityMigrator(liquidityMigrator).getWethAddress()) {
            (token, weth) = (weth, token);
        }

        lockedPositions[pool] = 0;
        lockedPositionsCount -= 1;

        ILiquidityMigrator(liquidityMigrator)
            .nonfungiblePositionManager()
            .approve(AERO_LOCKER_FACTORY, tokenId);
        address locker = ICLLockerFactory(AERO_LOCKER_FACTORY).lock(
            tokenId,
            ETERNAL_LOCK,
            address(0),
            0,
            0,
            feeAccount
        );
        IFeeAccount(feeAccount).addCompetingToken(
            payable(token),
            weth,
            pool,
            locker
        );

        emit LiquidityMigrated(tokenId, pool, locker);
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function lockedPosition(
        address pool
    ) external view override returns (uint256 tokenId) {
        return lockedPositions[pool];
    }

    /**
     * @inheritdoc ILiquidityLocker
     */
    function poolAt(
        uint256 index
    ) external view override returns (address pool) {
        return pools[index];
    }
}
