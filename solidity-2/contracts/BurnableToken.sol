//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {ERC20BurnableUpgradeable, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAddressChecker} from "src/interfaces/IAddressChecker.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ILockManager} from "src/interfaces/ILockManager.sol";
import {IBurnableTokenContext} from "src/interfaces/IBurnableTokenContext.sol";
import {IDividendToken} from "src/interfaces/IDividendToken.sol";
import {IBurnableTokenActions} from "src/interfaces/IBurnableTokenActions.sol";
import {IFeeAccount} from "src/interfaces/IFeeAccount.sol";
import {VestingCalculator} from "src/libraries/VestingCalculator.sol";
import {StringValidator} from "src/libraries/StringValidator.sol";

contract BurnableToken is
    Initializable,
    IBurnableTokenContext,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard,
    IDividendToken,
    IBurnableTokenActions
{
    struct Vesting {
        uint256 unlockTimePreMigration;
        uint256 unlockTimePostMigration;
        uint256 amount;
        uint256 lockedAmount;
    }

    using StringValidator for string;

    IAddressChecker public s_addressChecker;
    bool public s_isDevLocked;
    bool public isLaunched;
    bool public isMigrated;
    uint256 public migrationTimestamp;
    address public dev;
    address public feeAccount;
    ILockManager public lockManager;
    mapping(address holder => Vesting unlockTimes) public holdersVesting;
    mapping(address => bool) public whitelistedVesting;
    // the maximum amount of tokens that can be bought from the bonding curve
    uint256 public constant SCALE = 1e18;
    uint256 public totalVestedSupply;
    uint256 public constant MIN_VESTING_PERIOD = 1 days;
    uint256 public constant MAX_VESTING_PERIOD = 365 days;
    uint256 public constant MAX_NAME_LENGTH = 30;
    uint256 public constant MAX_SYMBOL_LENGTH = 10;
    bytes public metadata;
    // With `magnitude`, we can properly distribute dividends even if the amount of received ether is small.
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint256 private magnifiedDividendPerShare;
    address private lockManagerImpl;
    address private lockPositionsNFTImpl;

    // About dividendCorrection:
    // If the token balance of a `_user` is never changed, the dividend of `_user` can be computed with:
    //   `withdrawableDividendOf(_user) = dividendPerShare * balanceOf(_user)`.
    // When `balanceOf(_user)` is changed (via minting/burning/transferring tokens),
    //   `withdrawableDividendOf(_user)` should not be changed,
    //   but the computed value of `dividendPerShare * balanceOf(_user)` is changed.
    // To keep the `withdrawableDividendOf(_user)` unchanged, we add a correction term:
    //   `withdrawableDividendOf(_user) = dividendPerShare * balanceOf(_user) + dividendCorrectionOf(_user)`,
    //   where `dividendCorrectionOf(_user)` is updated whenever `balanceOf(_user)` is changed:
    //   `dividendCorrectionOf(_user) = dividendPerShare * (old balanceOf(_user)) - (new balanceOf(_user))`.
    // So now `withdrawableDividendOf(_user)` returns the same value before and after `balanceOf(_user)` is changed.
    mapping(address => int256) private magnifiedDividendCorrections;
    mapping(address => uint256) private withdrawnDividends;
    // uint256 public supplyExcludingDev;

    modifier launched() {
        if (!isLaunched) {
            revert BurnableToken__NotLaunched();
        }
        _;
    }
    modifier launchedOrOwner() {
        if (!isLaunched && _msgSender() != owner()) {
            revert BurnableToken__NotOwnerOrLaunched(_msgSender());
        }
        _;
    }
    modifier devLock(address from) {
        if (from == dev && !isLaunched && s_isDevLocked) {
            revert BurnableToken__DevIsLocked();
        }
        _;
    }
    modifier vested(
        address from,
        address to,
        uint256 amount
    ) {
        Vesting memory vesting = holdersVesting[from];

        if (!isLaunched && vesting.unlockTimePreMigration > block.timestamp) {
            revert BurnableToken__TransfersLocked(
                vesting.unlockTimePreMigration
            );
        }
        if (!isMigrated) {
            _;
            return;
        }
        if (vesting.amount > 0 && vesting.unlockTimePostMigration == 0) {
            (uint256 unlockTime, ) = calculateHolderVestingPostMigration(from);
            vesting.unlockTimePostMigration = unlockTime;
            holdersVesting[from].unlockTimePostMigration = vesting
                .unlockTimePostMigration;
        }
        _checkVestedAmount(from, to, amount, vesting.unlockTimePostMigration);
        _;
    }
    modifier launchedOrOwnerTransfer(address from, address to) {
        if (isLaunched) {
            _;
            return;
        }
        if (from == owner() || to == owner()) {
            _;
            return;
        }
        IAddressChecker addressChecker = s_addressChecker;
        if (addressChecker.isDex(from) || addressChecker.isDex(to)) {
            revert BurnableToken__NotOwnerOrLaunched(_msgSender());
        }
        _;
    }
    modifier onlyDev() {
        if (msg.sender != dev) {
            revert BurnableToken__NotDev();
        }
        _;
    }
    modifier onlyLockManager() {
        address lockManagerAddress = address(lockManager);

        if (
            lockManagerAddress == address(0) || msg.sender != lockManagerAddress
        ) {
            revert BurnableToken__NotLockManager();
        }
        _;
    }
    modifier preTransfer(
        address from,
        address to,
        uint256 amount
    ) {
        _beforeTokenTransfer(from, to, amount);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        bytes memory _metadata,
        address addressChecker,
        bool _isDevLocked,
        address _dev,
        address _feeAccount,
        address _lockManagerImpl,
        address _lockPositionsNFTImpl
    ) public initializer {
        if (addressChecker == address(0)) {
            revert BurnableToken__ZeroAddressChecker();
        }
        if (
            !_name.isValidString(true) || !_name.isValidLength(MAX_NAME_LENGTH)
        ) {
            revert BurnableToken__InvalidName();
        }
        if (
            !_symbol.isValidString(false) ||
            !_symbol.isValidLength(MAX_SYMBOL_LENGTH)
        ) {
            revert BurnableToken__InvalidSymbol();
        }

        __Ownable_init(msg.sender);
        __ERC20_init(_name, _symbol);
        __ERC20Burnable_init();
        _mint(_msgSender(), 1e9 ether);
        metadata = _metadata;
        s_addressChecker = IAddressChecker(addressChecker);
        s_isDevLocked = _isDevLocked;
        dev = _dev;
        feeAccount = _feeAccount;
        lockManagerImpl = _lockManagerImpl;
        lockPositionsNFTImpl = _lockPositionsNFTImpl;
        isLaunched = false;
        isMigrated = false;
    }

    /**
     * @notice Fallback function to receive ether and distribute dividends.
     * @dev This function allows the contract to receive ether and automatically
     * distributes dividends to token holders.
     */
    receive() external payable {
        distributeDividends();
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function burn(
        uint256 amount
    )
        public
        override(ERC20BurnableUpgradeable, IBurnableTokenActions)
        launchedOrOwner
    {
        address sender = _msgSender();
        uint256 balance = balanceOf(sender);

        if (amount <= 0) {
            revert BurnableToken__MustBeMoreThanZero();
        } else if (amount > balance) {
            revert BurnableToken__BurnAmountExceedsBalance();
        }

        magnifiedDividendCorrections[msg.sender] += _toInt256Safe(
            magnifiedDividendPerShare * amount
        );
        uint256 holdersVestingAmount = holdersVesting[msg.sender].amount;
        if (holdersVestingAmount > 0) {
            holdersVesting[msg.sender].amount -= amount > holdersVestingAmount
                ? holdersVestingAmount
                : amount;
        }

        super.burn(amount);
    }

    /**
     * @notice Transfers tokens from the caller to a specified address.
     * @notice Prior to the transfer the accumulated dividends are distributed to the caller.
     * @dev This function overrides the transfer function of the ERC20 standard.
     * It includes checks for vesting, launch status, and developer lock.
     * @param to The address to which tokens are transferred.
     * @param value The amount of tokens to transfer.
     * @return A boolean indicating whether the transfer was successful.
     */
    function transfer(
        address to,
        uint256 value
    )
        public
        override(IERC20, ERC20Upgradeable)
        launchedOrOwnerTransfer(msg.sender, to)
        devLock(msg.sender)
        vested(msg.sender, to, value)
        preTransfer(msg.sender, to, value)
        returns (bool)
    {
        return super.transfer(to, value);
    }

    /**
     * @notice Transfers tokens from 'from' to 'to'. Must be approved by 'from'.
     * @notice Prior to the transfer the accumulated dividends are distributed to the holder ('from').
     * @dev This function overrides the transferFrom function of the ERC20 standard.
     * It includes checks for vesting, launch status, and developer lock.
     * @param from The address from which tokens are transferred.
     * @param to The address to which tokens are transferred.
     * @param value The amount of tokens to transfer.
     * @return A boolean indicating whether the transfer was successful.
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    )
        public
        override(IERC20, ERC20Upgradeable)
        launchedOrOwnerTransfer(from, to)
        devLock(from)
        vested(from, to, value)
        preTransfer(from, to, value)
        returns (bool)
    {
        return super.transferFrom(from, to, value);
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function extendLockDuration(
        address _holder,
        uint256 _newUnlockTime
    ) external onlyOwner {
        if (holdersVesting[_holder].unlockTimePreMigration >= _newUnlockTime) {
            return;
        }

        holdersVesting[_holder].unlockTimePreMigration = _newUnlockTime;

        emit TransfersLockExtended(_holder, _newUnlockTime);
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function addLockedAmount(
        address holder,
        uint256 amount
    ) external launched onlyLockManager {
        holdersVesting[holder].lockedAmount += amount;
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function setLaunched() external onlyOwner {
        isLaunched = true;
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function setMigrated(uint256 liquidityAmount) external onlyOwner {
        uint256 _migrationTimestamp = migrationTimestamp;
        if (_migrationTimestamp == 0) {
            _migrationTimestamp += isLaunched ? block.timestamp : 0;
            migrationTimestamp = _migrationTimestamp;
        }
        totalVestedSupply = totalSupply() - liquidityAmount;

        isMigrated = _migrationTimestamp > 0;
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function renounceOwnership()
        public
        override(OwnableUpgradeable, IBurnableTokenActions)
        onlyOwner
    {
        super.renounceOwnership();
    }

    // /**
    //  * @inheritdoc IBurnableTokenActions
    //  */
    // function owner()
    //     public
    //     view
    //     override(OwnableUpgradeable, IBurnableTokenActions)
    //     returns (address)
    // {
    //     OwnableUpgradeable.owner();
    // }

    /**
     * @notice Changes the address of the developer(creator) for the token.
     * @notice The new address can be set to the zero address, which effectively removes the developer.
     * @dev This function can only be called by the current developer and after the token has been launched.
     * @param _dev The address of the new developer(creator).
     */
    function setDev(address _dev) external onlyDev launched {
        dev = _dev;
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function calculateHolderVestingPostMigration(
        address holder
    ) public view returns (uint256 unlockTime, uint256 amount) {
        unlockTime = migrationTimestamp + _calculateVestingDuration(holder);
        amount = holdersVesting[holder].amount;

        return (unlockTime, amount);
    }

    /**
     * @notice Distributes dividends to all token holders.
     * @dev This function can be called by anyone to distribute dividends.
     */
    function distributeDividends() public payable launched {
        if (msg.value == 0) {
            return;
        }

        magnifiedDividendPerShare += (msg.value * MAGNITUDE) / totalSupply();
        emit DividendsDistributed(msg.sender, msg.value);
    }

    /**
     * @inheritdoc IDividendToken
     */
    function withdrawDividend() external {
        _withdrawDividend(_msgSender());
    }

    /**
     * @inheritdoc IBurnableTokenActions
     */
    function lock(
        uint256 amount,
        uint256 durationInDays
    ) external override launched returns (uint256 tokenId) {
        ILockManager _lockManager = lockManager;
        bool isBoosted;
        if (address(_lockManager) == address(0)) {
            address lockManagerClone = Clones.clone(lockManagerImpl);

            _lockManager = ILockManager(lockManagerClone);
            _lockManager.initialize(
                address(this),
                feeAccount,
                lockPositionsNFTImpl
            );

            lockManager = _lockManager;
            uint256 balance = this.balanceOf(address(this));
            if (balance > 0) {
                this.approve(address(_lockManager), balance);
                _lockManager.distributeRewards(balance);
            }
            isBoosted = true;
            whitelistedVesting[address(_lockManager)] = true;
            IFeeAccount(feeAccount).emitNewLockManagerAndNFT(
                address(_lockManager),
                address(_lockManager.positionsNFT())
            );
        }

        whitelistedVesting[address(this)] = true;
        this.transferFrom(msg.sender, address(this), amount);
        whitelistedVesting[address(this)] = false;
        this.approve(address(_lockManager), amount);

        return
            _lockManager.lockFor(msg.sender, amount, durationInDays, isBoosted);
    }

    /**
     * @inheritdoc IDividendToken
     */
    function withdrawableDividendOf(
        address _owner
    ) public view returns (uint256) {
        return accumulativeDividendOf(_owner) - (withdrawnDividends[_owner]);
    }

    /**
     * @inheritdoc IDividendToken
     */
    function withdrawnDividendOf(
        address _owner
    ) external view returns (uint256) {
        return withdrawnDividends[_owner];
    }

    /**
     * @inheritdoc IDividendToken
     */
    function accumulativeDividendOf(
        address _owner
    ) public view returns (uint256) {
        return
            _toUint256Safe(
                _toInt256Safe(magnifiedDividendPerShare * balanceOf(_owner)) +
                    magnifiedDividendCorrections[_owner]
            ) / MAGNITUDE;
    }

    function getVestedAmount(address _holder) public view returns (uint256) {
        Vesting memory vesting = holdersVesting[_holder];

        return
            balanceOf(_holder) -
            (
                vesting.unlockTimePostMigration > block.timestamp
                    ? (vesting.amount - vesting.lockedAmount)
                    : 0
            );
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) private {
        if (!isMigrated) {
            _trackVestingPreMigration(from, to, amount);
            return;
        }

        _withdrawDividend(from);
        int256 _magCorrection = _toInt256Safe(
            magnifiedDividendPerShare * amount
        );
        magnifiedDividendCorrections[from] += _magCorrection;
        magnifiedDividendCorrections[to] -= _magCorrection;
    }

    function _withdrawDividend(address _owner) private nonReentrant {
        uint256 _withdrawableDividend = withdrawableDividendOf(_owner);
        if (_withdrawableDividend == 0) {
            return;
        }

        withdrawnDividends[_owner] += _withdrawableDividend;
        bool success = false;
        if (_owner != feeAccount) {
            (success, ) = payable(_owner).call{value: _withdrawableDividend}(
                ""
            );
        }

        if (!success) {
            magnifiedDividendPerShare +=
                (_withdrawableDividend * MAGNITUDE) /
                totalSupply();
            withdrawnDividends[_owner] = accumulativeDividendOf(_owner);
        } else {
            emit DividendWithdrawn(_owner, _withdrawableDividend);
        }
    }

    function _toUint256Safe(int256 a) private pure returns (uint256) {
        require(a >= 0, "Negative value cannot be converted to uint256");
        return uint256(a);
    }

    function _toInt256Safe(uint256 a) private pure returns (int256) {
        int256 b = int256(a);
        require(b >= 0, "Value is too large to fit in int256");
        return b;
    }

    function _trackVestingPreMigration(
        address from,
        address to,
        uint256 amount
    ) private {
        if (isLaunched) {
            return;
        }

        if (from != owner()) {
            holdersVesting[from].amount -= amount;
        }
        if (to != owner()) {
            holdersVesting[to].amount += amount;
        }
    }

    function _calculateVestingDuration(
        address _holder
    ) private view returns (uint256) {
        return
            VestingCalculator.calculateVestingDuration(
                holdersVesting[_holder].amount,
                totalVestedSupply
            );
    }

    function _checkVestedAmount(
        address from,
        address to,
        uint256 amount,
        uint256 vestingUnlockTime
    ) private view {
        uint256 vestedAmount = getVestedAmount(from);

        if (
            vestedAmount < amount &&
            !whitelistedVesting[from] &&
            !whitelistedVesting[to]
        ) {
            revert BurnableToken__UnvestedAmount(
                vestingUnlockTime,
                amount - vestedAmount
            );
        }
    }
}
