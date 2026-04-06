// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { LibSupplyRequest } from "../libraries/LibSupplyRequest.sol";
import "fhevm/lib/TFHE.sol";

contract SupplyFacet {
    function supplyRequest(address asset, einput _amount, uint16 referralCode, bytes calldata inputProof) external {
        euint64 amount = TFHE.asEuint64(_amount, inputProof);
        LibSupplyRequest.supplyRequest(asset, amount, referralCode);
    }

    function callbackSupplyRequest(uint256 requestId, uint64 amount) external {
        LibSupplyRequest.callbackSupplyRequest(requestId, amount);
    }

    function finalizeSupplyRequests(uint256 supplyRequestId) external {
        LibSupplyRequest.finalizeSupplyRequests(supplyRequestId);
    }
}
