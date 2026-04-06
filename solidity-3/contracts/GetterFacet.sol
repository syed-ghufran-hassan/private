// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { LibAdapterStorage } from "../libraries/LibAdapterStorage.sol";
import "fhevm/lib/TFHE.sol";

contract GetterFacet {
    /// @notice Returns user's real supplied balance (encrypted) including interest accrual
    function getSuppliedBalance(address user, address asset) external view returns (euint64) {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();

        return s.scaledBalances[user][asset];
    }

    /// @notice Returns user's real borrowed debt (encrypted) including interest accrual
    function getBorrowedBalance(address user, address asset) external returns (euint64) {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();
        euint64 scaledDebt = s.scaledDebts[user][asset];
        uint256 reserveNormalizedDebt = s.aavePool.getReserveNormalizedVariableDebt(asset);

        euint256 scaledProduct = TFHE.mul(TFHE.asEuint256(scaledDebt), reserveNormalizedDebt);
        euint256 scaledResult = TFHE.div(scaledProduct, 1e27);

        return TFHE.asEuint64(scaledResult);
    }

    /// @notice Returns user's max borrowable amount (already confidentially stored)
    function getMaxBorrowable(address user, address asset) external view returns (euint64) {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();
        return s.userMaxBorrowablePerAsset[user][asset];
    }

    /// @notice Returns user's withdrawable amount (supplied - borrowed) in encrypted space
    function getScaledDebt(address user, address asset) external view returns (euint64) {
        LibAdapterStorage.Storage storage s = LibAdapterStorage.getStorage();
        euint64 debtScaledBalance = s.scaledDebts[user][asset];

        return debtScaledBalance;
    }
}
