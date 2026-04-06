// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FactoryManager} from "src/FactoryManager.sol";
import {IBondingCurvesStorage} from "src/interfaces/IBondingCurvesStorage.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BondingCurvesStorage is
    ReentrancyGuard,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IBondingCurvesStorage
{
    uint16 private constant PRECISION = 1000;
    address private s_addressChecker;
    address private s_liquidityMigrator;
    uint16 public feePercent;
    mapping(address curve => bool exists) public bondingCurves;
    mapping(address curve => uint256 timestamp) public crownedCasts;
    mapping(address dev => uint256 reward) public devRewards;
    address public lastKingOfTheCasts;
    address public currentKingOfTheCasts;
    address[] public kingsOfTheCasts;
    address[] public basedNFTs;
    FactoryManager public factoryManager;
    address public bondingCurveImplementation;
    address public burnableTokenImplementation;
    address public lockManagerImplementation;
    address public lockPositionsNFTImplementation;

    // Gap for future storage variables. If you add new variables, decrease the size of the gap.
    uint256[100] private __gap;

    modifier onlyCurve() {
        if (!bondingCurves[msg.sender]) {
            revert BondingCurvesStorage__NotBondingCurve();
        }
        _;
    }
    modifier onlyFactory() {
        if (factoryManager.getBondingCurveFactory() != msg.sender) {
            revert BondingCurvesStorage__NotBondingCurveFactory();
        }
        _;
    }
    modifier nonZeroAddress(address addressToCheck) {
        if (addressToCheck == address(0)) {
            revert BondingCurvesStorage__ZeroAddress();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with the liquidity migrator and address checker.
     * @param _liquidityMigrator The address of the liquidity migrator contract.
     * @param _addressChecker The address of the AddressChecker contract.
     */
    function initialize(
        address _liquidityMigrator,
        address _addressChecker,
        address _bondingCurveImpl,
        address _burnableTokenImpl,
        address _lockManagerImpl,
        address _lockPositionsNFTImpl
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        s_liquidityMigrator = _liquidityMigrator;
        feePercent = 10;
        s_addressChecker = _addressChecker;
        bondingCurveImplementation = _bondingCurveImpl;
        burnableTokenImplementation = _burnableTokenImpl;
        lockManagerImplementation = _lockManagerImpl;
        lockPositionsNFTImplementation = _lockPositionsNFTImpl;
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function addBasedNFT(address nft) external onlyOwner nonZeroAddress(nft) {
        basedNFTs.push(nft);
    }

    function setBondingCurveImplementation(
        address _bondingCurveImpl
    ) external onlyOwner nonZeroAddress(_bondingCurveImpl) {
        bondingCurveImplementation = _bondingCurveImpl;
    }

    function setBurnableTokenImplementation(
        address _burnableTokenImpl
    ) external onlyOwner nonZeroAddress(_burnableTokenImpl) {
        burnableTokenImplementation = _burnableTokenImpl;
    }

    function setLockManagerImplementation(
        address _lockManagerImpl
    ) external onlyOwner nonZeroAddress(_lockManagerImpl) {
        lockManagerImplementation = _lockManagerImpl;
    }

    function setLockPositionsNFTImplementation(
        address _lockPositionsNFTImpl
    ) external onlyOwner nonZeroAddress(_lockPositionsNFTImpl) {
        lockPositionsNFTImplementation = _lockPositionsNFTImpl;
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function receiveDevReward(address dev) external payable {
        if (msg.value == 0) {
            return;
        }
        devRewards[dev] += msg.value;
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function withdrawDevRewards() external nonReentrant {
        uint256 reward = devRewards[msg.sender];
        devRewards[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: reward}("");
        if (!success) {
            revert BondingCurvesStorage__WithdrawalFailed();
        }

        emit DevRewardsWithdrawn(msg.sender, reward);
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function emitBuy(
        address token,
        address sender,
        uint256 amount,
        uint256 deposit,
        string memory id,
        uint256 unlockTime
    ) external onlyCurve {
        emit Buy(token, sender, amount, deposit, id, unlockTime);
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function emitSell(
        address token,
        address sender,
        uint256 amount,
        uint256 reimbursement,
        string memory id
    ) external onlyCurve {
        emit Sell(token, sender, amount, reimbursement, id);
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function emitNewBondingCurveCreated(
        address curve,
        address token,
        address creator,
        string memory name,
        string memory symbol,
        bool isDevLocked,
        string memory id,
        bytes memory metadata
    ) external onlyFactory {
        emit NewBondingCurveCreated(
            curve,
            token,
            creator,
            name,
            symbol,
            isDevLocked,
            id,
            metadata
        );
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function addBondingCurve(address bondingCurve) external onlyFactory {
        bondingCurves[bondingCurve] = true;
    }

    function setFeePercent(uint16 newFeePercent) external onlyOwner {
        if (newFeePercent >= PRECISION || newFeePercent <= 0) {
            revert BondingCurvesStorage__InvalidFeePercent();
        }

        feePercent = newFeePercent;
        emit FeePercentUpdated(feePercent);
    }

    function setAddressChecker(
        address _addressChecker
    ) external onlyOwner nonZeroAddress(_addressChecker) {
        s_addressChecker = _addressChecker;
    }

    function setFactoryManager(
        address _factoryManager
    ) external onlyOwner nonZeroAddress(_factoryManager) {
        factoryManager = FactoryManager(_factoryManager);
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function getAddressChecker() external view returns (address) {
        return s_addressChecker;
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function liquidityMigrator() external view returns (address) {
        return s_liquidityMigrator;
    }

    function setLiquidityMigrator(
        address _liquidityMigrator
    ) external onlyOwner nonZeroAddress(_liquidityMigrator) {
        s_liquidityMigrator = _liquidityMigrator;
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function updateKingOfTheCasts(
        address newKingOfTheCasts,
        bool isCrowned
    ) external onlyCurve {
        lastKingOfTheCasts = currentKingOfTheCasts;
        currentKingOfTheCasts = newKingOfTheCasts;

        if (!isCrowned) {
            crownedCasts[newKingOfTheCasts] = block.timestamp;
            kingsOfTheCasts.push(newKingOfTheCasts);
        }

        emit NewKingOfTheCasts(newKingOfTheCasts);
    }

    /**
     * @inheritdoc IBondingCurvesStorage
     */
    function removeLastKingOfTheCasts() external onlyCurve {
        uint256 length = kingsOfTheCasts.length;
        if (length <= 1) {
            lastKingOfTheCasts = address(0);
            return;
        }

        kingsOfTheCasts[length - 2] = kingsOfTheCasts[length - 1];
        kingsOfTheCasts.pop();
        length--;
        if (length == 1) {
            lastKingOfTheCasts = address(0);
            return;
        }
        lastKingOfTheCasts = kingsOfTheCasts[length - 2];
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
