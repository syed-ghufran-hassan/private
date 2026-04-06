```solidity
Ran 6 tests for test/test.t.sol:StakingOrderVulnerabilityTest
[PASS] testFuzz_AlwaysVulnerable(uint96,uint96,uint16) (runs: 257, μ: 423336, ~: 428414)
[PASS] test_AttackWithTimestampManipulation() (gas: 59081)
Logs:
  
=== TEST 3: Attack with Stake Before Reward Claim ===
  Alice staked 1000 tokens
  1000 seconds passed - 100,000 tokens in rewards accumulated
  
=== ATTACK SCENARIO ===
  Attacker sees accumulated rewards and prepares to steal
  Attacker stakes 1,000,000 tokens (flash loan)...
  
  ATTACK SUCCESSFUL: Attacker now has a claim to
     rewards generated during the 1000 seconds BEFORE they staked!
  
Impact:
    Total staked after attack: 1001000000000000000000000
    Alice's fair share was drastically reduced!

[PASS] test_ContractGeneratesRewards() (gas: 54213)
Logs:
  
=== VERIFYING CONTRACT BASELINE ===
  Reward index after update: 0
    No rewards generated - check _updateRewardIndex logic

[PASS] test_DilutionEffect() (gas: 73808)
Logs:
  
=== TEST 2: Dilution Effect (The Real Vulnerability) ===
  Alice staked 1000 tokens
  100 seconds passed - rewards accumulated for Alice
  
State before Bob stakes:
    Total staked: 1000000000000000000000
    Last minted timestamp: 1
    Reward index: 0
  
Expected rewards for Alice if alone: 10000 tokens
  
Bob stakes 10,000 tokens (large stake)...
  
State after Bob stakes:
    Total staked: 11000000000000000000000
    Reward index: 0
  
10 more seconds pass...
  
Final reward index: 0
  
  VULNERABILITY: Bob's stake diluted Alice's share of the first 100 seconds of rewards!
     Alice should have received 100% of the first 100 seconds of rewards.
     But because Bob staked before those rewards were claimed, Alice lost value.

[PASS] test_MathematicalDemonstration() (gas: 85225)
Logs:
  
=== TEST 4: Mathematical Demonstration ===
  Initial state:
    Alice's stake: 1000 tokens
    Time passed: 100 seconds
    Reward rate: 100 tokens/second
    Total rewards generated: 100 * 100 = 10,000 tokens
    Alice's fair share: 100% = 10,000 tokens
  
Bob stakes 1000 tokens BEFORE rewards claimed:
    Now total staked: 2000 tokens
    Alice's NEW share of past rewards: 50% = 5,000 tokens
    Bob's UNDESERVED share of past rewards: 50% = 5,000 tokens
  
  THE VULNERABILITY:
    Bob earned 5,000 tokens for time he WASN'T staked!
    Alice LOST 5,000 tokens she should have earned!
    This is a direct wealth transfer from Alice to Bob.
  
Another 100 seconds pass:
    New rewards generated: 10,000 tokens
    Fair distribution: Alice 5,000, Bob 5,000
    TOTAL: Alice gets 10,000, Bob gets 5,000
  
  Without vulnerability: Alice 20,000, Bob 0
    With vulnerability: Alice 10,000, Bob 5,000
    Alice LOST 10,000 tokens, Bob GAINED 5,000 unfairly!

[PASS] test_WrongOrderGivesUnfairRewards() (gas: 74799)
Logs:
  
=== TEST 1: Wrong Order Vulnerability ===
  Alice staked 1000 tokens at timestamp: 1
  10 seconds passed, rewards accumulated
  
Before Bob's stake:
    Reward index: 0
    Last minted: 1
    Total staked: 1000000000000000000000
  
Bob staking 2000 tokens...
  
After Bob's stake:
    Reward index before: 0
    Reward index after: 0
    Difference: 0
  
   No immediate reward index change - checking dilution effect...
    Final reward index after more time: 0
    Total staked: 3001000000000000000000
  
 VULNERABILITY: Bob's stake diluted Alice's share of previously accumulated rewards!

Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 77.79ms (77.68ms CPU time)

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
