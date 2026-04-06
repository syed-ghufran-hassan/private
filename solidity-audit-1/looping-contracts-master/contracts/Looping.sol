// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { ISwapper } from "./interfaces/ISwapper.sol";
import { IPool } from "./interfaces/IPool.sol";


contract Looping is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice mapping of whitelisted lending pools
    mapping(address => bool) public pools;
    /// @notice mapping of whitelisted swapper contracts
    mapping(address => bool) public swappers;
    /// @notice address that receives referral rewards from the swapper
    address public referralAddress;

    /// @param _pools array of whitelisted pools
    /// @param _swappers array of whitelisted swappers
    constructor(address[] memory _pools, address[] memory _swappers, address _owner) Ownable(_owner) {
        for (uint256 i = 0; i < _pools.length; i++){
            pools[_pools[i]] = true;
        }
        for (uint256 i = 0; i < _swappers.length; i++){
            swappers[_swappers[i]] = true;
        }

        referralAddress = _owner;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Public Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice function used to open a leveraged position using a flashloan
    /// @param _pool address of the pool we want to supply/borrow from
    /// @param _swapper address of the swapping contract (DEX) used to swap _debtAsset to _yieldAsset
    /// @param _debtAsset asset we want to borrow
    /// @param _yieldAsset asset we want to maximize the supply
    /// @param _initialAmount initial amount of the _debtAsset provided by the user
    /// @param _flashloanAmount amount of the _debtAsset we want to flashloan and then swap to _yieldAsset
    /// @param _minAmountOut minimum amount of _yieldAsset we can receive after swapping _debtAsset
    /// @param _path path used to swap from _debtAsset to _yieldAsset
    /// @param _startWithYield user provides _yieldAsset initially, otherwise we use _debtAsset
    /// @param _minInitialAmountOut minimum output when swapping from yield to debt token (if _startWithYield is true)
    /// @param _deadline deadline for swapping tokens
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
        
        //transfer any funds accidentally sent/stuck in the contract to the owner first
        _refund(_debtAsset, _yieldAsset, 0, 0, owner());

        if (_startWithYield){
            //transfer initial _yieldAsset from user
            IERC20(_yieldAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);
            //swap from yieldAsset to debtAsset
            _initialAmount = _swap(_swapper, _reversePath(_path), _initialAmount, _minInitialAmountOut, _deadline);
        } else {
            //transfer initial _debtAsset from user
            IERC20(_debtAsset).safeTransferFrom(msg.sender, address(this), _initialAmount);
        }

        require(_flashloanAmount >= _initialAmount, "_flashloanAmount < _initialAmount");

        //use flashloan to borrow _debtAsset
        uint256 repaymentAmount = _flashloanAmount - _initialAmount;
        bytes memory params = abi.encode(0, _yieldAsset, _swapper, _path, repaymentAmount, _minAmountOut, msg.sender, 0, _deadline);
        IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);
    }

    /// @notice function used to close a leveraged position using a flashloan
    /// @param _pool address of the pool we want to supply/borrow from
    /// @param _swapper address of the swapping contract (DEX) used to swap _debtAsset to _yieldAsset
    /// @param _debtAsset asset we want to borrow
    /// @param _yieldAsset asset we want to maximize the supply
    /// @param _flashloanAmount amount of the _debtAsset we want to flashloan and then swap to _yieldAsset
    /// @param _minAmountOut minimum amount of _yieldAsset we can receive after swapping _debtAsset
    /// @param _path path used to swap from _debtAsset to _yieldAsset
    /// @param _withdrawAmount amount of yield token we need to withdraw to repay the flashloan (when swapped to _debtAsset, output should be > _flashloanAmount+premium)
    /// @param _deadline deadline for swapping tokens
    function closePosition(
        address _pool, 
        address _swapper,
        address _debtAsset, 
        address _yieldAsset, 
        uint256 _flashloanAmount, 
        uint256 _minAmountOut,
        address[] memory _path,
        uint256 _withdrawAmount,
        uint256 _deadline
    ) external nonReentrant() {
        require(pools[_pool], "pool not allowed");

        //transfer any funds accidentally sent/stuck in the contract to the owner first
        _refund(_debtAsset, _yieldAsset, 0, 0, owner());

        //use flashloan to borrow _debtAsset
        bytes memory params = abi.encode(1, _yieldAsset, _swapper, _path, _flashloanAmount, _minAmountOut, msg.sender, _withdrawAmount, _deadline);
        IPool(_pool).flashLoanSimple(address(this), _debtAsset, _flashloanAmount, params, 0);
    }

    /// @notice callback function called by pool contract during flashloan
    /// @param debtAsset asset we received from the flashloan
    /// @param amount amount of the debtAsset we received from the flashloan
    /// @param premium flashloan premium we must repay
    /// @param initiator address of the flashloan initiator
    /// @param params extra data passed to us by the pool contract
    function executeOperation(
        address debtAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    )  external returns (bool) {
        require(pools[msg.sender], "msg.sender != pool");
        require(initiator == address(this), "initiator != address(this)");

        //actionType: 0 = open position, 1 = close position
        ( uint8 actionType, address yieldAsset, , , , , address user , ,) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));

        if (actionType == 0){
            _executeOpenPosition(params, debtAsset, amount, premium);
        } else if (actionType == 1){
            _executeClosePosition(params, debtAsset);
        }

        //refund any leftover assets that would remain in the contract after flashloan repayment
        _refund(debtAsset, yieldAsset, amount, premium, user);

        //approve pool so it can pull the funds to repay the flashloan
        IERC20(debtAsset).safeIncreaseAllowance(msg.sender, amount + premium);

        return true;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                   Internal Functions                     */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice open a leveraged positon using a flashloan
    /// @dev we take a flashloan of debtAsset, swap it to yieldAsset, supply yieldAsset, borrow debtAsset and repay the flashloan
    function _executeOpenPosition(bytes memory params, address debtAsset, uint256 amount, uint256 premium) internal {
        (
            , //action type
            address yieldAsset, 
            address swapper, 
            address[] memory path, 
            uint256 repaymentAmount,
            uint256 minAmountOut,
            address user,
            ,
            uint256 deadline
        ) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));

        //swap flashloaned debt token to yield token
        uint256 yieldAmount = _swap(swapper, path, amount, minAmountOut, deadline);

        //supply yield tokens, note: msg.sender is now lending pool
        IERC20(yieldAsset).safeIncreaseAllowance(msg.sender, yieldAmount);
        IPool(msg.sender).supply(yieldAsset, yieldAmount, user, 0);

        //borrow debt token, so we have enough to repay the flashloan
        IPool(msg.sender).borrow(debtAsset, repaymentAmount + premium, 2, 0, user);
    }

    /// @dev we take a flashloan of debtAsset, repay the loan, withdraw the yieldAsset, swap yieldAsset to debtAsset, repay the flashloan
    function _executeClosePosition(bytes memory params, address debtAsset) internal {
        (
            , //action type
            address yieldAsset, 
            address swapper, 
            address[] memory path, 
            uint256 repaymentAmount, //=flashloanAmount
            uint256 minAmountOut,
            address user,
            uint256 withdrawAmount,
            uint256 deadline
        ) = abi.decode(params, (uint8, address, address, address[], uint256, uint256, address, uint256, uint256));

        IERC20 hYieldToken = IERC20(IPool(msg.sender).getReserveData(yieldAsset).aTokenAddress);

        //close full position if repaymentAmount == maxUint256
        if (withdrawAmount == type(uint256).max){
            IERC20 debtDebtToken = IERC20(IPool(msg.sender).getReserveData(debtAsset).variableDebtTokenAddress);
            repaymentAmount = debtDebtToken.balanceOf(user);
            withdrawAmount = hYieldToken.balanceOf(user);
        }

        //repay debt, note: msg.sender is now the lending pool
        IERC20(debtAsset).safeIncreaseAllowance(msg.sender, repaymentAmount);
        IPool(msg.sender).repay(debtAsset, repaymentAmount, 2, user);

        //get address of the hToken and transfer it from user, so we can withdraw it
        hYieldToken.safeTransferFrom(user, address(this), withdrawAmount);

        //withdraw yield token
        IPool(msg.sender).withdraw(yieldAsset, withdrawAmount, address(this));

        //swap yield token to debt token
        _swap(swapper, path, withdrawAmount, minAmountOut, deadline);
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                    Helper Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/

    /// @notice used to swap debt token to yield token
    /// @param swapper address of the dex contract
    /// @param path path we want to use when swapping
    /// @param minAmountOut minimum amount fo yield token we want to receive
    /// @return amountOut amount of output token received after the swap
    function _swap(address swapper, address[] memory path, uint256 amountToSwap, uint256 minAmountOut, uint256 deadline) internal returns (uint256) {
        require(swappers[swapper], "swapper not allowed");

        IERC20(path[0]).safeIncreaseAllowance(swapper, amountToSwap);

        uint256 balanceBefore = IERC20(path[path.length-1]).balanceOf(address(this));
        ISwapper(swapper).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            minAmountOut,
            path,
            address(this),
            referralAddress,
            deadline
        );
        uint256 balanceAfter = IERC20(path[path.length-1]).balanceOf(address(this));

        return balanceAfter - balanceBefore;
    }

    /// @notice used to refund any tokens that would remain in the contract after the flashloan repayment
    /// @param debtAsset address of the token we want to borrow
    /// @param yieldAsset address of the token we want to supply
    /// @param amount amount of the debt token we owe from the flashloan
    /// @param premium amount of the premium we need to pay for the flashloan
    function _refund(address debtAsset, address yieldAsset, uint256 amount, uint256 premium, address user) internal {
        uint256 debtAssetBalance = IERC20(debtAsset).balanceOf(address(this));
        uint256 yieldAssetBalance = IERC20(yieldAsset).balanceOf(address(this));

        if (debtAssetBalance > amount + premium){
            IERC20(debtAsset).safeTransfer(user, debtAssetBalance - (amount + premium));
        }
        if (yieldAssetBalance > 0){
            IERC20(yieldAsset).safeTransfer(user, yieldAssetBalance);
        }
    }

    /// @notice reverse an array of addresses
    function _reversePath(address[] memory _array) internal pure returns(address[] memory) {
        uint length = _array.length;
        address[] memory reversedArray = new address[](length);
        uint j = 0;

        for(uint i = length; i >= 1; i--) {
            reversedArray[j] = _array[i-1];
            j++;
        }

        return reversedArray;
    }

    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    /*                     Admin Functions                      */
    /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
    
    /// @notice used to add or remove pools from the whitelist
    function setPool(address _pool, bool _isApproved) external onlyOwner(){
        pools[_pool] = _isApproved;
    }

    /// @notice used to add or remove swappers from the whitelist
    function setSwapper(address _swapper, bool _isApproved) external onlyOwner(){
        swappers[_swapper] = _isApproved;
    }

    /// @notice used to update the swapper referral address
    function setReferralAddress(address _newReferralAddress) external onlyOwner(){
        referralAddress = _newReferralAddress;
    }

    /// @notice used to rescue stuck tokens that were sent to the contract by mistake
    function rescueTokens(address _token, uint256 _amount) external onlyOwner(){
        if (_token == address(0)){
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            require(success, "transfer failed");
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }
}
