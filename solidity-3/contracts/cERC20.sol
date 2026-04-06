// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "fhevm/lib/TFHE.sol";
import "fhevm/config/ZamaFHEVMConfig.sol";
import "./zama/ConfidentialERC20Wrapped.sol";

/// @notice This contract implements an encrypted ERC20-like token with confidential balances using Zama's FHE library.
/// @dev It supports typical ERC20 functionality such as transferring tokens, minting, and setting allowances,
/// @dev but uses encrypted data types.
contract cERC20 is SepoliaZamaFHEVMConfig, ConfidentialERC20Wrapped {
    event OnUnwrapSuccessHook(uint256 requestId, uint256 amount);
    event OnUnwrapFailHook(uint256 requestId, uint256 amount);
    /// @notice Constructor to initialize the token's name and symbol, and set up the owner
    /// @param erc20_ Address of the ERC20 token to wrap/unwrap.
    /// @param maxDecryptionDelay_ Maximum delay for the Gateway to decrypt. Use high values for production.
    constructor(address erc20_, uint256 maxDecryptionDelay_) ConfidentialERC20Wrapped(erc20_, maxDecryptionDelay_) {}

    /// @notice Custom unwrap callback to notify the confidentiality adapter
    function callbackUnwrap(uint256 requestId, bool canUnwrap) public override nonReentrant onlyGateway {
        UnwrapRequest memory unwrapRequest = unwrapRequests[requestId];

        if (canUnwrap) {
            /// @dev It does a supply adjustment.
            uint256 amountUint256 = unwrapRequest.amount * (10 ** (ERC20_TOKEN.decimals() - decimals()));

            try ERC20_TOKEN.transfer(unwrapRequest.account, amountUint256) {
                _unsafeBurn(unwrapRequest.account, unwrapRequest.amount);
                _totalSupply -= unwrapRequest.amount;
                emit Unwrap(unwrapRequest.account, unwrapRequest.amount);

                // Custom hook to adapter after successful unwrap
                if (unwrapRequest.account.code.length > 0) {
                    try IUnwrapReceiver(unwrapRequest.account).onUnwrap(requestId, amountUint256) {
                        emit OnUnwrapSuccessHook(requestId, amountUint256);
                    } catch {
                        emit OnUnwrapFailHook(requestId, amountUint256);
                    }
                }
            } catch {
                emit UnwrapFailTransferFail(unwrapRequest.account, unwrapRequest.amount);
            }
        } else {
            emit UnwrapFailNotEnoughBalance(unwrapRequest.account, unwrapRequest.amount);
        }

        delete unwrapRequests[requestId];
        delete isAccountRestricted[unwrapRequest.account];
    }
}

interface IUnwrapReceiver {
    // function executeConfidential(einput encryptedData, bytes calldata inputProof) external;
    function onUnwrap(uint256 requestId, uint256 amount) external;
}
