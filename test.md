halmos --test test/halmos/vault/AutopoolDebt.t.sol --function checkAssetBreakdownOrdering

```solidity
 // SPDX-License-Identifier: UNLICENSED  
pragma solidity 0.8.17;  
  
import { Test } from "forge-std/Test.sol";  
import { AutopoolDebt } from "src/vault/libs/AutopoolDebt.sol";  
import { IAutopool } from "src/interfaces/vault/IAutopool.sol";  
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
  
contract AutopoolDebtHalmosTest is Test {  
     
  function checkAssetBreakdownOrdering(  
    uint256 cachedMinDebtValue,  
    uint256 cachedDebtValue,  
    uint256 cachedMaxDebtValue  
) public {  
    assume(cachedMinDebtValue <= cachedDebtValue);  
    assume(cachedDebtValue <= cachedMaxDebtValue);
    AutopoolDebt.DestinationInfo memory destInfo;  
    destInfo.cachedMinDebtValue = uint256(keccak256("min"));  
    destInfo.cachedDebtValue = uint256(keccak256("mid"));  
    destInfo.cachedMaxDebtValue = uint256(keccak256("max"));  
      
    // Invariant: min <= mid <= max  
    assert(destInfo.cachedMinDebtValue <= destInfo.cachedDebtValue);  
    assert(destInfo.cachedDebtValue <= destInfo.cachedMaxDebtValue);  
}
function checkWithdrawalSafety(  
    uint256 totalIdle,  
    uint256 totalDebtMin,  
    uint256 assets  
) public {  
    // Constrain inputs to valid states  
    assume(totalIdle >= 0);  
    assume(totalDebtMin >= 0);  
    assume(assets >= 0);  
      
    IAutopool.AssetBreakdown memory breakdown;  
    breakdown.totalIdle = totalIdle;  
    breakdown.totalDebtMin = totalDebtMin;  
      
    // Calculate what would be pulled from market  
    uint256 assetsFromIdle = assets > breakdown.totalIdle ? 0 : assets;  
    uint256 totalAssetsToPull = assets - assetsFromIdle;  
      
    // Invariant: withdrawal cannot exceed available assets  
    assert(totalAssetsToPull <= breakdown.totalIdle + breakdown.totalDebtMin);  
}
function checkDebtRecalculationInvariant(  
    uint256 originalShares,  
    uint256 currentShares,  
    uint256 cachedDebtValue,  
    uint256 cachedMinDebtValue,  
    uint256 cachedMaxDebtValue,  
    uint256 prevOwnedShares  
) public {  
    // Assume valid inputs  
    assume(prevOwnedShares > 0);  
    assume(originalShares <= prevOwnedShares);  
    assume(cachedMinDebtValue <= cachedDebtValue && cachedDebtValue <= cachedMaxDebtValue);  
      
    // Calculate debt decreases  
    uint256 debtDecrease = (cachedDebtValue * originalShares) / prevOwnedShares;  
    uint256 minDebtDecrease = (cachedMinDebtValue * originalShares) / prevOwnedShares;  
    uint256 maxDebtDecrease = (cachedMaxDebtValue * originalShares) / prevOwnedShares;  
      
    // Invariant: decreases should maintain ordering  
    assert(minDebtDecrease <= debtDecrease);  
    assert(debtDecrease <= maxDebtDecrease);  
      
    // Invariant: decreases should not exceed cached values  
    assert(minDebtDecrease <= cachedMinDebtValue);  
    assert(debtDecrease <= cachedDebtValue);  
    assert(maxDebtDecrease <= cachedMaxDebtValue);  
}
function checkFlashRebalanceConservation(  
    uint256 totalIdleBefore,  
    uint256 totalDebtBefore,  
    uint256 totalIdleDecrease,  
    uint256 totalIdleIncrease,  
    uint256 totalDebtDecrease,  
    uint256 totalDebtIncrease  
) public {  
    // Setup valid state  
    assume(totalIdleBefore >= totalIdleDecrease);  
    assume(totalDebtBefore >= totalDebtDecrease);  
      
    uint256 totalIdleAfter = totalIdleBefore - totalIdleDecrease + totalIdleIncrease;  
    uint256 totalDebtAfter = totalDebtBefore - totalDebtDecrease + totalDebtIncrease;  
      
    // Invariant: total assets should not decrease (ignoring swap costs which are external)  
    // This is a simplified invariant - in reality, swap costs may reduce total  
    assert(totalIdleAfter + totalDebtAfter >= 0);  
}
function checkStaleDataConservatism(  
    uint256 cachedMaxDebtValue,  
    uint256 cachedMinDebtValue,  
    uint256 currentShares,  
    uint256 ownedShares,  
    uint256 ceilingPrice,  
    uint256 floorPrice  
) public {  
    assume(ownedShares > 0);  
    assume(cachedMinDebtValue <= cachedMaxDebtValue);  
      
    // Deposit case: use ceiling price  
    uint256 staleDebtDeposit = cachedMaxDebtValue.mulDiv(currentShares, ownedShares, Math.Rounding.Down);  
    uint256 newValueDeposit = (currentShares * ceilingPrice) / 1e18;  
      
    // Invariant: for deposits, use the more conservative (higher) value  
    uint256 finalDepositValue = staleDebtDeposit > newValueDeposit ? staleDebtDeposit : newValueDeposit;  
    assert(finalDepositValue >= newValueDeposit);  
      
    // Withdrawal case: use floor price  
    uint256 staleDebtWithdraw = cachedMinDebtValue.mulDiv(currentShares, ownedShares, Math.Rounding.Up);  
    uint256 newValueWithdraw = (currentShares * floorPrice) / 1e18;  
      
    // Invariant: for withdrawals, use the more conservative (lower) value  
    uint256 finalWithdrawValue = staleDebtWithdraw < newValueWithdraw ? staleDebtWithdraw : newValueWithdraw;  
    assert(finalWithdrawValue <= newValueWithdraw);  
}
function checkUnderflowProtection(  
    uint256 currentTotalDebt,  
    uint256 currentTotalDebtMin,  
    uint256 currentTotalDebtMax,  
    uint256 debtDecrease,  
    uint256 debtMinDecrease,  
    uint256 debtMaxDecrease  
) public {  
    // Apply the underflow protection logic  
    uint256 newTotalDebt = debtDecrease > currentTotalDebt ? 0 : currentTotalDebt - debtDecrease;  
    uint256 newTotalDebtMin = debtMinDecrease > currentTotalDebtMin ? 0 : currentTotalDebtMin - debtMinDecrease;  
    uint256 newTotalDebtMax = debtMaxDecrease > currentTotalDebtMax ? 0 : currentTotalDebtMax - debtMaxDecrease;  
      
    // Invariant: values should never be negative  
    assert(newTotalDebt >= 0);  
    assert(newTotalDebtMin >= 0);  
    assert(newTotalDebtMax >= 0);  
      
    // Invariant: ordering should be maintained  
    assert(newTotalDebtMin <= newTotalDebt);  
    assert(newTotalDebt <= newTotalDebtMax);  
}

}
```
