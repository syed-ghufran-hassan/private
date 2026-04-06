// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/gateway/GatewayCaller.sol";
import { LibAdapterStorage } from "../libraries/LibAdapterStorage.sol";
import { TFHE } from "fhevm/lib/TFHE.sol";
import { ConfidentialERC20Wrapped } from "../../../zama/ConfidentialERC20Wrapped.sol";
import { DataTypes } from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IScaledBalanceToken } from "@aave/core-v3/contracts/interfaces/IAToken.sol";

library LibBorrowRequest {
    bytes4 constant BorrowRequestFacet__callbackBorrowRequest =
        bytes4(keccak256("callbackBorrowRequest(uint256,uint64)"));

    function borrowRequest(
        address asset,
        euint64 amount,
        uint16 referralCode,
        DataTypes.InterestRateMode interestRateMode
    ) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        // check if user has enough supply
        euint64 maxBorrowable = s.userMaxBorrowablePerAsset[msg.sender][asset];
        euint64 safeAmount = TFHE.select(TFHE.le(amount, maxBorrowable), amount, TFHE.asEuint64(0));

        s.borrowRequests.push(
            LibAdapterStorage.BorrowRequestData({
                sender: msg.sender,
                asset: asset,
                amount: safeAmount,
                referralCode: referralCode,
                interestRateMode: interestRateMode
            })
        );

        TFHE.allow(s.borrowRequests[s.borrowRequests.length - 1].amount, msg.sender);
        TFHE.allowThis(s.borrowRequests[s.borrowRequests.length - 1].amount);

        emit LibAdapterStorage.BorrowRequested(
            asset,
            msg.sender,
            msg.sender,
            safeAmount,
            interestRateMode,
            0,
            referralCode
        );

        if (s.borrowRequests.length < s.REQUEST_THRESHOLD) {
            return;
        }

        LibAdapterStorage.BorrowRequestData[] memory requests = new LibAdapterStorage.BorrowRequestData[](
            s.REQUEST_THRESHOLD
        );
        uint256[] memory matchedIndexes = new uint256[](s.REQUEST_THRESHOLD);
        uint256 count = 0;

        for (uint256 i = 0; i < s.borrowRequests.length; i++) {
            LibAdapterStorage.BorrowRequestData memory brd = s.borrowRequests[i];
            if (brd.asset == asset && brd.interestRateMode == interestRateMode) {
                requests[count] = brd;
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
            _processBorrowRequests(s, requests, matchedIndexes);
        }
    }

    function _processBorrowRequests(
        LibAdapterStorage.Storage storage s,
        LibAdapterStorage.BorrowRequestData[] memory brd,
        uint256[] memory matchedIndexes
    ) internal {
        uint256[] memory cts = new uint256[](1);
        euint256 totalAmount = TFHE.asEuint256(0);

        for (uint256 i = 0; i < brd.length; i++) {
            totalAmount = TFHE.add(totalAmount, brd[i].amount);
        }

        cts[0] = Gateway.toUint256(totalAmount);
        uint256 requestId = Gateway.requestDecryption(
            cts,
            BorrowRequestFacet__callbackBorrowRequest,
            0,
            block.timestamp + 100,
            false
        );

        for (uint256 i = 0; i < brd.length; i++) {
            s.requestIdToBorrowRequests[requestId].push(brd[i]);
        }

        s.requestIdToRequestData[requestId] = LibAdapterStorage.RequestData({
            requestType: LibAdapterStorage.RequestType.BORROW,
            data: abi.encode(brd)
        });

        for (uint256 i = matchedIndexes.length; i > 0; i--) {
            uint256 idx = matchedIndexes[i - 1];
            s.borrowRequests[idx] = s.borrowRequests[s.borrowRequests.length - 1];
            s.borrowRequests.pop();
        }
    }

    function callbackBorrowRequest(uint256 requestId, uint64 amount) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        if (amount == 0) {
            revert LibAdapterStorage.AmountIsZero();
        }

        LibAdapterStorage.BorrowRequestData[] memory requests = s.requestIdToBorrowRequests[requestId];

        address asset = requests[0].asset;
        address cToken = s.tokenAddressToCTokenAddress[asset];

        uint256 amountToBorrow = amount *
            (10 ** (IERC20Metadata(asset).decimals() - ConfidentialERC20Wrapped(cToken).decimals()));

        s.requestIdToAmount[requestId] = amountToBorrow;

        emit LibAdapterStorage.BorrowCallback(asset, uint64(amountToBorrow), requestId);
    }

    function finalizeBorrowRequests(uint256 requestId) internal {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();
        LibAdapterStorage.RequestData memory requestData = s.requestIdToRequestData[requestId];

        if (requestData.requestType != LibAdapterStorage.RequestType.BORROW) {
            revert LibAdapterStorage.InvalidRequestType();
        }

        LibAdapterStorage.BorrowRequestData[] memory requests = abi.decode(
            requestData.data,
            (LibAdapterStorage.BorrowRequestData[])
        );

        _handleBorrowFinalize(s, requestId, requests);

        delete s.requestIdToRequestData[requestId];
        delete s.requestIdToBorrowRequests[requestId];
        delete s.requestIdToAmount[requestId];
    }

    function _handleBorrowFinalize(
        LibAdapterStorage.Storage storage s,
        uint256 requestId,
        LibAdapterStorage.BorrowRequestData[] memory requests
    ) internal {
        address asset = requests[0].asset;
        address cToken = s.tokenAddressToCTokenAddress[asset];

        address debtToken = s.aavePool.getReserveData(asset).variableDebtTokenAddress;
        uint256 beforeScaledDebt = IScaledBalanceToken(debtToken).scaledBalanceOf(address(this));

        DataTypes.InterestRateMode interestRateMode = requests[0].interestRateMode;
        uint16 referralCode = requests[0].referralCode;
        uint256 amount = s.requestIdToAmount[requestId];

        s.aavePool.borrow(asset, amount, uint256(interestRateMode), referralCode, address(this));

        uint256 afterScaledDebt = IScaledBalanceToken(debtToken).scaledBalanceOf(address(this));
        uint256 difference = afterScaledDebt - beforeScaledDebt;

        uint256 multiplier = difference / (amount / (10 ** 6));

        // wrap borrowed tokens
        IERC20(asset).approve(cToken, amount);
        ConfidentialERC20Wrapped(cToken).wrap(amount);

        _processStateUpdates(s, requests, multiplier, asset, cToken);

        emit LibAdapterStorage.FinalizeBorrowRequest(asset, requestId);
    }

    function _processStateUpdates(
        LibAdapterStorage.Storage storage s,
        LibAdapterStorage.BorrowRequestData[] memory requests,
        uint256 multiplier,
        address asset,
        address cToken
    ) internal {
        for (uint256 i = 0; i < requests.length; i++) {
            address user = requests[i].sender;
            euint64 requestAmount = requests[i].amount;

            euint64 newBalance = TFHE.add(
                s.scaledDebts[requests[i].sender][asset],
                TFHE.div(TFHE.mul(requests[i].amount, uint64(multiplier)), 1e6)
            );
            s.scaledDebts[requests[i].sender][asset] = newBalance;

            TFHE.allowThis(newBalance);
            TFHE.allow(newBalance, requests[i].sender);

            euint64 scaledBalance = s.scaledBalances[user][asset];

            _setMaxBorrowables(scaledBalance, user);

            TFHE.allow(requestAmount, cToken);
            ConfidentialERC20Wrapped(cToken).transfer(user, requestAmount);
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
