//SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {TickMath} from "@velodrome-finance/slipstream/core/libraries/TickMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {HexStrings} from "@velodrome-finance/slipstream/periphery/libraries/HexStrings.sol";
import {NFTSVG} from "src/libraries/NFTSVG.sol";

library NFTDescriptor {
    using TickMath for int24;
    using Strings for uint256;
    using HexStrings for uint256;

    struct ConstructTokenURIParams {
        uint256 tokenId;
        address lockedTokenAddress;
        address minterAddress;
        string tokenName;
        string tokenSymbol;
        uint256 lockBoost;
        address lockManagerAddress;
        uint256 lockedAmount;
        uint256 lockRemaining;
        bool isLocked;
        uint256 lockShares;
    }

    uint256 public constant SCALE = 100;

    function generateSVGImage(
        ConstructTokenURIParams memory params
    ) external pure returns (string memory svg) {
        NFTSVG.SVGParams memory svgParams = NFTSVG.SVGParams({
            tokenName: params.tokenName,
            tokenSymbol: params.tokenSymbol,
            owner: addressToString(params.minterAddress),
            lockedTokenAddress: addressToString(params.lockedTokenAddress),
            lockManagerAddress: params.lockManagerAddress,
            lockBoost: lockBoostString(params.lockBoost),
            lockedAmount: params.lockedAmount,
            lockRemaining: (params.lockRemaining / 1 days).toString(),
            isLocked: params.isLocked,
            lockShares: params.lockShares,
            tokenId: params.tokenId,
            color0: tokenToColorHex(
                uint256(uint160(params.lockedTokenAddress)),
                136
            ),
            color1: tokenToColorHex(
                uint256(uint160(params.minterAddress)),
                136
            ),
            color2: tokenToColorHex(
                uint256(uint160(params.lockedTokenAddress)),
                0
            ),
            color3: tokenToColorHex(uint256(uint160(params.minterAddress)), 0),
            x1: scale(
                getCircleCoord(
                    uint256(uint160(params.lockedTokenAddress)),
                    16,
                    params.tokenId
                ),
                0,
                255,
                16,
                274
            ),
            y1: scale(
                getCircleCoord(
                    uint256(uint160(params.minterAddress)),
                    16,
                    params.tokenId
                ),
                0,
                255,
                100,
                484
            ),
            x2: scale(
                getCircleCoord(
                    uint256(uint160(params.lockedTokenAddress)),
                    32,
                    params.tokenId
                ),
                0,
                255,
                16,
                274
            ),
            y2: scale(
                getCircleCoord(
                    uint256(uint160(params.minterAddress)),
                    32,
                    params.tokenId
                ),
                0,
                255,
                100,
                484
            ),
            x3: scale(
                getCircleCoord(
                    uint256(uint160(params.lockedTokenAddress)),
                    48,
                    params.tokenId
                ),
                0,
                255,
                16,
                274
            ),
            y3: scale(
                getCircleCoord(
                    uint256(uint160(params.minterAddress)),
                    48,
                    params.tokenId
                ),
                0,
                255,
                100,
                484
            )
        });

        return NFTSVG.generateSVG(svgParams);
    }

    // @notice Returns the lock boost as a string in percentage format with 2 decimal places.
    // @param lockBoost the lock boost value in the format of 1e4 (1% = 100).
    function lockBoostString(
        uint256 lockBoost
    ) private pure returns (string memory boost) {
        uint256 wholePart = lockBoost / SCALE;
        uint256 decimalPart = lockBoost % SCALE;
        boost = string.concat("+", wholePart.toString());
        if (decimalPart > 0) {
            boost = string.concat(boost, ".", decimalPart.toString());
        }
        return string.concat(boost, "%");
    }

    function addressToString(
        address addr
    ) private pure returns (string memory) {
        return HexStrings.toHexString(uint256(uint160(addr)), 20);
    }

    function scale(
        uint256 n,
        uint256 inMn,
        uint256 inMx,
        uint256 outMn,
        uint256 outMx
    ) private pure returns (string memory) {
        return
            Strings.toString(
                ((n - inMn) * (outMx - outMn)) / (inMx - inMn) + outMn
            );
    }

    function tokenToColorHex(
        uint256 token,
        uint256 offset
    ) internal pure returns (string memory str) {
        return string((token >> offset).toHexStringNoPrefix(3));
    }

    function getCircleCoord(
        uint256 tokenAddress,
        uint256 offset,
        uint256 tokenId
    ) internal pure returns (uint256) {
        return (sliceTokenHex(tokenAddress, offset) * tokenId) % 255;
    }

    function sliceTokenHex(
        uint256 token,
        uint256 offset
    ) internal pure returns (uint256) {
        return uint256(uint8(token >> offset));
    }
}
