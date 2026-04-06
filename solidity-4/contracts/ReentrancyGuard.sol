// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Minimal Reentrancy Guard
/// @notice Protects functions against nested reentrant calls.
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status = _NOT_ENTERED;

    /// @notice Prevents a function from being called reentrantly.
    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANT");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}
