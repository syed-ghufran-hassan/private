//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILockPositionsNFT} from "src/interfaces/ILockPositionsNFT.sol";
import {ILockManager} from "src/interfaces/ILockManager.sol";
import {IDividendToken} from "src/interfaces/IDividendToken.sol";
import {IBurnableTokenActions} from "src/interfaces/IBurnableTokenActions.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @dev The LockManager contract allows users to lock tokens for a specified duration,
 * earning rewards and dividends based on the amount locked and the duration.
 */
contract LockManager is
    Initializable,
    OwnableUpgradeable,
    ILockManager,
    ReentrancyGuard
{
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint256 private magnifiedRewardPerShare;
    uint256 private magnifiedDividendsPerShare;
    string private constant NAME_PREFIX = "Locked ";
    string private constant SYMBOL_PREFIX = "L";
    uint256 private constant MAX_LOCK_DURATION = 365 days;
    uint256 private constant MAX_LOCK_BOOST = 30;
    uint256 private constant INITIALIZATION_LOCK_BOOST = 5;
    uint256 private constant SCALE = 100;
    uint256 public totalLockShares;
    ILockPositionsNFT public positionsNFT;
    address public feeAccount;
    mapping(uint256 tokenId => uint256) internal collectedRewards;
    mapping(uint256 tokenId => uint256) internal collectedDividends;

    IDividendToken public dividendToken;

    modifier positive(uint256 amount) {
        if (amount == 0) {
            revert LockManager__MustBeMoreThanZero();
        }
        _;
    }
    modifier ownerOf(uint256 tokenId) {
        if (msg.sender != positionsNFT.ownerOf(tokenId)) {
            revert LockManager__NotOwner(tokenId);
        }
        _;
    }
    modifier onlyToken() {
        if (msg.sender != address(dividendToken)) {
            revert LockManager__NotAuthorized();
        }
        _;
    }
    modifier onlyFeeAccount() {
        if (msg.sender != feeAccount) {
            revert LockManager__NotFeeAccount();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @inheritdoc ILockManager
     */
    function initialize(
        address _dividendToken,
        address _feeAccount,
        address _lockPositionsNFTImpl
    ) public initializer {
        __Ownable_init(msg.sender);
        dividendToken = IDividendToken(_dividendToken);
        feeAccount = _feeAccount;
        address lockPositionsNFTClone = Clones.clone(_lockPositionsNFTImpl);
        ILockPositionsNFT(lockPositionsNFTClone).initialize(
            string.concat(NAME_PREFIX, IDividendToken(_dividendToken).name()),
            string.concat(
                SYMBOL_PREFIX,
                IDividendToken(_dividendToken).symbol()
            ),
            _dividendToken
        );
        positionsNFT = ILockPositionsNFT(lockPositionsNFTClone);
    }

    /**
     * @notice Fallback function to receive Ether and distribute dividends.
     * This function is called when Ether is sent to the contract.
     */
    receive() external payable {
        distributeDividends();
    }

    /**
     * @inheritdoc ILockManager
     */
    function lock(
        uint256 amount,
        uint256 durationInDays
    )
        external
        override
        positive(amount)
        positive(durationInDays)
        returns (uint256 tokenId)
    {
        return _lock(msg.sender, msg.sender, amount, durationInDays, false);
    }

    /**
     * @notice Locks the selected position and mints a LockPositionsNFT representing the lock, to the specified lockOwner.
     * @dev This function can be called only by the locked token contract.
     *
     * @param lockOwner The address that will own the locked position.
     * @param amount Amount of tokens to lock. Must be greater than 0 and pre-approved to transfer.
     * @param durationInDays Duration of the lock in days. Caps at 365 days. Must be greater than 0.
     * @param isBoosted Whether the lock is boosted with an initial boost.
     * @return tokenId - The tokenId of the minted position NFT.
     */
    function lockFor(
        address lockOwner,
        uint256 amount,
        uint256 durationInDays,
        bool isBoosted
    )
        external
        positive(amount)
        positive(durationInDays)
        onlyToken
        returns (uint256 tokenId)
    {
        return _lock(msg.sender, lockOwner, amount, durationInDays, isBoosted);
    }

    /**
     * @inheritdoc ILockManager
     */
    function redistributeRewards(
        uint256 tokenId
    ) external onlyFeeAccount ownerOf(tokenId) {
        (uint256 amount, uint256 lockShares, , ) = positionsNFT.positions(
            tokenId
        );

        positionsNFT.burn(tokenId);
        totalLockShares -= lockShares;
        magnifiedRewardPerShare += (amount * MAGNITUDE) / (totalLockShares);
    }

    /**
     * @inheritdoc ILockManager
     */
    function distributeDividends() public payable {
        if (msg.value == 0) {
            return;
        }

        magnifiedDividendsPerShare += (msg.value * MAGNITUDE) / totalLockShares;
        emit DividendsDistributed(msg.sender, msg.value);
    }

    /**
     * @inheritdoc ILockManager
     */ function distributeRewards(
        uint256 amount
    ) external override positive(amount) {
        bool success = dividendToken.transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert LockManager__FailedToDistributeRewards();
        }

        magnifiedRewardPerShare += (amount * MAGNITUDE) / (totalLockShares);
        emit RewardsDistributed(amount);
    }

    /**
     * @inheritdoc ILockManager
     */
    function claimRewards(uint256 tokenId) external override ownerOf(tokenId) {
        (
            uint256 amount,
            uint256 lockShares,
            uint256 unlockTime,

        ) = positionsNFT.positions(tokenId);
        if (block.timestamp < unlockTime) {
            revert LockManager__PoisitionNotUnlocked();
        }

        collectRewards(tokenId);
        collectDividends(tokenId); // has nonReentrant modifier
        uint256 totalReward = collectedRewards[tokenId] + amount;
        positionsNFT.burn(tokenId);
        totalLockShares -= lockShares;
        collectedRewards[tokenId] = 0;

        dividendToken.transfer(msg.sender, totalReward);

        emit LockClaimed(msg.sender, totalReward);
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectRewardsAndDividends(uint256 tokenId) external {
        collectRewards(tokenId);
        collectDividends(tokenId);
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectRewards(uint256 tokenId) public override ownerOf(tokenId) {
        collectedRewards[tokenId] += collectableRewardOf(tokenId);
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectableRewardOf(
        uint256 tokenId
    ) public view override returns (uint256) {
        return accumulativeRewardOf(tokenId) - (collectedRewards[tokenId]);
    }

    /**
     * @inheritdoc ILockManager
     */
    function accumulativeRewardOf(
        uint256 tokenId
    ) public view override returns (uint256) {
        (, uint256 lockShares, , ) = positionsNFT.positions(tokenId);
        return (magnifiedRewardPerShare * lockShares) / MAGNITUDE;
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectedRewardOf(
        uint256 tokenId
    ) external view override returns (uint256) {
        return collectedRewards[tokenId];
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectDividends(
        uint256 tokenId
    ) public nonReentrant ownerOf(tokenId) {
        dividendToken.withdrawDividend();
        uint256 _withdrawableDividend = collectableDividendOf(tokenId);
        if (_withdrawableDividend == 0) {
            return;
        }

        collectedDividends[tokenId] += _withdrawableDividend;
        (bool success, ) = payable(msg.sender).call{
            value: _withdrawableDividend
        }("");

        if (!success) {
            magnifiedDividendsPerShare +=
                (_withdrawableDividend * MAGNITUDE) /
                totalLockShares;
            collectedDividends[tokenId] = accumulativeDividendOf(tokenId);
        } else {
            emit DividendWithdrawn(msg.sender, _withdrawableDividend);
        }
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectableDividendOf(
        uint256 tokenId
    ) public view returns (uint256) {
        return accumulativeDividendOf(tokenId) - (collectedDividends[tokenId]);
    }

    /**
     * @inheritdoc ILockManager
     */
    function collectedDividendOf(
        uint256 tokenId
    ) external view ownerOf(tokenId) returns (uint256) {
        return collectedDividends[tokenId];
    }

    /**
     * @inheritdoc ILockManager
     */
    function accumulativeDividendOf(
        uint256 tokenId
    ) public view returns (uint256) {
        (, uint256 lockShares, , ) = positionsNFT.positions(tokenId);
        return (magnifiedDividendsPerShare * lockShares) / MAGNITUDE;
    }

    function _lock(
        address from,
        address lockOwner,
        uint256 amount,
        uint256 durationInDays,
        bool isBoosted
    ) private returns (uint256 tokenId) {
        durationInDays *= 1 days;
        if (durationInDays > MAX_LOCK_DURATION) {
            durationInDays = MAX_LOCK_DURATION;
        }
        _checkVestingLockDurataion(durationInDays, lockOwner, amount);

        dividendToken.transferFrom(from, address(this), amount);
        uint256 lockShares = amount +
            (amount * durationInDays * MAX_LOCK_BOOST) /
            (MAX_LOCK_DURATION * SCALE);
        if (isBoosted) {
            lockShares += (amount * INITIALIZATION_LOCK_BOOST) / SCALE;
        }

        totalLockShares += lockShares;

        return
            positionsNFT.mint(
                lockOwner,
                ILockPositionsNFT.Position(
                    amount,
                    lockShares,
                    block.timestamp + durationInDays,
                    block.timestamp
                )
            );
    }

    function _checkVestingLockDurataion(
        uint256 durationInDays,
        address lockOwner,
        uint256 amountToLock
    ) private {
        IBurnableTokenActions token = IBurnableTokenActions(
            address(dividendToken)
        );
        (
            ,
            uint256 unlockTimePostMigration,
            uint256 vestingAmount,
            uint256 lockedVestingAmount
        ) = token.holdersVesting(lockOwner);

        if (
            block.timestamp > unlockTimePostMigration ||
            vestingAmount == lockedVestingAmount
        ) {
            return;
        }
        uint256 unvestedAmount = vestingAmount - lockedVestingAmount;
        if (unvestedAmount > amountToLock) {
            unvestedAmount = amountToLock;
        }
        if (durationInDays + block.timestamp >= unlockTimePostMigration) {
            token.addLockedAmount(lockOwner, unvestedAmount);
            return;
        }

        uint256 minLockDuration = unlockTimePostMigration - block.timestamp;
        if (minLockDuration % 1 days > 0) {
            minLockDuration += 1 days;
        }

        revert ILockManager.LockManager__LockDurationUnderMinForUnvestedAmount(
            unvestedAmount,
            minLockDuration
        );
    }
}
