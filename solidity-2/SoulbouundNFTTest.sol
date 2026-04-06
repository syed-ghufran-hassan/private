// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SoulboundNFT} from "src/SoulboundNFT.sol";

contract SoulboundNFTTest is Test {
    string constant TWITTER_HANDLE = "twitter_handle";
    string constant FARCASTER_HANDLE = "farcaster_handle";
    string constant TELEGRAM_HANDLE = "telegram_handle";
    string constant NEW_HANDLE = "new_handle";
    string constant EMPTY_HANDLE = "";
    string constant INVALID_HANDLE =
        "invalid_handle_too_long_12345678901234567890";
    string constant URI_ALL_SOCIALS =
        "data:application/json;base64,eyJuYW1lIjogIkJhc2VkIENhc3RlcnMiLCJkZXNjcmlwdGlvbiI6ICJBIGJhZGdlIG9mIGhvbm91ciBmb3IgYmFzZWQgY3JlYXRvcnMgYW5kIHN1cHBvcnRlcnMgb2YgdGhlIHByb2plY3QgY2FzdHIuZnVuLiBPd25lcnMgb2YgdGhpcyBORlQgaGF2ZSBzcGVjaWFsIHByaXZpbGVnZXMgaW4gdGhlIGVjb3N5c3RlbS5cblxu4pqg77iPIERJU0NMQUlNRVI6IFRoaXMgTkZUIGlzIHNvdWxib3VuZCBhbmQgY2Fubm90IGJlIHRyYW5zZmVycmVkIG9yIHNvbGQuIEl0IGlzIHBlcm1hbmVudGx5IGJvdW5kIHRvIHRoZSBhZGRyZXNzIG9mIHRoZSBvd25lci4iLCAiaW1hZ2UiOiAiaXBmcy9pbWFnZS5naWYiLCAiYW5pbWF0aW9uX3VybCI6ICJpcGZzL2FuaW1hdGlvbi5tcDQiLCAiZXh0ZXJuYWxfdXJsIjogImh0dHBzOi8vY2FzdHIuZnVuIiwgImF0dHJpYnV0ZXMiOiBbeyAiZGlzcGxheV90eXBlIjogImRhdGUiLCAgInRyYWl0X3R5cGUiOiAicmVjaWV2ZWQiLCAidmFsdWUiOiAxNzUxNDkyNDY1fSwgeyAidHJhaXRfdHlwZSI6ICJ0d2l0dGVyX3hfaGFuZGxlIiwgInZhbHVlIjogIkB0d2l0dGVyX2hhbmRsZSJ9LCB7ICJ0cmFpdF90eXBlIjogImZhcmNhc3Rlcl9oYW5kbGUiLCAidmFsdWUiOiAiQGZhcmNhc3Rlcl9oYW5kbGUifSwgeyAidHJhaXRfdHlwZSI6ICJ0ZWxlZ3JhbV9oYW5kbGUiLCAidmFsdWUiOiAiQHRlbGVncmFtX2hhbmRsZSJ9XX0=";
    string constant URI_NO_SOCIALS =
        "data:application/json;base64,eyJuYW1lIjogIkJhc2VkIENhc3RlcnMiLCJkZXNjcmlwdGlvbiI6ICJBIGJhZGdlIG9mIGhvbm91ciBmb3IgYmFzZWQgY3JlYXRvcnMgYW5kIHN1cHBvcnRlcnMgb2YgdGhlIHByb2plY3QgY2FzdHIuZnVuLiBPd25lcnMgb2YgdGhpcyBORlQgaGF2ZSBzcGVjaWFsIHByaXZpbGVnZXMgaW4gdGhlIGVjb3N5c3RlbS5cblxu4pqg77iPIERJU0NMQUlNRVI6IFRoaXMgTkZUIGlzIHNvdWxib3VuZCBhbmQgY2Fubm90IGJlIHRyYW5zZmVycmVkIG9yIHNvbGQuIEl0IGlzIHBlcm1hbmVudGx5IGJvdW5kIHRvIHRoZSBhZGRyZXNzIG9mIHRoZSBvd25lci4iLCAiaW1hZ2UiOiAiaXBmcy9pbWFnZS5naWYiLCAiYW5pbWF0aW9uX3VybCI6ICJpcGZzL2FuaW1hdGlvbi5tcDQiLCAiZXh0ZXJuYWxfdXJsIjogImh0dHBzOi8vY2FzdHIuZnVuIiwgImF0dHJpYnV0ZXMiOiBbeyAiZGlzcGxheV90eXBlIjogImRhdGUiLCAgInRyYWl0X3R5cGUiOiAicmVjaWV2ZWQiLCAidmFsdWUiOiAxNzUxNDkyNDY1fV19";
    uint256 constant TIMESTAMP = 1751492465; // Example timestamp for testing
    SoulboundNFT soulboundNFT;
    address OWNER = makeAddr("owner");
    address USER = makeAddr("user");

    function setUp() public {
        vm.prank(OWNER);
        soulboundNFT = new SoulboundNFT(
            "Based Casters",
            "BCAST",
            "ipfs/image.gif",
            "ipfs/animation.mp4"
        );
    }

    function testOwner() external view {
        assertEq(soulboundNFT.owner(), OWNER);
    }

    function testMint() public returns (uint256 tokenId) {
        vm.prank(OWNER);
        tokenId = soulboundNFT.mint(
            USER,
            TWITTER_HANDLE,
            FARCASTER_HANDLE,
            TELEGRAM_HANDLE
        );
        assertEq(soulboundNFT.ownerOf(tokenId), USER);
    }

    function testMintRevertsOnInvalidHandleTwitter() external {
        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__LeadingAtSignNotAllowed.selector
        );
        vm.prank(OWNER);
        soulboundNFT.mint(
            USER,
            "@invalid_handle",
            FARCASTER_HANDLE,
            TELEGRAM_HANDLE
        );
    }

    function testMintRevertsOnInvalidHandleFarcaster() external {
        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__LeadingAtSignNotAllowed.selector
        );
        vm.prank(OWNER);
        soulboundNFT.mint(
            USER,
            TWITTER_HANDLE,
            "@invalid_handle",
            TELEGRAM_HANDLE
        );
    }

    function testMintRevertsOnInvalidHandleTelegram() external {
        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__LeadingAtSignNotAllowed.selector
        );
        vm.prank(OWNER);
        soulboundNFT.mint(
            USER,
            TWITTER_HANDLE,
            FARCASTER_HANDLE,
            "@invalid_handle"
        );
    }

    function testMintRevertsIfNotOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        soulboundNFT.mint(
            USER,
            TWITTER_HANDLE,
            FARCASTER_HANDLE,
            TELEGRAM_HANDLE
        );
    }

    function testTransferFromReverts() external {
        uint256 tokenId = testMint();

        vm.expectRevert(SoulboundNFT.SoulboundNFT__NotTransferable.selector);
        vm.prank(USER);
        soulboundNFT.transferFrom(USER, OWNER, tokenId);
    }

    function testApproveReverts() external {
        uint256 tokenId = testMint();

        vm.expectRevert(SoulboundNFT.SoulboundNFT__NotTransferable.selector);
        vm.prank(USER);
        soulboundNFT.approve(OWNER, tokenId);
    }

    function testSetApprovalForAllReverts() external {
        testMint();

        vm.expectRevert(SoulboundNFT.SoulboundNFT__NotTransferable.selector);
        vm.prank(USER);
        soulboundNFT.setApprovalForAll(OWNER, true);
    }

    function testUpdateTwitterXHandle() external {
        uint256 tokenId = testMint();
        string memory expectedTwitterHandle = NEW_HANDLE;
        (string memory oldTwitterHandle, , , ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        vm.prank(USER);
        soulboundNFT.updateTwitterXHandle(tokenId, expectedTwitterHandle);
        (string memory newTwitterHandle, , , ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        assertNotEq(newTwitterHandle, oldTwitterHandle);
        assertEq(newTwitterHandle, expectedTwitterHandle);
    }

    function testUpdateFarcasterHandle() external {
        uint256 tokenId = testMint();
        string memory expectedFarcasterHandle = NEW_HANDLE;
        (, string memory oldFarcasterHandle, , ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        vm.prank(USER);
        soulboundNFT.updateFarcasterHandle(tokenId, expectedFarcasterHandle);
        (, string memory newFarcasterHandle, , ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        assertNotEq(newFarcasterHandle, oldFarcasterHandle);
        assertEq(newFarcasterHandle, expectedFarcasterHandle);
    }

    function testUpdateTelegramHandle() external {
        uint256 tokenId = testMint();
        string memory expectedTelegramHandle = NEW_HANDLE;
        (, , string memory oldTelegramHandle, ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        vm.prank(USER);
        soulboundNFT.updateTelegramHandle(tokenId, expectedTelegramHandle);
        (, , string memory newTelegramHandle, ) = soulboundNFT.tokenMetadata(
            tokenId
        );

        assertNotEq(newTelegramHandle, oldTelegramHandle);
        assertEq(newTelegramHandle, expectedTelegramHandle);
    }

    function testUpdateTwitterXHandleRevertsIfNotOwner() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            abi.encodeWithSelector(
                SoulboundNFT.SoulboundNFT__NotOwnerOf.selector,
                tokenId
            )
        );
        soulboundNFT.updateTwitterXHandle(tokenId, NEW_HANDLE);
    }

    function testUpdateFarcasterHandleRevertsIfNotOwner() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            abi.encodeWithSelector(
                SoulboundNFT.SoulboundNFT__NotOwnerOf.selector,
                tokenId
            )
        );
        soulboundNFT.updateFarcasterHandle(tokenId, NEW_HANDLE);
    }

    function testUpdateTelegramHandleRevertsIfNotOwner() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            abi.encodeWithSelector(
                SoulboundNFT.SoulboundNFT__NotOwnerOf.selector,
                tokenId
            )
        );
        soulboundNFT.updateTelegramHandle(tokenId, NEW_HANDLE);
    }

    function testUpdateTwitterXHandleRevertsIfInvalidHandle() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__InvalidTwitterXHandle.selector
        );
        vm.prank(USER);
        soulboundNFT.updateTwitterXHandle(tokenId, INVALID_HANDLE);
    }

    function testUpdateFarcasterHandleRevertsIfInvalidHandle() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__InvalidFarcasterHandle.selector
        );
        vm.prank(USER);
        soulboundNFT.updateFarcasterHandle(tokenId, INVALID_HANDLE);
    }

    function testUpdateTelegramHandleRevertsIfInvalidHandle() external {
        uint256 tokenId = testMint();

        vm.expectRevert(
            SoulboundNFT.SoulboundNFT__InvalidTelegramHandle.selector
        );
        vm.prank(USER);
        soulboundNFT.updateTelegramHandle(tokenId, INVALID_HANDLE);
    }

    function testTokenURIAllSocials() external {
        vm.warp(TIMESTAMP);
        vm.roll(block.number + 1);
        uint256 tokenId = testMint();

        assertEq(soulboundNFT.tokenURI(tokenId), URI_ALL_SOCIALS);
    }

    function testTokenURINoSocials() external {
        vm.warp(TIMESTAMP);
        vm.roll(block.number + 1);
        vm.prank(OWNER);
        uint256 tokenId = soulboundNFT.mint(
            USER,
            EMPTY_HANDLE,
            EMPTY_HANDLE,
            EMPTY_HANDLE
        );

        assertEq(soulboundNFT.tokenURI(tokenId), URI_NO_SOCIALS);
    }

    function testBatchMint() external {
        uint256 size = 10000;
        address[] memory receivers = new address[](size);
        string[] memory handles = new string[](size);
        for (uint256 i = 0; i < size; i++) {
            receivers[i] = (USER);
            handles[i] = (NEW_HANDLE);
        }
        vm.prank(OWNER);
        uint256 lastIndex = soulboundNFT.batchMint(
            receivers,
            handles,
            handles,
            handles
        );
        assertGt(lastIndex, 0);
    }

    function testBatchMintRevertsOnInvalidBatch() external {
        address[] memory receivers = new address[](1);
        string[] memory handles = new string[](2);
        receivers[0] = USER;
        handles[0] = NEW_HANDLE;
        handles[1] = FARCASTER_HANDLE;
        vm.expectRevert(SoulboundNFT.SoulboundNFT__InvalidBatch.selector);
        vm.prank(OWNER);
        soulboundNFT.batchMint(receivers, handles, handles, handles);
    }
}
