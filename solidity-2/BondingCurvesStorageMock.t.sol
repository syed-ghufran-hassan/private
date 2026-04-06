// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {BondingCurve, IBondingCurve} from "src/BondingCurve.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {LockPositionsNFT} from "src/LockPositionsNFT.sol";
import {LockManager} from "src/LockManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract BondingCurvesStorageMock is Ownable {
    uint16 public constant PRECISION = 1000;
    uint8 public feePercent = 10;
    address public lastKingOfTheCasts;
    address public currentKingOfTheCasts;
    address public feeAccount = address(1);
    address public burnableTokenImpl;
    address public lockManagerImpl;
    address public lockPositionsNFTImpl;

    event NewBondingCurveCreated(address indexed curve);
    event FeePercentUpdated(uint8 indexed newFeePercent);

    error BondingCurveFactory__InvalidFeePercent();
    error BondingCurveFactory__NotBondingCurve();

    constructor() Ownable(msg.sender) {
        burnableTokenImpl = address(new BurnableToken());
        lockManagerImpl = address(new LockManager());
        lockPositionsNFTImpl = address(new LockPositionsNFT());
    }

    receive() external payable {}

    function bondingCurves(address /*curve*/) public pure returns (bool) {
        return true;
    }

    function createBondingCurve(
        string memory name,
        string memory symbol,
        bytes memory metadata
    ) external {
        address bondingCurveClone = Clones.clone(address(new BondingCurve()));
        IBondingCurve(bondingCurveClone).initialize(
            name,
            symbol,
            metadata,
            feePercent,
            address(0),
            feeAccount,
            false,
            msg.sender
        );

        emit NewBondingCurveCreated(bondingCurveClone);
    }

    function setFeePercent(uint8 newFeePercent) external onlyOwner {
        if (newFeePercent >= PRECISION || newFeePercent <= 0) {
            revert BondingCurveFactory__InvalidFeePercent();
        }

        feePercent = newFeePercent;
        emit FeePercentUpdated(feePercent);
    }

    function updateKingOfTheCasts(address newKingOfTheCasts) external {
        lastKingOfTheCasts = currentKingOfTheCasts;
        currentKingOfTheCasts = newKingOfTheCasts;
    }

    function removeLastKingOfTheCasts() external {
        currentKingOfTheCasts = address(0);
    }
}
