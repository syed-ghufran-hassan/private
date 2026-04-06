// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import { LibBorrowRequest } from "../libraries/LibBorrowRequest.sol";
import { DataTypes } from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

contract BorrowFacet {
    function borrowRequest(
        address asset,
        einput _amount,
        DataTypes.InterestRateMode interestRateMode,
        uint16 referralCode,
        bytes calldata inputProof
    ) external {
        euint64 amount = TFHE.asEuint64(_amount, inputProof);
        LibBorrowRequest.borrowRequest(asset, amount, referralCode, interestRateMode);
    }

    function callbackBorrowRequest(uint256 requestId, uint64 amount) external {
        LibBorrowRequest.callbackBorrowRequest(requestId, amount);
    }

    function finalizeBorrowRequests(uint256 borrowRequestId) external {
        LibBorrowRequest.finalizeBorrowRequests(borrowRequestId);
    }
}
