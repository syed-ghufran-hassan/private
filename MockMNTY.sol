// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockMNTY is ERC20, Ownable {
    constructor() ERC20("Montty Token", "MNTY") Ownable(msg.sender) {
        _mint(msg.sender, 10_000_000 ether);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        if (msg.sender != account) {
            _spendAllowance(account, msg.sender, amount);
        }

        _burn(account, amount);
    }
}
