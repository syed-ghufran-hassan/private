// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Simple ETH faucet with per-wallet cooldown and lifetime cap.
/// @notice will not be deployed on mainnet
contract Faucet {
    uint256 public constant DRIP_AMOUNT = 0.01 ether;
    uint256 public constant COOLDOWN = 1 days;
    uint256 public constant MAX_CLAIMS = 5;
    uint256 public constant MAX_TOTAL_PER_WALLET = 0.05 ether;

    mapping(address => uint256) public lastClaimAt;
    mapping(address => uint256) public claimCount;
    mapping(address => uint256) public totalClaimed;
    address public admin;

    event Claimed(address indexed claimant, uint256 amount, uint256 claimCount, uint256 totalClaimed);
    event Funded(address indexed from, uint256 amount);
    event AdminUpdated(address indexed admin);
    event Withdrawn(address indexed to, uint256 amount);

    error CooldownActive(uint256 nextClaimAt);
    error MaxClaimsReached();
    error MaxTotalReached();
    error InsufficientFaucetBalance();
    error NotAdmin();

    constructor(address admin_) {
        require(admin_ != address(0), "ADMIN_ZERO");
        admin = admin_;
        emit AdminUpdated(admin_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Updates the registry admin.
    /// @dev Transfers authority of the faucet
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "ADMIN_ZERO");
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    /// @notice Claims 0.001 ETH if caller is eligible.
    function claim() external {
        uint256 count = claimCount[msg.sender];
        if (count >= MAX_CLAIMS) revert MaxClaimsReached();

        uint256 claimed = totalClaimed[msg.sender];
        if (claimed + DRIP_AMOUNT > MAX_TOTAL_PER_WALLET) revert MaxTotalReached();

        uint256 last = lastClaimAt[msg.sender];
        if (count > 0 && block.timestamp < last + COOLDOWN) {
            revert CooldownActive(last + COOLDOWN);
        }

        if (address(this).balance < DRIP_AMOUNT) revert InsufficientFaucetBalance();

        claimCount[msg.sender] = count + 1;
        totalClaimed[msg.sender] = claimed + DRIP_AMOUNT;
        lastClaimAt[msg.sender] = block.timestamp;

        (bool ok,) = payable(msg.sender).call{value: DRIP_AMOUNT}("");
        require(ok, "ETH_TRANSFER_FAILED");

        emit Claimed(msg.sender, DRIP_AMOUNT, claimCount[msg.sender], totalClaimed[msg.sender]);
    }

    /// @notice Admin withdraws ETH from faucet.
    function withdraw() external onlyAdmin {
        (bool ok,) = payable(msg.sender).call{value: address(this).balance}("");
        require(ok, "ETH_TRANSFER_FAILED");
        emit Withdrawn(msg.sender, address(this).balance);
    }
}
