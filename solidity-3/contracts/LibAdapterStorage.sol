// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import { IPool } from "@aave/core-v3/contracts/interfaces/IPool.sol";
import { IPoolDataProvider } from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import { DataTypes } from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";

library LibAdapterStorage {
    bytes32 constant STORAGE_POSITION = keccak256("confidential.adapter.storage");

    enum RequestType {
        SUPPLY,
        WITHDRAW,
        BORROW,
        REPAY
    }

    struct RequestData {
        RequestType requestType;
        bytes data;
    }

    struct SupplyRequestData {
        address sender;
        address asset;
        euint64 amount;
        uint16 referralCode;
    }

    struct WithdrawRequestData {
        address sender;
        address asset;
        euint64 amount;
        address to;
    }

    struct BorrowRequestData {
        address sender;
        address asset;
        euint64 amount;
        DataTypes.InterestRateMode interestRateMode;
        uint16 referralCode;
    }

    struct RepayRequestData {
        address sender;
        address asset;
        euint64 amount;
        DataTypes.InterestRateMode interestRateMode;
    }

    struct Storage {
        uint8 REQUEST_THRESHOLD;
        IPool aavePool;
        IPoolDataProvider aaveDataProvider;
        SupplyRequestData[] supplyRequests;
        WithdrawRequestData[] withdrawRequests;
        BorrowRequestData[] borrowRequests;
        RepayRequestData[] repayRequests;
        address[] aaveAssets;
        mapping(address => address) tokenAddressToCTokenAddress;
        mapping(address => address) cTokenAddressToTokenAddress;
        mapping(uint256 => SupplyRequestData[]) requestIdToSupplyRequests;
        mapping(uint256 => WithdrawRequestData[]) requestIdToWithdrawRequests;
        mapping(uint256 => BorrowRequestData[]) requestIdToBorrowRequests;
        mapping(uint256 => RepayRequestData[]) requestIdToRepayRequests;
        mapping(uint256 => RequestData) requestIdToRequestData;
        mapping(uint256 => uint256) requestIdToAmount;
        mapping(uint256 => uint256) requestIdToUnwrapRequestId;
        mapping(address => mapping(address => euint64)) scaledBalances; // user => asset => scaledBalance
        mapping(address => mapping(address => euint64)) scaledDebts; // user => asset => scaledDebt
        mapping(address => mapping(address => euint64)) userMaxBorrowablePerAsset; // user => asset => maxBorrowable
    }

    error AmountIsZero();
    error InvalidRequestType();
    error NotEnoughSupplyRequest();
    error NotEnoughBorrowRequest();
    error NotEnoughRepayRequest();
    error InvalidCTokenAddress(address asset);
    error NoUnwrapRequestIdFound();

    event OnUnwrap(uint256 indexed requestId, uint256 amount);

    event SupplyRequested(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        euint64 amount,
        uint16 indexed referralCode
    );

    event WithdrawRequested(address indexed reserve, address indexed user, address indexed to, euint64 amount);

    event BorrowRequested(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        euint64 amount,
        DataTypes.InterestRateMode interestRateMode,
        uint256 borrowRate,
        uint16 indexed referralCode
    );

    event RepayRequested(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        euint64 amount,
        bool useATokens
    );

    event FinalizeSupplyRequest(address reserve, uint256 requestId, uint256 multiplier, uint256 amount);
    event FinalizeWithdrawRequest(address reserve, uint256 requestId);
    event FinalizeBorrowRequest(address reserve, uint256 requestId);
    event FinalizeRepayRequest(address reserve, uint256 requestId);

    event SupplyCallback(address indexed reserve, uint64 amount, uint256 requestId);
    event WithdrawCallback(address indexed reserve, uint64 amount, uint256 requestId);
    event BorrowCallback(address indexed reserve, uint64 amount, uint256 requestId);
    event RepayCallback(address indexed reserve, uint64 amount, uint256 requestId);

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
