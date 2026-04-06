// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

interface IMockUSDC {
    function mint(address to, uint256 amount) external;
}

/// @notice Faucet that mints mock USDC directly to eligible claimants.
/// @notice will not be deployed on mainnet
contract UsdcFaucet {
    uint256 public constant CLAIM_AMOUNT = 50_000 * 1e6;
    uint256 public constant COOLDOWN = 1 days;

    IMockUSDC public immutable usdc;
    mapping(address => uint256) public lastClaimAt;

    event Claimed(address indexed claimant, uint256 amount, uint256 claimedAt);

    error CooldownActive(uint256 nextClaimAt);
    error TokenZeroAddress();

    constructor(address usdc_) {
        if (usdc_ == address(0)) revert TokenZeroAddress();
        usdc = IMockUSDC(usdc_);
    }

    /// @notice Claims 50,000 mock USDC once every 24 hours.
    function claim() external {
        uint256 last = lastClaimAt[msg.sender];
        if (last != 0 && block.timestamp < last + COOLDOWN) {
            revert CooldownActive(last + COOLDOWN);
        }

        lastClaimAt[msg.sender] = block.timestamp;
        usdc.mint(msg.sender, CLAIM_AMOUNT);

        emit Claimed(msg.sender, CLAIM_AMOUNT, block.timestamp);
    }
}
