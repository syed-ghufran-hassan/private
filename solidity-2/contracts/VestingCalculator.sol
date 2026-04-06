//SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {UD60x18, ud, pow, mul, convert} from "@prb/math/UD60x18.sol";

library VestingCalculator {
    uint256 public constant SCALE = 1e18;
    uint256 public constant MIN_VESTING_PERIOD = 1 days;
    uint256 public constant MAX_VESTING_PERIOD = 365 days;

    function calculateVestingDuration(
        uint256 balance,
        uint256 totalVestedSupply
    ) external pure returns (uint256) {
        UD60x18 vestingExponent = ud(13e17);
        UD60x18 vestedShare = ud(((balance * SCALE) / totalVestedSupply));
        UD60x18 scaledVestedShare = vestedShare.pow(vestingExponent);
        UD60x18 scaledDuration = scaledVestedShare.mul(
            ud(((MAX_VESTING_PERIOD - MIN_VESTING_PERIOD) * SCALE))
        );
        return MIN_VESTING_PERIOD + convert(scaledDuration);
    }
}
