// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { LibWithdrawRequest } from "../libraries/LibWithdrawRequest.sol";
import "fhevm/lib/TFHE.sol";

contract WithdrawFacet {
    function withdrawRequest(address asset, einput _amount, bytes calldata inputProof) external {
        euint64 amount = TFHE.asEuint64(_amount, inputProof);
        LibWithdrawRequest.withdrawRequest(asset, amount);
    }

    function callbackWithdrawRequest(uint256 requestId, uint64 amount) external {
        LibWithdrawRequest.callbackWithdrawRequest(requestId, amount);
    }

    function finalizeWithdrawRequests(uint256 withdrawRequestId) external {
        LibWithdrawRequest.finalizeWithdrawRequest(withdrawRequestId);
    }
}
