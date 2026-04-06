// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import { LibRepayRequest } from "../libraries/LibRepayRequest.sol";
import { DataTypes } from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

contract RepayFacet {
    function repayRequest(
        address asset,
        einput _amount,
        DataTypes.InterestRateMode interestRateMode,
        bytes calldata inputProof
    ) external {
        euint64 amount = TFHE.asEuint64(_amount, inputProof);
        LibRepayRequest.repayRequest(asset, amount, interestRateMode);
    }

    function callbackRepayRequest(uint256 requestId, uint64 amount) external {
        LibRepayRequest.callbackRepayRequest(requestId, amount);
    }

    function finalizeRepayRequest(uint256 repayRequestId) external {
        LibRepayRequest.finalizeRepayRequests(repayRequestId);
    }
}
