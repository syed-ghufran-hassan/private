// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISubscriptionMNTY is IERC20 {}

/**
 * @title SubscriptionManager
 * @notice Manages MNTY-denominated subscriptions for Montty protocol access
 *
 * AUDIT FIXES APPLIED:
 * - M-02: isActiveSubscriber() now computes real-time status instead of reading stale storage
 * - M-07: Added events for rewards pool transparency
 * - L-01: Added events for all setter functions (setMonthlyPrice, setTreasury, setGracePeriod)
 */
contract SubscriptionManager is Ownable, ReentrancyGuard {
    using SafeERC20 for ISubscriptionMNTY;

    ISubscriptionMNTY public mntyToken;
    address public treasury;
    uint256 public monthlyPrice;
    uint256 public treasurySplitBps;
    uint256 public rewardsPool;
    uint256 public gracePeriod;

    enum SubscriptionStatus {
        INACTIVE,
        ACTIVE,
        GRACE,
        SUSPENDED
    }

    struct Subscription {
        address subscriber;
        uint256 startedAt;
        uint256 paidUntil;
        uint256 totalPaid;
        SubscriptionStatus status;
        uint256 paymentCount;
    }

    mapping(address => Subscription) public subscriptions;
    address[] public allSubscribers;

    error AlreadySubscribed();
    error NotSubscribed();
    error SubscriptionSuspended();
    error InsufficientAllowance();
    error InvalidSplit();
    error InvalidPrice();
    error NothingToWithdraw();
    error ZeroAddress();

    event Subscribed(
        address indexed subscriber,
        uint256 paidUntil,
        uint256 amount,
        uint256 timestamp
    );
    event SubscriptionRenewed(
        address indexed subscriber,
        uint256 newPaidUntil,
        uint256 amount,
        uint256 timestamp
    );
    event SubscriptionStatusChanged(
        address indexed subscriber,
        SubscriptionStatus oldStatus,
        SubscriptionStatus newStatus
    );
    event RewardsWithdrawn(address indexed to, uint256 amount);
    /// @notice L-01 FIX: Events for all admin setter functions
    event MonthlyPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TreasurySplitUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event GracePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    /// @notice M-07 FIX: Events for rewards pool transparency
    event PaymentCollected(address indexed payer, uint256 totalAmount, uint256 treasuryAmount, uint256 rewardsAmount);

    constructor(
        address mntyTokenAddress,
        address treasuryAddress,
        uint256 monthlyPrice_,
        uint256 treasurySplitBps_
    ) Ownable(msg.sender) {
        if (mntyTokenAddress == address(0) || treasuryAddress == address(0))
            revert ZeroAddress();
        if (monthlyPrice_ == 0) revert InvalidPrice();
        _validateSplit(treasurySplitBps_);

        mntyToken = ISubscriptionMNTY(mntyTokenAddress);
        treasury = treasuryAddress;
        monthlyPrice = monthlyPrice_;
        treasurySplitBps = treasurySplitBps_;
        gracePeriod = 7 days;
    }

    function subscribe() external nonReentrant {
        Subscription storage subscription = subscriptions[msg.sender];
        if (
            subscription.status == SubscriptionStatus.ACTIVE ||
            subscription.status == SubscriptionStatus.GRACE
        ) {
            revert AlreadySubscribed();
        }

        uint256 paidUntil = block.timestamp + 30 days;
        bool firstSubscription = subscription.subscriber == address(0);
        _collectPayment(msg.sender, monthlyPrice);

        if (firstSubscription) {
            allSubscribers.push(msg.sender);
        }

        subscriptions[msg.sender] = Subscription({
            subscriber: msg.sender,
            startedAt: block.timestamp,
            paidUntil: paidUntil,
            totalPaid: subscription.totalPaid + monthlyPrice,
            status: SubscriptionStatus.ACTIVE,
            paymentCount: subscription.paymentCount + 1
        });

        emit Subscribed(msg.sender, paidUntil, monthlyPrice, block.timestamp);
    }

    function renewSubscription() external nonReentrant {
        Subscription storage subscription = subscriptions[msg.sender];
        if (subscription.subscriber == address(0)) revert NotSubscribed();
        if (subscription.status == SubscriptionStatus.SUSPENDED)
            revert SubscriptionSuspended();

        _collectPayment(msg.sender, monthlyPrice);

        uint256 baseTime = subscription.paidUntil > block.timestamp
            ? subscription.paidUntil
            : block.timestamp;
        subscription.paidUntil = baseTime + 30 days;
        subscription.totalPaid += monthlyPrice;
        subscription.status = SubscriptionStatus.ACTIVE;
        subscription.paymentCount += 1;

        emit SubscriptionRenewed(
            msg.sender,
            subscription.paidUntil,
            monthlyPrice,
            block.timestamp
        );
    }

    function checkAndUpdateStatus(address subscriber) public {
        Subscription storage subscription = subscriptions[subscriber];
        if (subscription.subscriber == address(0)) revert NotSubscribed();

        SubscriptionStatus oldStatus = subscription.status;
        SubscriptionStatus newStatus;
        if (subscription.paidUntil >= block.timestamp) {
            newStatus = SubscriptionStatus.ACTIVE;
        } else if (subscription.paidUntil + gracePeriod >= block.timestamp) {
            newStatus = SubscriptionStatus.GRACE;
        } else {
            newStatus = SubscriptionStatus.SUSPENDED;
        }

        if (oldStatus != newStatus) {
            subscription.status = newStatus;
            emit SubscriptionStatusChanged(subscriber, oldStatus, newStatus);
        }
    }

    /**
     * @notice Check if a subscriber is active
     * @dev M-02 FIX: Computes status in real-time from paidUntil timestamp instead of
     *      reading stored status which may be stale (not updated since last checkAndUpdateStatus call).
     */
    function isActiveSubscriber(
        address subscriber
    ) external view returns (bool) {
        Subscription memory sub = subscriptions[subscriber];
        if (sub.subscriber == address(0)) return false;

        // M-02 FIX: Real-time computation instead of reading stale stored status
        if (sub.paidUntil >= block.timestamp) return true; // ACTIVE
        if (sub.paidUntil + gracePeriod >= block.timestamp) return true; // GRACE
        return false; // SUSPENDED/EXPIRED
    }

    function withdrawRewardsPool(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > rewardsPool) revert NothingToWithdraw();

        rewardsPool -= amount;
        mntyToken.safeTransfer(to, amount);

        emit RewardsWithdrawn(to, amount);
    }

    /// @dev L-01 FIX: Added event emission
    function setMonthlyPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        uint256 oldPrice = monthlyPrice;
        monthlyPrice = newPrice;
        emit MonthlyPriceUpdated(oldPrice, newPrice);
    }

    /// @dev L-01 FIX: Added event emission
    function setTreasurySplit(uint256 newBps) external onlyOwner {
        _validateSplit(newBps);
        uint256 oldBps = treasurySplitBps;
        treasurySplitBps = newBps;
        emit TreasurySplitUpdated(oldBps, newBps);
    }

    /// @dev L-01 FIX: Added event emission
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /// @dev L-01 FIX: Added event emission
    function setGracePeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < 1 days || newPeriod > 30 days) revert InvalidPrice();
        uint256 oldPeriod = gracePeriod;
        gracePeriod = newPeriod;
        emit GracePeriodUpdated(oldPeriod, newPeriod);
    }

    function getSubscription(
        address subscriber
    ) external view returns (Subscription memory) {
        return subscriptions[subscriber];
    }

    function getAllSubscribers() external view returns (address[] memory) {
        return allSubscribers;
    }

    function getRewardsPool() external view returns (uint256) {
        return rewardsPool;
    }

    /**
     * @dev M-07 FIX: Added PaymentCollected event for full transparency on payment splits
     */
    function _collectPayment(address payer, uint256 amount) internal {
        if (mntyToken.allowance(payer, address(this)) < amount)
            revert InsufficientAllowance();

        uint256 treasuryAmount = (amount * treasurySplitBps) / 10_000;
        uint256 rewardsAmount = amount - treasuryAmount;
        rewardsPool += rewardsAmount;

        mntyToken.safeTransferFrom(payer, address(this), amount);
        mntyToken.safeTransfer(treasury, treasuryAmount);

        emit PaymentCollected(payer, amount, treasuryAmount, rewardsAmount);
    }

    function _validateSplit(uint256 bps) internal pure {
        if (bps < 1000 || bps > 9000) revert InvalidSplit();
    }
}
