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
    
    // Events
    event MinRateUpdated(uint256 newRate);
    event RewardIndexUpdated(uint256 newIndex);
    
    constructor(uint256 _initialMinRate) Ownable(msg.sender) {
        minRate = _initialMinRate;
        lastMinted = block.timestamp;
        rewardIndex = 0;
    }
    
    function setMinRate(uint256 newMintRate) external onlyOwner {
        minRate = newMintRate;
        emit MinRateUpdated(newMintRate);
    }
    
    function _updateRewardIndex() internal {
        if (totalStakedAmount == 0) return;
        
        uint256 elapsed = block.timestamp - lastMinted;
        if (elapsed == 0) return;
        
        uint256 mintAmount = elapsed * minRate;
        
        // Calculate reward increase using Math.mulDiv
        uint256 rewardIncrease = Math.mulDiv(mintAmount, 1e18, totalStakedAmount);
        rewardIndex += rewardIncrease;
        
        lastMinted = block.timestamp;
        emit RewardIndexUpdated(rewardIndex);
    }
    
    // Helper function to stake tokens (you'll need to implement this)
    function stake(uint256 amount) external {
        // Add your staking logic here
        totalStakedAmount += amount;
        _updateRewardIndex();
    }
    
    // Helper function to unstake tokens (you'll need to implement this)
    function unstake(uint256 amount) external {
        // Add your unstaking logic here
        totalStakedAmount -= amount;
        _updateRewardIndex();
    }
}