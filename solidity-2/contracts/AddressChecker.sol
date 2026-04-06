//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAddressChecker} from "src/interfaces/IAddressChecker.sol";

contract AddressChecker is Ownable, IAddressChecker {
    mapping(address => bool) public isDex;

    constructor(address[] memory _dexes) Ownable(msg.sender) {
        for (uint256 i = 0; i < _dexes.length; i++) {
            isDex[_dexes[i]] = true;
        }
    }

    function addDex(address dex) external onlyOwner {
        isDex[dex] = true;
    }

    function removeDex(address dex) external onlyOwner {
        isDex[dex] = false;
    }
}
