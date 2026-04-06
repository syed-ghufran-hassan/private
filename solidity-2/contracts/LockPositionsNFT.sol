//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NFTDescriptor} from "src/libraries/NFTDescriptor.sol";
import {ILockPositionsNFT} from "src/interfaces/ILockPositionsNFT.sol";

/**
 * @dev LockPositionsNFT is an ERC721 contract that represents locked positions.
 * @notice Each token represents a lock position with details such as amount, lock shares, unlock time, locked at time, and more. It is used by the lock manager contract to mint and manage locked positions. See ILockManager for more details.
 */
contract LockPositionsNFT is
    ERC721Upgradeable,
    OwnableUpgradeable,
    ILockPositionsNFT
{
    using Strings for uint256;
    using Strings for address;

    uint256 public constant SCALE = 1e18;
    mapping(uint256 tokenId => Position) public positions;
    mapping(address owner => IdsOwned owns) private ownedTokenIds;
    uint256 public nextTokenId;
    address public lockedToken;

    modifier owns(uint256 tokenId) {
        if (msg.sender != ownerOf(tokenId)) {
            revert LockPositionsNFT__NotOwnerOf(tokenId);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _lockedToken
    ) public initializer onlyInitializing {
        __ERC721_init(_name, _symbol);
        __Ownable_init(msg.sender);
        lockedToken = _lockedToken;
        nextTokenId = 1;
    }

    function ownerOf(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, ILockPositionsNFT)
        returns (address owner)
    {
        return super.ownerOf(tokenId);
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function burn(uint256 tokenId) external onlyOwner {
        _removeTokenId(ownerOf(tokenId), tokenId);
        _burn(tokenId);
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function safeTransfer(address to, uint256 tokenId) external owns(tokenId) {
        _safeTransfer(msg.sender, to, tokenId);
        _removeTokenId(msg.sender, tokenId);
        _addTokenId(to, tokenId);
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721Upgradeable, ILockPositionsNFT) {
        super.transferFrom(from, to, tokenId);
        _removeTokenId(from, tokenId);
        _addTokenId(to, tokenId);

        emit MetadataUpdate(tokenId);
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function mint(
        address to,
        Position memory position
    ) external onlyOwner returns (uint256) {
        uint256 tokenId = nextTokenId++;
        positions[tokenId] = position;
        _safeMint(to, tokenId);
        _addTokenId(to, tokenId);
        return tokenId;
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function getOwnedTokenIds(
        address _owner,
        uint256 skip,
        uint256 limit
    ) external view returns (uint256[] memory) {
        IdsOwned storage ownedIds = ownedTokenIds[_owner];
        uint256[] storage ids = ownedIds.ids;
        if (limit + skip > ids.length) {
            limit = ids.length - skip;
        }
        uint256[] memory result = new uint256[](limit);
        if (skip >= ids.length) {
            return result;
        }
        for (uint256 i = 0; i < limit; i++) {
            result[i] = ids[i + skip];
        }
        return result;
    }

    /**
     * @inheritdoc ILockPositionsNFT
     */
    function tokenURI(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, ILockPositionsNFT)
        returns (string memory)
    {
        Position memory position = positions[tokenId];
        uint256 lockBoost = _calculateLockBoost(
            position.amount,
            position.lockShares
        );
        string memory imageURI = _generateSVGImage(
            SvgParams({
                position: position,
                tokenId: tokenId,
                lockedToken: lockedToken,
                minter: msg.sender,
                lockManager: address(this),
                blockTimestamp: block.timestamp,
                lockBoost: lockBoost
            })
        );
        string memory lockedTokenAddress = (uint256(uint160(lockedToken)))
            .toHexString();
        string memory generalData = string.concat(
            '"name": "',
            name(),
            '","description": "Represents a lock position. The locked amount unlocks at unlockTime (UNIX epoch time) + proportional reward (depends on lockShares) for the total duration until the lock is claimed.',
            "\\n\\n",
            unicode'⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure token address matches the expected token, as token symbol may be imitated."',
            ', "external_url": "https://castr.fun/token/',
            lockedTokenAddress,
            '", "image": "',
            string.concat("data:image/svg+xml;base64,", imageURI),
            '"'
        );

        string memory attributes = string.concat(
            '"attributes": ',
            '[{ "trait_type": "locked amount", "value": ',
            (position.amount / SCALE).toString(),
            ".", // Add decimal point
            (position.amount % SCALE).toString(),
            '}, { "trait_type": "lock shares", "value": ',
            (position.lockShares / SCALE).toString(),
            ".", // Add decimal point
            (position.lockShares % SCALE).toString(),
            '}, { "display_type": "boost_percentage", "max_value": 35, "trait_type": "locked amount increase", "value": ',
            (lockBoost / 100).toString(),
            ".",
            (lockBoost % 100).toString(), // Add decimal point
            '}, { "display_type": "date",  "trait_type": "unlock time", "value": ',
            position.unlockTime.toString(),
            '}, { "display_type": "date",  "trait_type": "created", "value": ',
            position.lockedAtTime.toString(),
            '}, { "trait_type": "token", "value": "',
            lockedTokenAddress,
            '"}]'
        );
        return
            string.concat(
                _baseURI(),
                Base64.encode(
                    bytes(
                        string.concat("{", generalData, ", ", attributes, "}")
                    )
                )
            );
    }

    /**
     * @return The base URI for the token metadata.
     */
    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }

    function _generateSVGImage(
        SvgParams memory params
    ) private pure returns (string memory) {
        return
            Base64.encode(
                bytes(
                    NFTDescriptor.generateSVGImage(
                        NFTDescriptor.ConstructTokenURIParams({
                            tokenId: params.tokenId,
                            lockedTokenAddress: params.lockedToken,
                            minterAddress: params.minter,
                            tokenName: "Lock Position",
                            tokenSymbol: "LOCK",
                            lockManagerAddress: params.lockManager,
                            lockBoost: params.lockBoost,
                            lockedAmount: (params.position.amount / SCALE),
                            lockRemaining: (
                                params.position.unlockTime >
                                    params.blockTimestamp
                                    ? params.position.unlockTime -
                                        params.blockTimestamp
                                    : 0
                            ),
                            isLocked: params.position.unlockTime >
                                params.blockTimestamp,
                            lockShares: (params.position.lockShares / SCALE)
                        })
                    )
                )
            );
    }

    function _calculateLockBoost(
        uint256 amount,
        uint256 lockShares
    ) private pure returns (uint256) {
        uint256 lockBoost = (((lockShares - amount) * SCALE) / amount) * 100;
        uint256 wholePart = lockBoost / SCALE;
        uint256 decimals = lockBoost % SCALE;
        uint256 decimalPart = (decimals * 100) / SCALE;
        if (((decimals * 1000) / SCALE) % 100 >= 5) {
            decimalPart += 1;
        }
        if (decimalPart == 100) {
            decimalPart = 0;
            wholePart += 1;
        }

        return wholePart * 100 + decimalPart; // Return as whole number with two decimals (e.g., 123.45 as 12345)
    }

    function _removeTokenId(address _owner, uint256 tokenId) private {
        IdsOwned storage ownedIds = ownedTokenIds[_owner];
        uint256[] storage ids = ownedIds.ids;
        uint256 index = ownedIds.indexes[tokenId];
        if (index >= ids.length || ids[index] != tokenId) {
            return; // Graceful handling to avoid reverts
        }
        uint256 lastElement = ids[ids.length - 1];
        ids[index] = lastElement;
        ids.pop();
        ownedIds.indexes[lastElement] = index;
        ownedIds.indexes[tokenId] = type(uint256).max;
    }

    function _addTokenId(address _owner, uint256 tokenId) private {
        ownedTokenIds[_owner].indexes[tokenId] = ownedTokenIds[_owner]
            .ids
            .length;
        ownedTokenIds[_owner].ids.push(tokenId);
    }
}
