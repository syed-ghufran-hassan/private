// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@velodrome-finance/slipstream/periphery/interfaces/ISwapRouter.sol";
import {ICLPool} from "@velodrome-finance/slipstream/core/interfaces/ICLPool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ILocker} from "@velodrome-finance/pool-launcher/interfaces/ILocker.sol";
import {OracleLibrary} from "@velodrome-finance/slipstream/periphery/libraries/OracleLibrary.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {ILiquidityMigrator, IWETH9} from "src/interfaces/ILiquidityMigrator.sol";
import {RewardResolver} from "src/RewardResolver.sol";
import {ILockManager} from "src/interfaces/ILockManager.sol";
import {ILiquidityLocker} from "src/interfaces/ILiquidityLocker.sol";
import {IFeeAccount} from "src/interfaces/IFeeAccount.sol";

contract FeeAccount is
    ReentrancyGuard,
    AutomationCompatibleInterface,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IFeeAccount,
    IERC721Receiver
{
    uint16 private constant SCALE = 1000;
    uint16 private slippage;
    address payable public treasury;
    RewardResolver public rewardResolver;
    ILiquidityMigrator public liquidityMigrator;
    address public liquidityLocker;
    address public swapRouter;
    uint256 public devRewardsCliff;
    uint256 public totalAccummulatedWethAmounts;
    uint16 public devRewardPercent;
    uint16 public treasuryRewardPercent;
    uint16 public basePercent;
    uint16 public additivePercent;
    mapping(address tokenAddress => TokenRefferences refferences)
        public competingTokens;
    mapping(address tokenAddress => uint256 amount)
        public accummulatedWethAmounts;

    // Gap for future storage variables. If you add new variables, decrease the size of the gap.
    uint256[50] private __gap;

    modifier onlyLiquidityMigratorOrLocker() {
        if (
            msg.sender != address(liquidityMigrator) &&
            msg.sender != liquidityLocker
        ) {
            revert FeeAccount__NotLiquidityMigratorOrLocker();
        }
        _;
    }
    modifier onlyGraduatedTokens() {
        if (address(competingTokens[msg.sender].pool) == address(0)) {
            revert FeeAccount__NotGraduatedToken();
        }
        _;
    }
    modifier nonZeroAddress(address addressToCheck) {
        if (addressToCheck == address(0)) {
            revert FeeAccount__ZeroAddress();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /**
     * @notice Initializes the FeeAccount contract with the necessary parameters.
     * @param _swapRouter The address of the Aerodrome Slipstream swap router contract.
     * @param _rewardResolver The address of the RewardResolver contract.
     * @param _treasury The address of the treasury that will receive fees.
     */
    function initialize(
        address _swapRouter,
        address _rewardResolver,
        address _treasury
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        swapRouter = _swapRouter;
        rewardResolver = RewardResolver(_rewardResolver);
        treasury = payable(_treasury);
        devRewardPercent = 200;
        treasuryRewardPercent = 200;
        basePercent = 500;
        additivePercent = 100;
        devRewardsCliff = 30; // number of days
        slippage = 800;

        // Initializing the subgraph's LatestReward entity.
        emit Rewarded(address(0), address(0), 0, block.timestamp);
    }

    /**
     * @notice Sets the dev rewards (from the pool) cliff in days.
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _devRewardsCliff The number of days after which dev rewards can be claimed.
     */
    function setDevRewardsCliff(uint256 _devRewardsCliff) external onlyOwner {
        devRewardsCliff = _devRewardsCliff;
    }

    /**
     * @notice Sets the percentage of the collected fees that goes to the devs, in basis points (scale of thousand, e.g. 100 = 1%).
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _devRewardPercent The percentage of the collected fees that goes to the devs.
     */
    function setDevRewardPercent(uint16 _devRewardPercent) external onlyOwner {
        devRewardPercent = _devRewardPercent;
    }

    /**
     * @notice Sets the base percentage of the collected fees that goes to each of the top token/s, in basis points (scale of thousand, e.g. 50 = 5%).
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _basePercent The base percentage of the collected fees that goes to the top token/s.
     */
    function setBasePercent(uint16 _basePercent) external onlyOwner {
        basePercent = _basePercent;
    }

    /**
     * @notice Sets the additive percentage of the collected fees, that progressively adds to the base percentage of each of the top token/s (ASCENDING).It is in basis points (scale of thousand, e.g. 10 = 1%).
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _additivePercent The additive percentage of the collected fees that goes to the top token/s.
     */
    function setAdditivePercent(uint16 _additivePercent) external onlyOwner {
        additivePercent = _additivePercent;
    }

    /**
     * @notice Sets the percentage of the collected fees that goes to the treasury, in basis points (scale of thousand, e.g. 10 = 1%).
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _treasuryRewardPercent The percentage of the collected fees that goes to the treasury.
     */
    function setTreasuryRewardPercent(
        uint16 _treasuryRewardPercent
    ) external onlyOwner {
        treasuryRewardPercent = _treasuryRewardPercent;
    }

    /**
     * @notice Sets the liquidity migrator contract address.
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _liquidityMigrator The address of the liquidity migrator contract.
     */
    function setLiquidityMigrator(
        address _liquidityMigrator
    ) external onlyOwner nonZeroAddress(_liquidityMigrator) {
        liquidityMigrator = ILiquidityMigrator(_liquidityMigrator);

        emit MigratorUpdated(_liquidityMigrator);
    }

    /**
     * @notice Sets the liquidity locker contract address.
     * @dev This function can only be called by the owner of the contract only once.
     *
     * @param _liquidityLocker The address of the liquidity locker contract.
     */
    function setLiquidityLocker(
        address _liquidityLocker
    ) external onlyOwner nonZeroAddress(_liquidityLocker) {
        if (liquidityLocker != address(0)) {
            revert FeeAccount__LockerInitialized();
        }

        liquidityLocker = _liquidityLocker;
    }

    /**
     * @notice Sets the treasury address that will receive fees.
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _treasury The address of the treasury that will receive fees.
     */
    function setTreasury(
        address payable _treasury
    ) external onlyOwner nonZeroAddress(_treasury) {
        treasury = _treasury;
    }

    /**
     * @notice Sets the Aerodrome Slipstream swap router contract address.
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _swapRouter The address of theAerodrome Slipstream swap router contract.
     */
    function setSwapRouter02(
        address _swapRouter
    ) external onlyOwner nonZeroAddress(_swapRouter) {
        swapRouter = _swapRouter;
    }

    /**
     * @notice Sets the slippage tolerance for swaps, in basis points (scale of thousand and acutal value is calculated as 1000 - value, e.g. value of 800 = 1000 - 800 = 200 => 20% slippage).
     * @dev This function can only be called by the owner of the contract.
     *
     * @param _slippage The slippage tolerance for swaps.
     */
    function setSlippage(uint16 _slippage) external onlyOwner {
        slippage = _slippage;
    }

    /**
     * @inheritdoc IFeeAccount
     */
    function addCompetingToken(
        address payable token,
        address otherToken,
        address pool,
        address locker
    ) external onlyLiquidityMigratorOrLocker nonZeroAddress(token) {
        competingTokens[token] = TokenRefferences({
            pool: ICLPool(pool),
            instance: BurnableToken(token),
            otherToken: IERC20(otherToken),
            locker: locker
        });
    }

    /**
     * @inheritdoc IFeeAccount
     */
    function getCompetingTokenRefferences(
        address token
    ) external view returns (TokenRefferences memory) {
        return competingTokens[token];
    }

    /**
     * @inheritdoc IFeeAccount
     */
    function emitNewLockManagerAndNFT(
        address lockManager,
        address lockNFT
    ) external onlyGraduatedTokens {
        emit NewLockManagerAndNFT(lockManager, lockNFT, msg.sender);
    }

    /**
     * @inheritdoc IFeeAccount
     */
    function collectFeesAndDistribute(
        address payable token
    ) external nonReentrant {
        TokenRefferences memory tokenRefferences = competingTokens[token];
        uint256 amount0;
        uint256 amount1;
        if (tokenRefferences.locker == address(0)) {
            address pool = address(tokenRefferences.pool);
            (amount0, amount1) = ILiquidityLocker(
                liquidityMigrator.getLiquidityLocker()
            ).collectFees(pool);
        } else {
            (amount0, amount1) = ILocker(tokenRefferences.locker).claimFees(
                address(this)
            );
        }

        BurnableToken burnableToken = BurnableToken(token);
        IWETH9 weth = liquidityMigrator.getWeth();
        uint256 tokenBalance = burnableToken.balanceOf(address(this));

        uint256 wethAmount = token < address(weth) ? amount1 : amount0;
        wethAmount += accummulatedWethAmounts[token];
        uint256 devRewardAmount;
        uint256 lockRewardAmount;
        if (tokenBalance >= SCALE) {
            devRewardAmount = burnableToken.dev() == address(0)
                ? 0
                : (tokenBalance * devRewardPercent) / SCALE;
            lockRewardAmount = tokenBalance - devRewardAmount;
        }
        uint256 treasuryAmount = (wethAmount * treasuryRewardPercent) / SCALE;
        uint256 dividendAmount = wethAmount - treasuryAmount;
        if (treasuryAmount == 0) {
            dividendAmount = 0;
            accummulatedWethAmounts[token] += wethAmount;
            totalAccummulatedWethAmounts += wethAmount;
        }
        if (treasuryAmount > 0) {
            weth.transfer(address(treasury), treasuryAmount);
        }
        if (devRewardAmount > 0) {
            burnableToken.approve(address(burnableToken), devRewardAmount);
            uint256 lockId = burnableToken.lock(
                devRewardAmount,
                devRewardsCliff
            );
            try
                burnableToken.lockManager().positionsNFT().safeTransfer(
                    burnableToken.dev(),
                    lockId
                )
            {
                // Successfully transferred the lock NFT to the dev
            } catch {
                // If transfer fails, we distribute the reward to the holders of the lock positions NFT
                burnableToken.lockManager().redistributeRewards(lockId);
            }
        }
        if (dividendAmount > 0) {
            weth.withdraw(dividendAmount);
            totalAccummulatedWethAmounts -= accummulatedWethAmounts[token];
            accummulatedWethAmounts[token] = 0;
            burnableToken.distributeDividends{value: dividendAmount}();
        }
        if (lockRewardAmount > 0) {
            ILockManager lockManager = burnableToken.lockManager();
            if (address(lockManager) == address(0)) {
                burnableToken.transfer(
                    address(burnableToken),
                    lockRewardAmount
                );
            }
            burnableToken.approve(address(lockManager), lockRewardAmount);
            lockManager.distributeRewards(lockRewardAmount);
        }
    }

    /**
     * @notice Implemented to satisfy the IERC721Receiver interface, for the mint function of LockPositionsNFT (in collectFeesAndDistribute). Do not send NFTs to this contract directly, as it will not handle them properly.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev This is the function that Chainlink nodes will call to check if the account is ready to reward the picked top tokens that bonded. This is measured with Aerodrome Concentrated Liquidity TWGP (time weighed geometric mean price). Price = 1.0001 ^ T, where T is time weighted arithemetic mean tick, that is stored on a subgraph.
     * The following is needed in order for upkeepNeeded to be true:
     * 1. The reward resolver contract has picked a winner (in WAIING state)
     * 2. Implicitly, the subscription has received LINK
     * @param - ignored
     * @return upkeepNeeded - true if the reward resolver had picked winners
     * @return - ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool winnerIsPicked = rewardResolver.getState() ==
            RewardResolver.State.WAITING;

        upkeepNeeded = winnerIsPicked;
        return (upkeepNeeded, "");
    }

    /**
     * @dev This is the function that Chainlink nodes will call to reward the picked top tokens that bonded. Each token's pool receives a portion of the total rewards. This is calculated as basePercent + additivePercent * multiplier. The multiplier is determined by the place in reverse order (if top 3 - 3th place has multiplier 1, 2nd place has multiplier 2, 1st place has multiplier 3).
     */
    function performUpkeep(
        bytes calldata /* performData */
    ) external nonReentrant {
        (bool upkeepNeeded, ) = checkUpkeep("");
        IWETH9 weth = liquidityMigrator.getWeth();
        weth.withdraw(
            weth.balanceOf(address(this)) - totalAccummulatedWethAmounts
        );
        if (!upkeepNeeded) {
            revert FeeAccount__UpkeepNotNeeded(rewardResolver.getState());
        }
        if (address(this).balance == 0) {
            rewardResolver.setStateOpen();
            return;
        }

        rewardResolver.setStateOpen();

        address[] memory winners = rewardResolver.getWinners();
        uint256 startBalance = address(this).balance;

        for (uint8 i = 0; i < winners.length; i++) {
            address winner = winners[i];
            if (winner == address(0)) continue;
            _rewardWinner(competingTokens[winner], i, winner);
        }
        if (startBalance == address(this).balance) {
            return;
        }

        (bool success, ) = treasury.call{value: address(this).balance}("");
        if (!success) {
            revert FeeAccount__TransferFailed();
        }
    }

    function _rewardWinner(
        TokenRefferences storage winnerTokenData,
        uint8 multiplier,
        address winner
    ) internal {
        IWETH9 weth = liquidityMigrator.getWeth();
        uint256 amountInEth;
        uint256 amountInTotal;
        // avoid stack too deep errors
        {
            uint256 wethBalance = weth.balanceOf(address(this));
            uint256 ethBalance = address(this).balance;

            uint256 percent = basePercent + additivePercent * multiplier;
            amountInEth = (ethBalance * percent) / SCALE;
            uint256 amountInWeth = (wethBalance * percent) / SCALE;
            amountInTotal = amountInEth + amountInWeth;
        }
        if (amountInTotal == 0) {
            return;
        }

        ISwapRouter swapRouterInstance = ISwapRouter(swapRouter);

        (, int24 tick, , , , ) = winnerTokenData.pool.slot0();
        uint256 quoteAmount = OracleLibrary.getQuoteAtTick(
            tick,
            uint128(amountInEth),
            address(weth),
            address(winnerTokenData.otherToken)
        );
        uint256 amountOutMinimum = (quoteAmount * slippage) / SCALE;

        weth.deposit{value: amountInEth}();
        weth.approve(address(swapRouterInstance), amountInTotal);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: winner,
                tickSpacing: winnerTokenData.pool.tickSpacing(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountInTotal,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            });

        swapRouterInstance.exactInputSingle(params);

        uint256 balance = winnerTokenData.instance.balanceOf(address(this));
        if (balance > 0) {
            winnerTokenData.instance.burn(balance);
        }

        emit Rewarded(
            address(winnerTokenData.pool),
            address(winnerTokenData.instance),
            amountInTotal,
            block.timestamp
        );
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
