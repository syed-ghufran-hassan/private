//SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title SoulboundNFT
 * @notice This contract implements a soulbound NFT that cannot be transferred or sold. It has updateable metadata fields for social media handles.
 */
contract SoulboundNFT is ERC721, Ownable {
    struct Metadata {
        string twitter_xHandle;
        string farcasterHandle;
        string telegramHandle;
        uint256 recievedAtTime;
    }

    using Strings for uint256;
    using Strings for address;

    uint256 public constant MIN_GAS_PER_MINT = 200_000;
    uint256 public constant TWITTER_USERNAME_MAX_LENGTH = 15;
    uint256 public constant FARCASTER_USERNAME_MAX_LENGTH = 16;
    uint256 public constant TELEGRAM_USERNAME_MAX_LENGTH = 32;
    uint256 public constant TELEGRAM_USERNAME_MIN_LENGTH = 5;
    string public image;
    string public animation;
    uint256 public nextTokenId = 1;
    mapping(uint256 tokenId => Metadata) public tokenMetadata;

    event Minted(
        address indexed receiver,
        uint256 indexed tokenId,
        uint256 timestamp
    );

    error SoulboundNFT__NotOwnerOf(uint256 tokenId);
    error SoulboundNFT__InvalidBatch();
    error SoulboundNFT__InvalidTwitterXHandle();
    error SoulboundNFT__InvalidFarcasterHandle();
    error SoulboundNFT__InvalidTelegramHandle();
    error SoulboundNFT__LeadingAtSignNotAllowed();
    error SoulboundNFT__NotTransferable();

    modifier owns(uint256 tokenId) {
        if (msg.sender != ownerOf(tokenId)) {
            revert SoulboundNFT__NotOwnerOf(tokenId);
        }
        _;
    }

    modifier nonLeadingAtSign(bytes memory textBytes) {
        if (textBytes.length > 0 && textBytes[0] == "@") {
            revert SoulboundNFT__LeadingAtSignNotAllowed();
        }
        _;
    }

    /**
     * @dev Constructor to initialize the contract with name and symbol.
     * @param _name The name of the NFT collection.
     * @param _symbol The symbol of the NFT collection.
     * @param _image The image of the NFT.
     * @param _animation The animation of the NFT.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _image,
        string memory _animation
    ) ERC721(_name, _symbol) Ownable(_msgSender()) {
        image = _image;
        animation = _animation;
    }

    /**
     * @notice Sets the image of the NFT.
     * @dev This function can only be called by the owner of the contract.
     */
    function setImage(string memory newImage) external onlyOwner {
        image = newImage;
    }

    /**
     * @notice Sets the animation of the NFT.
     * @dev This function can only be called by the owner of the contract.
     */
    function setAnimation(string memory newAnimation) external onlyOwner {
        animation = newAnimation;
    }

    // function owner() public view override returns (address) {
    //     return super.owner();
    // }

    /**
     * @notice This function is overridden to prevent the transfer of soulbound NFTs.
     */
    function transferFrom(
        address /*from*/,
        address /*to*/,
        uint256 /*tokenId*/
    ) public pure override(ERC721) {
        revert SoulboundNFT__NotTransferable();
    }

    /**
     * @notice This function is overridden to prevent the transfer of soulbound NFTs.
     */
    function approve(
        address /*to*/,
        uint256 /*tokenId*/
    ) public pure override(ERC721) {
        revert SoulboundNFT__NotTransferable();
    }

    /**
     * @notice This function is overridden to prevent the transfer of soulbound NFTs.
     */
    function setApprovalForAll(
        address /*operator*/,
        bool /*approved*/
    ) public pure override(ERC721) {
        revert SoulboundNFT__NotTransferable();
    }

    /**
     * @notice Mints a new soulbound NFT with the provided social media handles.
     * @notice This function can only be called by the owner of the contract.
     * @param to The address to mint the NFT to.
     * @param _twitter_xHandle The Twitter/X handle of the NFT owner.
     * @param _farcasterHandle The Farcaster handle of the NFT owner.
     * @param _telegramHandle The Telegram handle of the NFT owner.
     * @return tokenId The ID of the newly minted token.
     */
    function mint(
        address to,
        string memory _twitter_xHandle,
        string memory _farcasterHandle,
        string memory _telegramHandle
    )
        public
        onlyOwner
        nonLeadingAtSign(bytes(_twitter_xHandle))
        nonLeadingAtSign(bytes(_farcasterHandle))
        nonLeadingAtSign(bytes(_telegramHandle))
        returns (uint256)
    {
        uint256 tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        tokenMetadata[tokenId] = Metadata({
            twitter_xHandle: bytes(_twitter_xHandle).length == 0
                ? ""
                : _twitter_xHandle,
            farcasterHandle: bytes(_farcasterHandle).length == 0
                ? ""
                : _farcasterHandle,
            telegramHandle: bytes(_telegramHandle).length == 0
                ? ""
                : _telegramHandle,
            recievedAtTime: block.timestamp
        });
        emit Minted(to, tokenId, block.timestamp);

        return tokenId;
    }

    /**
     * @notice Mints multiple new soulbound NFTs with the provided social media handles.
     * @notice This function can only be called by the owner of the contract.
     * @param receivers The addresses to mint the NFTs to.
     * @param _twitter_xHandles The Twitter/X handles of the NFT owners.
     * @param _farcasterHandles The Farcaster handles of the NFT owners.
     * @param _telegramHandles The Telegram handles of the NFT owners.
     * @return The index of the last receiver, which got their soulbound NFT.
     */
    function batchMint(
        address[] memory receivers,
        string[] memory _twitter_xHandles,
        string[] memory _farcasterHandles,
        string[] memory _telegramHandles
    ) external onlyOwner returns (uint256) {
        if (
            receivers.length == 0 ||
            receivers.length != _twitter_xHandles.length ||
            receivers.length != _farcasterHandles.length ||
            receivers.length != _telegramHandles.length
        ) {
            revert SoulboundNFT__InvalidBatch();
        }
        uint256 totalReceivers = receivers.length;

        for (uint256 i = 0; i < totalReceivers; i++) {
            mint(
                receivers[i],
                _twitter_xHandles[i],
                _farcasterHandles[i],
                _telegramHandles[i]
            );
            if (gasleft() < MIN_GAS_PER_MINT) {
                return i;
            }
        }
        return receivers.length - 1;
    }

    /**
     * @notice Updates the Twitter/X handle of the soulbound NFT.
     * @notice This function can only be called by the owner of the token.
     *
     * @param tokenId The ID of the token to update.
     * @param _twitter_xHandle The new Twitter/X handle.
     */
    function updateTwitterXHandle(
        uint256 tokenId,
        string memory _twitter_xHandle
    ) external owns(tokenId) nonLeadingAtSign(bytes(_twitter_xHandle)) {
        bytes memory handleBytes = bytes(_twitter_xHandle);
        if (
            handleBytes.length == 0 ||
            handleBytes.length > TWITTER_USERNAME_MAX_LENGTH
        ) {
            revert SoulboundNFT__InvalidTwitterXHandle();
        }

        tokenMetadata[tokenId].twitter_xHandle = _twitter_xHandle;
    }

    /**
     * @notice Updates the Farcaster handle of the soulbound NFT.
     * @notice This function can only be called by the owner of the token.
     *
     * @param tokenId The ID of the token to update.
     * @param _farcasterHandle The new Farcaster handle.
     */
    function updateFarcasterHandle(
        uint256 tokenId,
        string memory _farcasterHandle
    ) external owns(tokenId) nonLeadingAtSign(bytes(_farcasterHandle)) {
        bytes memory handleBytes = bytes(_farcasterHandle);
        if (
            handleBytes.length == 0 ||
            handleBytes.length > FARCASTER_USERNAME_MAX_LENGTH
        ) {
            revert SoulboundNFT__InvalidFarcasterHandle();
        }

        tokenMetadata[tokenId].farcasterHandle = _farcasterHandle;
    }

    /**
     * @notice Updates the Telegram handle of the soulbound NFT.
     * @notice This function can only be called by the owner of the token.
     *
     * @param tokenId The ID of the token to update.
     * @param _telegramHandle The new Telegram handle.
     */
    function updateTelegramHandle(
        uint256 tokenId,
        string memory _telegramHandle
    ) external owns(tokenId) nonLeadingAtSign(bytes(_telegramHandle)) {
        bytes memory handleBytes = bytes(_telegramHandle);
        if (
            handleBytes.length < TELEGRAM_USERNAME_MIN_LENGTH ||
            handleBytes.length > TELEGRAM_USERNAME_MAX_LENGTH
        ) {
            revert SoulboundNFT__InvalidTelegramHandle();
        }

        tokenMetadata[tokenId].telegramHandle = _telegramHandle;
    }

    /**
     * @return The base URI for the token metadata.
     */
    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }

    /**
     * @notice Returns the token URI for the given token ID. Inludes metadata such as social media handles and the time the token was received, plus an SVG image.
     *
     * @param tokenId The ID of the token to get the URI for.
     * @return The token URI as a string.
     */
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        // string memory imageURI =
        Metadata memory _tokenMetadata = tokenMetadata[tokenId];
        string memory attributes = string.concat(
            '"attributes": ',
            '[{ "display_type": "date",  "trait_type": "recieved", "value": ',
            _tokenMetadata.recievedAtTime.toString()
        );
        if (bytes(_tokenMetadata.twitter_xHandle).length > 0) {
            attributes = string.concat(
                attributes,
                '}, { "trait_type": "twitter_x_handle", "value": "@',
                _tokenMetadata.twitter_xHandle,
                '"'
            );
        }
        if (bytes(_tokenMetadata.farcasterHandle).length > 0) {
            attributes = string.concat(
                attributes,
                '}, { "trait_type": "farcaster_handle", "value": "@',
                _tokenMetadata.farcasterHandle,
                '"'
            );
        }
        if (bytes(_tokenMetadata.telegramHandle).length > 0) {
            attributes = string.concat(
                attributes,
                '}, { "trait_type": "telegram_handle", "value": "@',
                _tokenMetadata.telegramHandle,
                '"'
            );
        }
        attributes = string.concat(attributes, "}]");

        return
            string.concat(
                _baseURI(),
                Base64.encode(
                    bytes(
                        string.concat(
                            '{"name": "',
                            name(),
                            '","description": "A badge of honour for based creators and supporters of the project castr.fun. Owners of this NFT have special privileges in the ecosystem.',
                            "\\n\\n",
                            unicode'⚠️ DISCLAIMER: This NFT is soulbound and cannot be transferred or sold. It is permanently bound to the address of the owner."',
                            ', "image": "',
                            image,
                            '", "animation_url": "',
                            animation,
                            '", "external_url": "https://castr.fun", ',
                            attributes,
                            "}"
                        )
                    )
                )
            );
    }
}
