// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AgentWallet
 * @notice Smart contract wallet for AI agents - replaces server-side EOAs
 * @dev Each user gets their own AgentWallet contract that can propose transactions to their Safe
 * 
 * SECURITY IMPROVEMENTS over current system:
 * 1. No private keys stored on server
 * 2. User can revoke agent permissions anytime
 * 3. On-chain audit trail of all agent actions
 * 4. User controls the wallet (Montty only has operator role)
 *
 * AUDIT FIXES APPLIED:
 * - C-01: Added _initialized flag to prevent re-initialization after renounceOwnership
 * - H-02: Implemented recoverTokens() with proper IERC20 handling
 * - M-04: Fixed markExecuted() signature cleanup order
 * - M-08: Changed recoverETH() from transfer() to call() for Safe compatibility
 * - L-02: Removed unused usedNonces mapping
 * - L-03: Updated pragma to ^0.8.20 for consistency
 */
contract AgentWallet is Ownable {  
    // Note: Implementation uses deployer as owner, clones use initialize pattern
    constructor() Ownable(msg.sender) {}
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    
    // ============ State ============
    
    /// @notice Initialization guard — prevents re-initialization after renounceOwnership (C-01 fix)
    bool private _initialized;
    
    /// @notice The user's Safe multisig that this agent wallet interacts with
    address public safeAddress;
    
    /// @notice Montty backend has operator permissions (can propose, not execute)
    address public operator;
    
    /// @notice Whether this wallet is active
    bool public isActive;
    
    /// @notice Nonce tracking for replay protection
    uint256 public nonce;
    
    /// @notice All transactions proposed by this agent
    mapping(bytes32 => AgentTransaction) public transactions;
    
    /// @notice ERC-1271 magic value for valid signatures
    bytes4 constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    
    /// @notice Pending Safe signatures (hash => approved)
    mapping(bytes32 => bool) public approvedSignatures;
    
    // ============ Structs ============
    
    struct AgentTransaction {
        address to;
        uint256 value;
        bytes data;
        uint256 proposedAt;
        bool executed;
        bytes32 safeTxHash;
        string metadata; // JSON string with agent context
    }
    
    // ============ Events ============
    
    event AgentWalletInitialized(address indexed user, address indexed safe, address operator);
    event TransactionProposed(
        bytes32 indexed txHash,
        address indexed to,
        uint256 value,
        bytes data,
        bytes32 indexed safeTxHash
    );
    event TransactionExecuted(bytes32 indexed txHash, bytes32 indexed safeTxHash);
    event SafeSignatureApproved(bytes32 indexed safeTxHash);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event SafeAddressUpdated(address indexed oldSafe, address indexed newSafe);
    event WalletDeactivated();
    event WalletReactivated();
    event ETHRecovered(address indexed to, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    
    // ============ Modifiers ============
    
    modifier onlyOperator() {
        require(msg.sender == operator, "AgentWallet: only operator");
        _;
    }
    
    modifier onlyActive() {
        require(isActive, "AgentWallet: wallet not active");
        _;
    }
    
    // ============ Initialization ============
    
    /**
     * @notice Initialize the agent wallet
     * @param _user The user who owns this wallet (Safe owner)
     * @param _safe The user's Safe multisig address
     * @param _operator Montty backend address that can propose transactions
     * @dev C-01 FIX: Uses _initialized flag instead of owner() == address(0) check.
     *      This prevents re-initialization if the owner calls renounceOwnership().
     */
    function initialize(
        address _user,
        address _safe,
        address _operator
    ) external {
        require(!_initialized, "AgentWallet: already initialized");
        require(_user != address(0), "AgentWallet: invalid user");
        require(_safe != address(0), "AgentWallet: invalid safe");
        require(_operator != address(0), "AgentWallet: invalid operator");
        
        _initialized = true;
        _transferOwnership(_user);
        safeAddress = _safe;
        operator = _operator;
        isActive = true;
        
        emit AgentWalletInitialized(_user, _safe, _operator);
    }
    
    // ============ Core Functions ============
    
    /**
     * @notice Propose a transaction to the user's Safe
     * @param _to Destination address
     * @param _value ETH value to send
     * @param _data Transaction data
     * @param _metadata JSON metadata about the agent action
     * @return txHash Unique hash of this proposal
     * 
     * @dev This is called by Montty backend when an agent wants to execute something.
     * The actual Safe transaction still requires user signature via Safe UI.
     */
    function proposeTransaction(
        address _to,
        uint256 _value,
        bytes calldata _data,
        string calldata _metadata
    ) external onlyOperator onlyActive returns (bytes32 txHash) {
        nonce++;
        
        txHash = keccak256(abi.encodePacked(
            address(this),
            nonce,
            _to,
            _value,
            keccak256(_data),
            block.timestamp
        ));
        
        // Compute what the Safe tx hash would be (for reference)
        bytes32 safeTxHash = keccak256(abi.encodePacked(
            safeAddress,
            _to,
            _value,
            keccak256(_data),
            nonce
        ));
        
        transactions[txHash] = AgentTransaction({
            to: _to,
            value: _value,
            data: _data,
            proposedAt: block.timestamp,
            executed: false,
            safeTxHash: safeTxHash,
            metadata: _metadata
        });
        
        emit TransactionProposed(txHash, _to, _value, _data, safeTxHash);
        
        return txHash;
    }
    
    /**
     * @notice Approve a signature for a Safe transaction (ERC-1271)
     * @param _safeTxHash The Safe transaction hash to approve
     * 
     * @dev This allows the AgentWallet to "sign" Safe transactions as an owner.
     * The operator (Montty backend) calls this after proposing a transaction.
     * Safe will verify via isValidSignature.
     */
    function approveSafeSignature(bytes32 _safeTxHash) external onlyOperator onlyActive {
        approvedSignatures[_safeTxHash] = true;
        emit SafeSignatureApproved(_safeTxHash);
    }
    
    /**
     * @notice ERC-1271: Verify if a signature is valid
     * @param _hash The hash that was signed (SafeTxHash)
     * @param _signature The signature (not used, we track approved hashes)
     * @return magicValue ERC1271_MAGIC_VALUE if valid
     * 
     * @dev Safe calls this to verify contract signatures. We check if the
     * hash was pre-approved by the operator via approveSafeSignature.
     */
    function isValidSignature(bytes32 _hash, bytes memory _signature) external view returns (bytes4 magicValue) {
        if (approvedSignatures[_hash]) {
            return ERC1271_MAGIC_VALUE;
        }
        return 0;
    }
    
    /**
     * @notice Get pre-signed signature data for Safe API
     * @param _safeTxHash The Safe transaction hash
     * @return signature The contract signature formatted for Safe API
     * 
     * @dev Safe API expects signatures in a specific format for contract owners.
     * This returns the signature data that should be sent to Safe API.
     */
    function getSafeContractSignature(bytes32 _safeTxHash) external view returns (bytes memory) {
        require(approvedSignatures[_safeTxHash], "AgentWallet: signature not approved");
        
        // Safe contract signature format: 0x + address + signature type (0)
        // The signature type 0 indicates a contract signature verified via ERC-1271
        bytes memory signature = abi.encodePacked(
            uint256(uint160(address(this))), // contract address as uint256
            uint256(65), // position of signature data (not used for contract sigs)
            uint8(0) // signature type = contract signature
        );
        
        return signature;
    }
    
    /**
     * @notice Mark a transaction as executed
     * @param _txHash The transaction hash
     * @param _safeTxHash The actual Safe transaction hash
     * 
     * @dev Called by Montty after Safe confirms execution.
     *      M-04 FIX: Cleans up the ORIGINAL safeTxHash before overwriting.
     */
    function markExecuted(
        bytes32 _txHash,
        bytes32 _safeTxHash
    ) external onlyOperator {
        AgentTransaction storage txn = transactions[_txHash];
        require(txn.proposedAt > 0, "AgentWallet: tx not found");
        require(!txn.executed, "AgentWallet: already executed");
        
        // M-04 FIX: Clean up the ORIGINAL approved signature first
        delete approvedSignatures[txn.safeTxHash];
        
        txn.executed = true;
        txn.safeTxHash = _safeTxHash;
        
        // Also clean up the new safeTxHash if different
        if (txn.safeTxHash != _safeTxHash) {
            delete approvedSignatures[_safeTxHash];
        }
        
        emit TransactionExecuted(_txHash, _safeTxHash);
    }
    
    // ============ Admin Functions (Owner Only) ============
    
    /**
     * @notice Update the operator (Montty backend address)
     * @param _newOperator New operator address
     */
    function updateOperator(address _newOperator) external onlyOwner {
        require(_newOperator != address(0), "AgentWallet: invalid operator");
        
        address oldOperator = operator;
        operator = _newOperator;
        
        emit OperatorUpdated(oldOperator, _newOperator);
    }
    
    /**
     * @notice Update the Safe address (if user changes Safe)
     * @param _newSafe New Safe address
     */
    function updateSafeAddress(address _newSafe) external onlyOwner {
        require(_newSafe != address(0), "AgentWallet: invalid safe");
        
        address oldSafe = safeAddress;
        safeAddress = _newSafe;
        
        emit SafeAddressUpdated(oldSafe, _newSafe);
    }
    
    /**
     * @notice Deactivate the wallet (pause all agent operations)
     */
    function deactivate() external onlyOwner {
        isActive = false;
        emit WalletDeactivated();
    }
    
    /**
     * @notice Reactivate the wallet
     */
    function reactivate() external onlyOwner {
        isActive = true;
        emit WalletReactivated();
    }
    
    /**
     * @notice Emergency function to recover any ETH stuck in contract
     * @dev M-08 FIX: Uses call() instead of transfer() to support Safe/contract owners
     *      that require more than 2300 gas in their receive() function.
     */
    function recoverETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "AgentWallet: no ETH");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "AgentWallet: ETH transfer failed");
        emit ETHRecovered(owner(), balance);
    }
    
    /**
     * @notice Emergency function to recover any ERC20 tokens stuck in contract
     * @param _token The ERC20 token address to recover
     * @dev H-02 FIX: Properly implemented with IERC20 interface (was previously empty).
     */
    function recoverTokens(address _token) external onlyOwner {
        require(_token != address(0), "AgentWallet: invalid token");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "AgentWallet: no tokens");
        IERC20(_token).safeTransfer(owner(), balance);
        emit TokensRecovered(_token, owner(), balance);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get all transaction details
     */
    function getTransaction(bytes32 _txHash) external view returns (AgentTransaction memory) {
        return transactions[_txHash];
    }
    
    /**
     * @notice Check if this wallet is properly configured
     */
    function isConfigured() external view returns (bool) {
        return safeAddress != address(0) && operator != address(0) && isActive;
    }
    
    receive() external payable {}
}

/**
 * @title AgentWalletFactory
 * @notice Factory for creating AgentWallet instances
 * @dev Uses minimal proxy pattern (Clones) for gas efficiency
 *
 * AUDIT FIXES APPLIED:
 * - C-02: createWallet() now restricted to owner/operator (was permissionless)
 */
contract AgentWalletFactory is Ownable {
    using Clones for address;
    
    // ============ State ============
    
    /// @notice Implementation contract to clone
    address public implementation;
    
    /// @notice Mapping of user => their agent wallet
    mapping(address => address) public userWallets;
    
    /// @notice Montty operator address (backend)
    address public operator;
    
    /// @notice All created wallets
    address[] public allWallets;
    
    // ============ Events ============
    
    event WalletCreated(address indexed user, address indexed wallet, address indexed safe);
    event ImplementationUpdated(address indexed newImplementation);
    event OperatorUpdated(address indexed newOperator);
    
    // ============ Errors ============
    
    error Unauthorized();
    error InvalidAddress();
    error WalletAlreadyExists();
    error LengthMismatch();
    
    // ============ Modifiers ============
    
    /// @dev C-02 FIX: Only owner or operator can create wallets, preventing front-running
    modifier onlyAuthorized() {
        if (msg.sender != owner() && msg.sender != operator) revert Unauthorized();
        _;
    }
    
    // ============ Constructor ============
    
    /**
     * @param _implementation Address of AgentWallet implementation
     * @param _operator Montty backend address
     */
    constructor(address _implementation, address _operator) Ownable(msg.sender) {
        require(_implementation != address(0), "Factory: invalid implementation");
        require(_operator != address(0), "Factory: invalid operator");
        
        implementation = _implementation;
        operator = _operator;
    }
    
    // ============ Core Functions ============
    
    /**
     * @notice Create an AgentWallet for a user
     * @param _user The user address
     * @param _safe The user's Safe multisig address
     * @return wallet The address of the created wallet
     * 
     * @dev C-02 FIX: Restricted to owner/operator to prevent front-running attacks.
     *      Previously was permissionless, allowing attackers to create wallets 
     *      with malicious Safe addresses for any user.
     */
    function createWallet(address _user, address _safe) external onlyAuthorized returns (address wallet) {
        if (_user == address(0) || _safe == address(0)) revert InvalidAddress();
        if (userWallets[_user] != address(0)) revert WalletAlreadyExists();
        
        // Create minimal proxy clone
        wallet = implementation.clone();
        
        // Initialize the wallet
        AgentWallet(payable(wallet)).initialize(_user, _safe, operator);
        
        // Store mapping
        userWallets[_user] = wallet;
        allWallets.push(wallet);
        
        emit WalletCreated(_user, wallet, _safe);
        
        return wallet;
    }
    
    /**
     * @notice Batch create wallets (for migrations)
     */
    function batchCreateWallets(
        address[] calldata _users,
        address[] calldata _safes
    ) external onlyOwner returns (address[] memory wallets) {
        if (_users.length != _safes.length) revert LengthMismatch();
        
        wallets = new address[](_users.length);
        
        for (uint i = 0; i < _users.length; i++) {
            if (userWallets[_users[i]] == address(0)) {
                address wallet = implementation.clone();
                AgentWallet(payable(wallet)).initialize(_users[i], _safes[i], operator);
                userWallets[_users[i]] = wallet;
                allWallets.push(wallet);
                wallets[i] = wallet;
                
                emit WalletCreated(_users[i], wallet, _safes[i]);
            }
        }
        
        return wallets;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Update the implementation address
     * @param _newImplementation New implementation contract
     */
    function updateImplementation(address _newImplementation) external onlyOwner {
        require(_newImplementation != address(0), "Factory: invalid implementation");
        implementation = _newImplementation;
        emit ImplementationUpdated(_newImplementation);
    }
    
    /**
     * @notice Update the operator address
     * @param _newOperator New operator address
     */
    function updateOperator(address _newOperator) external onlyOwner {
        require(_newOperator != address(0), "Factory: invalid operator");
        operator = _newOperator;
        emit OperatorUpdated(_newOperator);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get wallet for a user
     */
    function getWallet(address _user) external view returns (address) {
        return userWallets[_user];
    }
    
    /**
     * @notice Check if user has a wallet
     */
    function hasWallet(address _user) external view returns (bool) {
        return userWallets[_user] != address(0);
    }
    
    /**
     * @notice Get total number of wallets created
     */
    function getWalletCount() external view returns (uint256) {
        return allWallets.length;
    }
    
    /**
     * @notice Get all wallets (paginated)
     */
    function getAllWallets(uint256 _offset, uint256 _limit) external view returns (address[] memory) {
        uint256 end = _offset + _limit;
        if (end > allWallets.length) end = allWallets.length;
        
        address[] memory result = new address[](end - _offset);
        for (uint256 i = _offset; i < end; i++) {
            result[i - _offset] = allWallets[i];
        }
        
        return result;
    }
}
