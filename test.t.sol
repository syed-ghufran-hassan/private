pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BriVault} from "../src/briVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockErc20.t.sol";

contract AuditPoCTest is Test {
    uint256 public participationFeeBsp;
    uint256 public eventStartDate;
    uint256 public eventEndDate;
    address public participationFeeAddress;
    uint256 public minimumAmount;

    BriVault public briVault;
    MockERC20 public mockToken;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");

    string[48] countries = [
        "United States", "Canada", "Mexico", "Argentina", "Brazil", "Ecuador",
        "Uruguay", "Colombia", "Peru", "Chile", "Japan", "South Korea",
        "Australia", "Iran", "Saudi Arabia", "Qatar", "Uzbekistan", "Jordan",
        "France", "Germany", "Spain", "Portugal", "England", "Netherlands",
        "Italy", "Croatia", "Belgium", "Switzerland", "Denmark", "Poland",
        "Serbia", "Sweden", "Austria", "Morocco", "Senegal", "Nigeria",
        "Cameroon", "Egypt", "South Africa", "Ghana", "Algeria", "Tunisia",
        "Ivory Coast", "New Zealand", "Costa Rica", "Panama", "United Arab Emirates", "Iraq"
    ];

    function setUp() public {
        participationFeeBsp = 150; // 1.5%
        eventStartDate = block.timestamp + 2 days;
        eventEndDate = eventStartDate + 31 days;
        participationFeeAddress = makeAddr("participationFeeAddress");
        minimumAmount = 0.0002 ether;

        mockToken = new MockERC20("Mock Token", "MTK");

        // Mint balances
        mockToken.mint(owner, 100 ether);
        mockToken.mint(user1, 100 ether);
        mockToken.mint(user2, 100 ether);
        mockToken.mint(user3, 100 ether);

        // Deploy and initialize BriVault
        vm.startPrank(owner);
        briVault = new BriVault();
        
        // CRITICAL FIX: Initialize the contract
        briVault.initialize(
            address(mockToken),
            participationFeeBsp,
            eventStartDate,
            participationFeeAddress,
            minimumAmount,
            eventEndDate,
            owner
        );
        vm.stopPrank();
    }

    /// PoC-4: Multiple joinEvent calls inflate totalWinnerShares via duplicate addresses
    function test_poc4_multiple_joins_double_count_winner_shares() public {
        console.log("\n========== POC 4: MULTIPLE JOINS INFLATE WINNER SHARES ==========\n");
        
        // Set countries and pick a winner index
        vm.prank(owner);
        briVault.setCountry(countries);
        uint256 winnerIdx = 10; // Japan
        
        console.log("Winner country: Japan (index 10)");
        
        // User1 deposits and joins winner multiple times
        vm.startPrank(user1);
        mockToken.approve(address(briVault), type(uint256).max);
        briVault.deposit(5 ether, user1);
        
        console.log("\nUser1 deposits 5 ETH");
        console.log("User1 joins Japan - 1st time");
        briVault.joinEvent(winnerIdx);
        
        console.log("User1 joins Japan - 2nd time (VULNERABILITY!)");
        briVault.joinEvent(winnerIdx);
        
        console.log("User1 joins Japan - 3rd time (VULNERABILITY!)");
        briVault.joinEvent(winnerIdx);
        
        uint256 userShares = briVault.balanceOf(user1);
        console.log("\nUser1 total shares:", userShares);
        vm.stopPrank();

        // End event and set winner
        vm.warp(eventEndDate + 1);
        vm.prank(owner);
        briVault.setWinner(winnerIdx);

        console.log("\n=== VULNERABILITY DETECTED ===");
        console.log("User shares:", userShares);
        console.log("Total winner shares (inflated):", briVault.totalWinnerShares());
        console.log("User appears in usersAddress array multiple times!");
        
        // VULNERABILITY: totalWinnerShares counts user's shares MULTIPLE times
        // because user appears multiple times in usersAddress array
        // Each joinEvent() call pushes the same address to usersAddress
        assertEq(briVault.totalWinnerShares(), userShares * 3, "Winner shares tripled by multiple joins");

        // User1 withdraws - gets only 1/3 of what they should
        uint256 beforeBal = mockToken.balanceOf(user1);
        uint256 finalizedVault = briVault.finalizedVaultAsset();
        
        console.log("\n=== IMPACT ===");
        console.log("Finalized vault asset:", finalizedVault);
        console.log("Expected payout (if no vulnerability):", finalizedVault);
        console.log("Actual payout (reduced by 3x denominator):", finalizedVault / 3);
        
        vm.prank(user1);
        briVault.withdraw();
        
        uint256 afterBal = mockToken.balanceOf(user1);
        uint256 payout = afterBal - beforeBal;

        console.log("\nActual payout received:", payout);
        console.log("Loss due to vulnerability:", finalizedVault - payout);
        
        // Payout is reduced because totalWinnerShares is inflated 3x
        assertEq(payout, finalizedVault / 3, "Payout reduced by inflated denominator");
        
        console.log("\n  POC 4 Successful: User lost 2/3 of their rightful winnings!");
        console.log("   Root cause: Same user can join multiple times, inflating totalWinnerShares");
    }
    
 
}
