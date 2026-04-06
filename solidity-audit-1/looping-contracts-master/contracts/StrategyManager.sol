// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPool } from "./interfaces/IPool.sol";


/// @notice contract used to manage custom strategy on behalf of the user
contract StrategyManager is Ownable {
    using SafeERC20 for IERC20;

    /// @notice variables are used on the UI to identify which StrategyManager is used for certain pairs of assets
    address immutable public pool;
    address immutable public yieldAsset;
    address immutable public debtAsset;

    struct Call {
        address target;
        uint256 value;
        bytes data;
        bool allowRevert;
    }

    constructor(
        address _owner,
        address _pool,
        address _yieldAsset,
        address _debtAsset
    ) Ownable(_owner){
        pool = _pool;
        yieldAsset = _yieldAsset;
        debtAsset = _debtAsset;
    }

    modifier onlyOwnerOrSelf(){
      require(msg.sender == owner() || msg.sender == address(this), "only owner or self");
      _;
    }

    function executeCall(address target, uint256 value, bytes memory data, bool allowRevert) public payable onlyOwner() returns (bytes memory) {
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!allowRevert) {
            if (!success) _revertWithReason(returnData);
        }
        return returnData;
    }

    function executeMultiCall(Call[] memory calls) external payable onlyOwner() {
        for (uint256 i  = 0; i < calls.length; i++){
            executeCall(calls[i].target, calls[i].value, calls[i].data, calls[i].allowRevert);
        }
    }

    function cleanOutTokens(address[] memory tokens) external onlyOwnerOrSelf() {
        for (uint256 i = 0; i < tokens.length; i++){
            if (tokens[i] == address(0)){
                    (bool sent,) = owner().call{value: address(this).balance}("");
                    require(sent, "cleanOutTokens: failed to send native");
            } else {
                uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
                IERC20(tokens[i]).transfer(owner(), balance);
            }
        }
    }

    function withdrawAllFromPool(address[] calldata tokens) external onlyOwnerOrSelf() {
        for (uint256 i = 0; i < tokens.length; i++){
            IPool(pool).withdraw(tokens[i], type(uint256).max, owner());
        }
    }

    function _revertWithReason(bytes memory returndata) internal pure {
        if (returndata.length > 0) {
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert("execution failed");
        }
    }
}