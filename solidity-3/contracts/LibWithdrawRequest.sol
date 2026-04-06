// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/gateway/GatewayCaller.sol";
import { LibAdapterStorage } from "../libraries/LibAdapterStorage.sol";
import { TFHE } from "fhevm/lib/TFHE.sol";
import { ConfidentialERC20Wrapped } from "../../../zama/ConfidentialERC20Wrapped.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IScaledBalanceToken } from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import { DataTypes } from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library LibWithdrawRequest {
    bytes4 constant WithdrawRequestFacet__callbackWithdrawRequest =
        bytes4(keccak256("callbackWithdrawRequest(uint256,uint64)"));

    function withdrawRequest(address asset, euint64 amount) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        // Calculate withdrawable scaled balance = scaledBalances - scaledDebts
        euint64 suppliedScaledBalance = s.scaledBalances[msg.sender][asset];
        euint64 debtScaledBalance = s.scaledDebts[msg.sender][asset];
        euint64 withdrawableScaledBalance = TFHE.sub(suppliedScaledBalance, debtScaledBalance);

        euint64 safeAmount = TFHE.select(TFHE.le(amount, withdrawableScaledBalance), amount, TFHE.asEuint64(0));

        s.withdrawRequests.push(
            LibAdapterStorage.WithdrawRequestData({
                sender: msg.sender,
                asset: asset,
                amount: safeAmount,
                to: msg.sender
            })
        );

        TFHE.allow(s.withdrawRequests[s.withdrawRequests.length - 1].amount, msg.sender);
        TFHE.allowThis(s.withdrawRequests[s.withdrawRequests.length - 1].amount);

        emit LibAdapterStorage.WithdrawRequested(asset, msg.sender, msg.sender, safeAmount);

        if (s.withdrawRequests.length < s.REQUEST_THRESHOLD) {
            return;
        }

        LibAdapterStorage.WithdrawRequestData[] memory requests = new LibAdapterStorage.WithdrawRequestData[](
            s.REQUEST_THRESHOLD
        );
        uint256[] memory matchedIndexes = new uint256[](s.REQUEST_THRESHOLD);
        uint256 count = 0;

        for (uint256 i = 0; i < s.withdrawRequests.length; i++) {
            LibAdapterStorage.WithdrawRequestData memory wrd = s.withdrawRequests[i];
            if (wrd.asset == asset) {
                requests[count] = wrd;
                matchedIndexes[count] = i;

                unchecked {
                    count++;
                }

                if (count == s.REQUEST_THRESHOLD) {
                    break;
                }
            }
        }

        if (requests.length >= s.REQUEST_THRESHOLD) {
            _processWithdrawRequests(s, requests, matchedIndexes);
        }
    }

    function _processWithdrawRequests(
        LibAdapterStorage.Storage storage s,
        LibAdapterStorage.WithdrawRequestData[] memory wrd,
        uint256[] memory matchedIndexes
    ) internal {
        uint256[] memory cts = new uint256[](1);
        euint64 totalAmount = TFHE.asEuint64(0);

        for (uint256 i = 0; i < wrd.length; i++) {
            totalAmount = TFHE.add(totalAmount, wrd[i].amount);
        }

        cts[0] = Gateway.toUint256(totalAmount);
        uint256 requestId = Gateway.requestDecryption(
            cts,
            WithdrawRequestFacet__callbackWithdrawRequest,
            0,
            block.timestamp + 100,
            false
        );

        for (uint256 i = 0; i < wrd.length; i++) {
            s.requestIdToWithdrawRequests[requestId].push(wrd[i]);
        }

        s.requestIdToRequestData[requestId] = LibAdapterStorage.RequestData({
            requestType: LibAdapterStorage.RequestType.WITHDRAW,
            data: abi.encode(wrd)
        });

        for (uint256 i = matchedIndexes.length; i > 0; i--) {
            uint256 index = matchedIndexes[i - 1];
            s.withdrawRequests[index] = s.withdrawRequests[s.withdrawRequests.length - 1];
            s.withdrawRequests.pop();
        }
    }

    function callbackWithdrawRequest(uint256 requestId, uint64 amount) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        if (amount == 0) revert LibAdapterStorage.AmountIsZero();

        LibAdapterStorage.WithdrawRequestData[] memory requests = s.requestIdToWithdrawRequests[requestId];

        address asset = requests[0].asset;
        address cToken = s.tokenAddressToCTokenAddress[asset];

        uint256 amountToWithdraw = amount *
            (10 ** (IERC20Metadata(asset).decimals() - ConfidentialERC20Wrapped(cToken).decimals()));

        s.aavePool.withdraw(asset, amountToWithdraw, address(this));

        IERC20(asset).approve(cToken, amount);
        ConfidentialERC20Wrapped(cToken).wrap(amount);

        emit LibAdapterStorage.WithdrawCallback(asset, uint64(amountToWithdraw), requestId);
    }

    function finalizeWithdrawRequest(uint256 requestId) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        LibAdapterStorage.RequestData memory requestData = s.requestIdToRequestData[requestId];

        if (requestData.requestType != LibAdapterStorage.RequestType.WITHDRAW) {
            revert LibAdapterStorage.InvalidRequestType();
        }

        LibAdapterStorage.WithdrawRequestData[] memory requests = abi.decode(
            requestData.data,
            (LibAdapterStorage.WithdrawRequestData[])
        );

        address asset = requests[0].asset;
        address cToken = s.tokenAddressToCTokenAddress[asset];

        _processStateUpdates(s, requests, asset, cToken);

        emit LibAdapterStorage.FinalizeWithdrawRequest(asset, requestId);

        delete s.requestIdToWithdrawRequests[requestId];
        delete s.requestIdToRequestData[requestId];
    }

    function _processStateUpdates(
        LibAdapterStorage.Storage storage s,
        LibAdapterStorage.WithdrawRequestData[] memory requests,
        address asset,
        address cToken
    ) internal {
        for (uint256 i = 0; i < requests.length; i++) {
            // Subtract the amount withdrawn
            s.scaledBalances[requests[i].sender][asset] = TFHE.sub(
                s.scaledBalances[requests[i].sender][asset],
                requests[i].amount
            );

            TFHE.allow(s.scaledBalances[requests[i].sender][asset], requests[i].sender);
            TFHE.allowThis(s.scaledBalances[requests[i].sender][asset]);

            euint64 scaledBalance = s.scaledBalances[requests[i].sender][asset];

            _setMaxBorrowables(scaledBalance, requests[i].sender);

            // transfer the asset to the user
            TFHE.allow(requests[i].amount, cToken);
            TFHE.allowThis(requests[i].amount);
            ConfidentialERC20Wrapped(cToken).transfer(requests[i].to, requests[i].amount);
        }
    }

    function _setMaxBorrowables(euint64 currentBalance, address sender) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        address[] memory aaveAssets = s.aaveAssets;
        for (uint256 i = 0; i < aaveAssets.length; i++) {
            address asset = aaveAssets[i];

            (, uint256 ltv, , , , , , , , ) = s.aaveDataProvider.getReserveConfigurationData(asset);

            s.userMaxBorrowablePerAsset[sender][asset] = TFHE.div(TFHE.mul(currentBalance, uint64(ltv)), uint64(10000));

            TFHE.allow(s.userMaxBorrowablePerAsset[sender][asset], sender);
            TFHE.allowThis(s.userMaxBorrowablePerAsset[sender][asset]);
        }
    }
}
