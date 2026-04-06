// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IBurnableTokenActions} from "src/interfaces/IBurnableTokenActions.sol";
import {IBondingCurveFactory} from "src/interfaces/IBondingCurveFactory.sol";
import {IBondingCurvesStorage} from "src/interfaces/IBondingCurvesStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BancorBondingCurve} from "src/BancorBondingCurve.sol";
import {LiquidityMigrator} from "src/LiquidityMigrator.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StringValidator} from "src/libraries/StringValidator.sol";

contract BondingCurve is
    Initializable,
    OwnableUpgradeable,
    BancorBondingCurve,
    ReentrancyGuard,
    IBondingCurve
{
    using StringValidator for string;

    uint256 private constant PROTECTED_BLOCKS_COUNT = 3;
    uint256 private constant SCALE = 10 ** 18;
    uint256 private constant BONDING_CURVE_GOAL = 4.5 ether;
    uint256 private constant HALF_BONDING_CURVE_GOAL = 2.25 ether;
    // uint256 private constant START_VIRTUAL_LIQUIDITY = 3.21782 ether;
    // uint256 private constant START_VIRTUAL_SUPPLY = 2153288818.00752 ether;
    uint256 private constant START_VIRTUAL_LIQUIDITY = 0.4977908 ether;
    uint256 private constant START_VIRTUAL_SUPPLY = 94955060000 ether;
    uint32 private constant RESERVE_RATIO = 3606;
    uint16 private constant FEE_SCALE = 1000;
    uint16 private s_feePercent;
    IBondingCurvesStorage private s_bondingCurvesStorage;
    IBondingCurveFactory private s_bondingCurveFactory;
    LiquidityMigrator private s_liquidityMigrator;
    uint256 private virtualLiquidity;
    uint256 private virtualTokenSupply;
    uint256 private initializationBlock;
    uint256 public constant DEV_REWARD = 0.03 ether;
    uint256 public constant MIN_LOCK_DURATION = 2 minutes;
    uint256 public constant MAX_LOCK_DURATION = 24 hours;

    // uint256 public virtualLiquidity = 0.49779 ether;
    // uint256 public virtualTokenSupply = 94955e6 ether;

    bool public isOnCurve;
    IBurnableTokenActions public token;
    address public feeAccount;

    // Gap for future storage variables. If you add new variables, decrease the size of the gap.
    uint256[50] private __gap;

    modifier afterBonding() {
        if (isOnCurve) {
            revert BondingCurve__TokenNotBonded();
        }
        _;
    }

    modifier beforeBonding() {
        if (!isOnCurve) {
            revert BondingCurve__TokenAlreadyBonded();
        }
        _;
    }
    modifier sniperProtected() {
        if (block.number < initializationBlock + PROTECTED_BLOCKS_COUNT) {
            revert BondingCurve__Protected();
        }
        _;
    }
    modifier onlyFactory() {
        if (msg.sender != address(s_bondingCurveFactory)) {
            revert BondingCurve__NotBondingCurveFactory();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        buyToken(0, "");
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function initialize(
        string memory name,
        string memory symbol,
        bytes memory _metadata,
        uint16 feePercent,
        address liquidityMigrator,
        address _feeAccount,
        bool _isDevLocked,
        address _dev
    ) public initializer {
        s_feePercent = feePercent;
        s_bondingCurveFactory = IBondingCurveFactory(msg.sender);
        s_bondingCurvesStorage = IBondingCurvesStorage(
            s_bondingCurveFactory.bondingCurvesStorage()
        );
        s_liquidityMigrator = LiquidityMigrator(liquidityMigrator);
        feeAccount = _feeAccount;

        token = IBurnableTokenActions(
            Clones.clone(s_bondingCurvesStorage.burnableTokenImplementation())
        );
        token.initialize(
            name,
            symbol,
            _metadata,
            s_bondingCurvesStorage.getAddressChecker(),
            _isDevLocked,
            _dev,
            _feeAccount,
            s_bondingCurvesStorage.lockManagerImplementation(),
            s_bondingCurvesStorage.lockPositionsNFTImplementation()
        );

        initializationBlock = block.number;
        virtualLiquidity = START_VIRTUAL_LIQUIDITY;
        virtualTokenSupply = START_VIRTUAL_SUPPLY;
        isOnCurve = true;
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function sellToken(
        uint256 amount,
        uint256 minAmount,
        string memory id
    ) external beforeBonding nonReentrant {
        uint256 returnAmount = _continuousSell(amount, minAmount, id);
        _transferEther(msg.sender, returnAmount);
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function buyToken(
        uint256 minAmount,
        string memory id
    ) public payable beforeBonding sniperProtected nonReentrant {
        _buyToken(msg.sender, msg.value, minAmount, id);
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function calculateContinuousBuyReturn(
        uint256 _amount
    ) public view returns (uint256) {
        return
            calculatePurchaseReturn(
                virtualTokenSupply,
                virtualLiquidity,
                RESERVE_RATIO,
                _amount
            );
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function calculateContinuousSellReturn(
        uint256 _amount
    ) public view returns (uint256) {
        return
            calculateSaleReturn(
                virtualTokenSupply,
                virtualLiquidity,
                RESERVE_RATIO,
                _amount
            );
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * s_feePercent) / FEE_SCALE;
    }

    function calculateMaxBuy() public view returns (uint256) {
        uint256 divisor = FEE_SCALE - s_feePercent;
        return (BONDING_CURVE_GOAL * FEE_SCALE) / divisor + 1;
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function buyTokenForDev(
        address dev,
        uint256 minAmount,
        string memory id
    ) external payable onlyFactory nonReentrant {
        _buyToken(dev, msg.value, minAmount, id);
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function getReserveBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function factory() external view returns (address) {
        return address(s_bondingCurveFactory);
    }

    /**
     * @inheritdoc IBondingCurve
     */
    function migrator() external view returns (address) {
        return address(s_liquidityMigrator);
    }

    function _buyToken(
        address recipient,
        uint256 buyAmount,
        uint256 minAmount,
        string memory id
    ) private {
        uint256 startLiquidity = virtualLiquidity - START_VIRTUAL_LIQUIDITY;

        _continuousBuy(recipient, buyAmount, minAmount, id);
        _checkKingOfTheCasts(startLiquidity);
        _checkIsMigrating();
    }

    function _continuousBuy(
        address recipient,
        uint256 _deposit,
        uint256 minAmount,
        string memory id
    ) private returns (uint256) {
        if (_deposit <= 0) {
            revert BondingCurve__AmountMustBePositive();
        }
        id = _checkAndReturnId(id);

        uint256 refundAmount = _checkIsBalanceMoreThanGoal();
        _deposit -= refundAmount;
        _deposit -= _deductFee(recipient, _deposit);

        uint256 amount = calculateContinuousBuyReturn(_deposit);
        if (amount < minAmount) {
            revert BondingCurve__MinimumAmountNotMet();
        }

        uint256 startLiquidity = virtualLiquidity - START_VIRTUAL_LIQUIDITY;
        virtualLiquidity += _deposit;
        virtualTokenSupply += amount;
        int256 diff = int256(_deposit) -
            int256(calculateContinuousSellReturn(amount));

        if (refundAmount > 0) {
            _transferEther(recipient, refundAmount);
        }
        token.transfer(recipient, amount);
        _extendHolderTransfersLock(recipient, startLiquidity);

        (uint256 unlockTime, , , ) = token.holdersVesting(recipient);
        s_bondingCurvesStorage.emitBuy(
            address(token),
            recipient,
            amount,
            _deposit,
            id,
            unlockTime
        );
        emit Buy(recipient, amount, _deposit, id, unlockTime);

        return amount;
    }

    function _continuousSell(
        uint256 deposit,
        uint256 minAmount,
        string memory id
    ) private returns (uint256) {
        if (deposit <= 0) {
            revert BondingCurve__AmountMustBePositive();
        }
        if (token.balanceOf(msg.sender) < deposit) {
            revert BondingCurve__AmountMoreThanBalance();
        }
        id = _checkAndReturnId(id);

        uint256 reimburseAmount = calculateContinuousSellReturn(deposit);
        uint256 fee = _deductFee(msg.sender, reimburseAmount);
        virtualLiquidity -= reimburseAmount;
        virtualTokenSupply -= deposit;
        reimburseAmount -= fee;
        if (reimburseAmount < minAmount) {
            revert BondingCurve__MinimumAmountNotMet();
        }

        token.transferFrom(msg.sender, address(this), deposit);
        s_bondingCurvesStorage.emitSell(
            address(token),
            msg.sender,
            deposit,
            reimburseAmount,
            id
        );
        emit Sell(msg.sender, deposit, reimburseAmount, id);

        return reimburseAmount;
    }

    function _checkIsBalanceMoreThanGoal()
        private
        returns (uint256 refundAmount)
    {
        uint256 totalAmount = address(this).balance;
        uint256 maxBuy = calculateMaxBuy();
        if (totalAmount >= maxBuy) {
            refundAmount = totalAmount - maxBuy >= 0.0001 ether
                ? totalAmount - maxBuy
                : 0;

            isOnCurve = false;
        }

        return refundAmount;
    }

    function _transferEther(address to, uint256 amount) private {
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) {
            revert BondingCurve__TransferFailed();
        }
    }

    function _deductFee(
        address recipient,
        uint256 amount
    ) private returns (uint256) {
        try s_bondingCurvesStorage.basedNFTs(0) returns (address nft) {
            if (IERC721(nft).balanceOf(recipient) > 0) {
                return 0; // no fee for basedNFT holders
            }
        } catch {
            // no basedNFTs
        }
        uint256 feeAmount = calculateFee(amount);
        if (feeAmount <= 0) {
            revert BondingCurve__AmountMustBeMoreThanMin();
        }

        _transferEther(feeAccount, feeAmount);
        return feeAmount;
    }

    function _checkIsMigrating() private {
        if (isOnCurve) {
            return;
        }

        s_bondingCurvesStorage.receiveDevReward{value: DEV_REWARD}(token.dev());
        uint256 tokensForLiquidity = token.balanceOf(address(this));
        token.setLaunched();

        token.approve(address(s_liquidityMigrator), tokensForLiquidity);
        s_liquidityMigrator.createPoolAndLockLiquidity{
            value: address(this).balance
        }(payable(address(token)), tokensForLiquidity);
        token.setMigrated(tokensForLiquidity);
        token.renounceOwnership();
    }

    function _checkKingOfTheCasts(uint256 startLiquidity) private {
        if (
            startLiquidity < HALF_BONDING_CURVE_GOAL &&
            address(this).balance >= HALF_BONDING_CURVE_GOAL &&
            s_bondingCurvesStorage.crownedCasts(address(this)) == 0
        ) {
            s_bondingCurvesStorage.updateKingOfTheCasts(address(this), false);
        }
        if (
            !isOnCurve &&
            address(this) == s_bondingCurvesStorage.currentKingOfTheCasts()
        ) {
            s_bondingCurvesStorage.updateKingOfTheCasts(
                s_bondingCurvesStorage.lastKingOfTheCasts(),
                true
            );
        }
        if (
            !isOnCurve &&
            address(this) == s_bondingCurvesStorage.lastKingOfTheCasts()
        ) {
            s_bondingCurvesStorage.removeLastKingOfTheCasts();
        }
    }

    function _extendHolderTransfersLock(
        address recipient,
        uint256 balance
    ) private {
        if (!isOnCurve) {
            return;
        }

        uint256 curveProgress = (balance * SCALE) / BONDING_CURVE_GOAL;
        uint256 remainingCurveProgress = SCALE - curveProgress;
        uint256 lockDuration = MIN_LOCK_DURATION +
            ((MAX_LOCK_DURATION - MIN_LOCK_DURATION) * remainingCurveProgress) /
            SCALE;

        token.extendLockDuration(recipient, block.timestamp + lockDuration);
    }

    function _checkAndReturnId(
        string memory id
    ) private pure returns (string memory) {
        if (!id.isValidString(false)) {
            return "";
        }
        return id;
    }
}
