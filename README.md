0xfaaA795B8c074B8573E505CB4E5C415c90545fcF

```solidity
  
========== POC 4: MULTIPLE JOINS INFLATE WINNER SHARES ==========

  Winner country: Japan (index 10)
  
User1 deposits 5 ETH
  User1 joins Japan - 1st time
  User1 joins Japan - 2nd time (VULNERABILITY!)
  User1 joins Japan - 3rd time (VULNERABILITY!)
  
User1 total shares: 4925000000000000000
  
=== VULNERABILITY DETECTED ===
  User shares: 4925000000000000000
  Total winner shares (inflated): 14775000000000000000
  User appears in usersAddress array multiple times!
  
=== IMPACT ===
  Finalized vault asset: 4925000000000000000
  Expected payout (if no vulnerability): 4925000000000000000
  Actual payout (reduced by 3x denominator): 1641666666666666666
  
Actual payout received: 1641666666666666666
  Loss due to vulnerability: 3283333333333333334
  
  POC 4 Successful: User lost 2/3 of their rightful winnings!
     Root cause: Same user can join multiple times, inflating totalWinnerShares

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 8.04ms (2.43ms CPU time)


```

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract Staking is Ownable {
    // State variables
    uint256 public minRate;
    uint256 public totalStakedAmount;
    uint256 public rewardIndex;
    uint256 public lastMinted;
    
    // Per-user tracking (REQUIRED for fair distribution)
    mapping(address => uint256) public userStakedAmount;
    mapping(address => uint256) public userRewardDebt;
    mapping(address => uint256) public pendingRewards;
    
    // Events
    event MinRateUpdated(uint256 newRate);
    event RewardIndexUpdated(uint256 newIndex);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    
    constructor(uint256 _initialMinRate) Ownable(msg.sender) {
        minRate = _initialMinRate;
        lastMinted = block.timestamp;
        rewardIndex = 0;
    }
    
    function setMinRate(uint256 newMintRate) external onlyOwner {
        minRate = newMintRate;
        emit MinRateUpdated(newMintRate);
    }
    
    // FIXED: Update rewards before adding stake
    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");
        
        // FIX: Update rewards FIRST (uses OLD totalStakedAmount)
        _updateRewardIndex();
        
        // FIX: Update user rewards before changing their stake
        _updateUserRewards(msg.sender);
        
        // Then add the new stake
        userStakedAmount[msg.sender] += amount;
        totalStakedAmount += amount;
        
        emit Staked(msg.sender, amount);
    }
    
    // FIXED: Update rewards before removing stake
    function unstake(uint256 amount) external {
        require(amount > 0 && userStakedAmount[msg.sender] >= amount, "Invalid amount");
        
        // Update rewards FIRST
        _updateRewardIndex();
        _updateUserRewards(msg.sender);
        
        // Then remove stake
        userStakedAmount[msg.sender] -= amount;
        totalStakedAmount -= amount;
        
        emit Unstaked(msg.sender, amount);
    }
    
    // FIXED: Proper reward index update
    function _updateRewardIndex() internal {
        // FIX: Always update lastMinted to prevent huge elapsed time
        if (totalStakedAmount == 0) {
            lastMinted = block.timestamp;  // CRITICAL FIX!
            return;
        }
        
        uint256 elapsed = block.timestamp - lastMinted;
        if (elapsed == 0) return;
        
        uint256 mintAmount = elapsed * minRate;
        uint256 rewardIncrease = Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        rewardIndex += rewardIncrease;
        lastMinted = block.timestamp;
        
        emit RewardIndexUpdated(rewardIndex);
    }
    
    // NEW: Track per-user rewards
    function _updateUserRewards(address user) internal {
        uint256 pending = ((userStakedAmount[user] * (rewardIndex - userRewardDebt[user])) / 1e18);
        if (pending > 0) {
            pendingRewards[user] += pending;
        }
        userRewardDebt[user] = rewardIndex;
    }
    
    // NEW: Allow users to claim rewards
    function claimRewards() external {
        _updateRewardIndex();
        _updateUserRewards(msg.sender);
        
        uint256 reward = pendingRewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        
        pendingRewards[msg.sender] = 0;
        
        // Transfer rewards (implement your token transfer)
        // IERC20(rewardToken).transfer(msg.sender, reward);
        
        emit RewardsClaimed(msg.sender, reward);
    }
    
    // NEW: View pending rewards
    function getPendingRewards(address user) external view returns (uint256) {
        uint256 currentRewardIndex = rewardIndex;
        if (totalStakedAmount > 0) {
            uint256 elapsed = block.timestamp - lastMinted;
            if (elapsed > 0) {
                uint256 mintAmount = elapsed * minRate;
                currentRewardIndex += (mintAmount * 1e18) / totalStakedAmount;
            }
        }
        
        uint256 userReward = ((userStakedAmount[user] * (currentRewardIndex - userRewardDebt[user])) / 1e18);
        return pendingRewards[user] + userReward;
    }
}
```
