// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice will not be deployed on mainnet
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Mints mock tokens for testing/dev.
    /// @dev Anyone can mint; only use on local/test networks.
    /// @param to Recipient address.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Approves a spender.
    /// @dev Mirrors ERC20 approve semantics.
    /// @param spender The spender address.
    /// @param amount The allowance amount.
    /// @return success True if approval succeeded.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Transfers tokens to a recipient.
    /// @dev Mirrors ERC20 transfer semantics.
    /// @param to Recipient address.
    /// @param amount Transfer amount.
    /// @return success True if transfer succeeded.
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @notice Transfers tokens using allowance.
    /// @dev Mirrors ERC20 transferFrom semantics and decreases allowance.
    /// @param from The token owner address.
    /// @param to The recipient address.
    /// @param amount Transfer amount.
    /// @return success True if transfer succeeded.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        require(balanceOf[from] >= amount, "BALANCE");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
