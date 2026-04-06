// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library StringValidator {
    /**
     * @dev Validates that a string contains only alphanumeric characters and optionally
     * spaces, hyphen and underscore
     * @param allowSpaces Whether to allow spaces, hyphen and underscore
     */
    function isValidString(
        string memory str,
        bool allowSpaces
    ) internal pure returns (bool) {
        bytes memory b = bytes(str);

        for (uint256 i = 0; i < b.length; i++) {
            bytes1 char = b[i];

            // Allow: A-Z, a-z, 0-9, space, hyphen, underscore
            if (
                !((char >= 0x30 && char <= 0x39) || // 0-9
                    (char >= 0x41 && char <= 0x5A) || // A-Z
                    (char >= 0x61 && char <= 0x7A) || // a-z // space // hyphen
                    (allowSpaces &&
                        (char == 0x20 || char == 0x2D || char == 0x5F))) // underscore
            ) {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev Validates string length
     */
    function isValidLength(
        string memory str,
        uint256 maxLength
    ) internal pure returns (bool) {
        bytes memory b = bytes(str);
        return b.length <= maxLength && b.length > 0;
    }
}
