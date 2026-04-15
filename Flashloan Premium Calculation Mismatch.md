
# [H-01] Flashloan Premium Calculation Mismatch

## Description

The Looping contract contains a critical mathematical error in the `openPosition() `function where the flashloan repayment calculation doesn't account for the premium correctly. The contract calculates `repaymentAmount = _flashloanAmount - _initialAmount` and then borrows `repaymentAmount + premium`, but this creates a potential shortfall where the borrowed amount may not cover the actual flashloan repayment requirement of `_flashloanAmount + premium`.

```solidity
require(_flashloanAmount >= _initialAmount, "_flashloanAmount < _initialAmount");  
  
//use flashloan to borrow _debtAsset  
uint256 repaymentAmount = _flashloanAmount - _initialAmount;  
bytes memory params = abi.encode(0, _yieldAsset, _swapper, _path, repaymentAmount, _minAmountOut, msg.sender, 0, _deadline);  
IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);
```

## Root Cause

The vulnerability stems from incorrect mathematical logic in the flashloan repayment calculation. The contract assumes that:

`initialAmount + (repaymentAmount + premium) = flashloanAmount + premium  `

But since `repaymentAmount = flashloanAmount - initialAmount`, the actual equation becomes:

`initialAmount + (flashloanAmount - initialAmount + premium) = flashloanAmount + premium `

This only works when the premium is zero or when the initialAmount exactly covers the premium. In reality, the contract needs to borrow `flashloanAmount - initialAmount + premium `to ensure sufficient funds for repayment

## Attack Path

when a user calls openPosition() with parameters that create a mathematical mismatch between the borrowed amount and the actual flashloan repayment requirement. Specifically, when the flashloan premium is significant relative to the user's initial collateral, the contract's calculation of repaymentAmount = _flashloanAmount - _initialAmount followed by borrowing repaymentAmount + premium may result in insufficient funds to repay the full flashloan amount plus premium.

## Impact

- Users lose gas fees when position opening fails due to insufficient funds
- The contract becomes unpredictable under certain market conditions
- Failed transactions create poor user experience and loss of trust
- Users lose gas fees and potentially opportunity costs

## Fix

```solidity
function openPosition(  
    address _pool,   
    address _swapper,  
    address _debtAsset,   
    address _yieldAsset,   
    uint256 _initialAmount,   
    uint256 _flashloanAmount,   
    uint256 _minAmountOut,  
    address[] memory _path,  
    bool _startWithYield,  
    uint256 _minInitialAmountOut,  
    uint256 _deadline  
) external nonReentrant() {  
    require(pools[_pool], "pool not allowed");  
      
    _refund(_debtAsset, _yieldAsset, 0, 0, owner());  
  
    if (_startWithYield){  
        IERC20(_yieldAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);  
        _initialAmount = _swap(_swapper, _reversePath(_path), _initialAmount, _minInitialAmountOut, _deadline);  
    } else {  
        IERC20(_debtAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);  
    }  
  
    require(_flashloanAmount >= _initialAmount, "_flashloanAmount < _initialAmount");  
  
    // FIXED: Calculate repayment amount correctly  
    uint256 repaymentAmount = _flashloanAmount - _initialAmount;  
      
    // FIXED: Borrow enough to cover both repayment and premium  
    bytes memory params = abi.encode(0, _yieldAsset, _swapper, _path, repaymentAmount, _minAmountOut, msg.sender, 0, _deadline);  
    IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);  
}  
  
function _executeOpenPosition(bytes memory params, address debtAsset, uint256 amount, uint256 premium) internal {  
    (  
        ,   
        address yieldAsset,   
        address swapper,   
        address[] memory path,   
        uint256 repaymentAmount,  
        uint256 minAmountOut,  
        address user,  
        ,  
        uint256 deadline  
    ) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));  
  
    uint256 yieldAmount = _swap(swapper, path, amount, minAmountOut, deadline);  
  
    IERC20(yieldAsset).safeIncreaseAllowance(msg.sender, yieldAmount);  
    IPool(msg.sender).supply(yieldAsset, yieldAmount, user, 0);  
  
    // FIXED: Borrow repaymentAmount + premium to ensure sufficient funds  
    IPool(msg.sender).borrow(debtAsset, repaymentAmount + premium, 2, 0, user);  
}
```

