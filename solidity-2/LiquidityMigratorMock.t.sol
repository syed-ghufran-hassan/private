// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {IWETH9} from "src/interfaces/ILiquidityMigrator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH9 is ERC20, IWETH9 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {}

    function withdraw(uint256 amount) external {}
}

contract LiquidityMigratorMock {
    address private feeAccount;
    IWETH9 private weth;

    constructor(address _feeAccount) {
        feeAccount = _feeAccount;
        weth = new WETH9();
    }

    function createPoolAndLockLiquidity(
        address /*token*/,
        uint256 /*amountToAdd*/
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidityDelta,
            uint256 amount0,
            uint256 amount1,
            uint256 lockId
        )
    {
        return (1, 1000, 4 ether, 200e8 ether, 500);
    }

    function getFeeAccount() external view returns (address) {
        return feeAccount;
    }

    function getWeth() external view returns (IWETH9) {
        return weth;
    }
}
