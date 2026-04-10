// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BriVault {

    using SafeERC20 for IERC20;
    
    IERC20 public asset;
    
    uint256 public participationFeeBsp;

    uint256 constant BASE = 10000;
    uint256 constant PARTICIPATIONFEEBSPMAX = 300; 
    
    address private participationFeeAddress;

    uint256 public eventStartDate;
    uint256 public eventEndDate;
    uint256 public stakedAmount;
    uint256 public totalAssetsShares;
    string public winner;
    uint256 public finalizedVaultAsset;
    uint256 public totalWinnerShares;
    uint256 public totalParticipantShares;
    bool public _setWinner;
    uint256 public winnerCountryId;
    uint256 public minimumAmount; 
    uint256 public numberOfParticipants;
    string[48] public teams;
    address[] public usersAddress;

    // Track user balances
    mapping(address => uint256) public balances;
    mapping(address => uint256) public stakedAsset;
    mapping(address => string) public userToCountry;
    mapping(address => mapping(uint256 => uint256)) public userSharesToCountry;
    
    
    bool private _initialized;
    address public owner;

    // Error Logs
    error eventStarted();
    error lowFeeAndAmount();
    error invalidCountry();
    error eventNotEnded();
    error didNotWin();
    error notRegistered();
    error winnerNotSet();
    error noDeposit();
    error eventNotStarted();
    error WinnerAlreadySet();
    error limiteExceede();
    error AlreadyInitialized();
    error NotOwner();

    event deposited(address indexed _depositor, uint256 _value);
    event CountriesSet(string[48] country);
    event WinnerSet(string winnerSet);
    event joinedEvent(address user, uint256 _countryId);
    event Withdraw(address user, uint256 _amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier winnerSet() {
        if (_setWinner != true) {
            revert winnerNotSet();
        }
        _;
    }

    // Initialize function - call this after deployment
    function initialize(
        address _asset,
        uint256 _participationFeeBsp,
        uint256 _eventStartDate,
        address _participationFeeAddress,
        uint256 _minimumAmount,
        uint256 _eventEndDate,
        address _owner
    ) external {
        require(!_initialized, "Already initialized");
        
        if (_participationFeeBsp > PARTICIPATIONFEEBSPMAX) {
            revert limiteExceede();
        }
        
        owner = _owner;
        asset = IERC20(_asset);
        participationFeeBsp = _participationFeeBsp;
        eventStartDate = _eventStartDate;
        eventEndDate = _eventEndDate;
        participationFeeAddress = _participationFeeAddress;
        minimumAmount = _minimumAmount;
        _setWinner = false;
        _initialized = true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ERC20 replacement functions
    function totalSupply() public view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < usersAddress.length; i++) {
            total += balances[usersAddress[i]];
        }
        return total;
    }

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    function _mint(address account, uint256 amount) internal {
        balances[account] += amount;
    }

    function _burn(address account, uint256 amount) internal {
        balances[account] -= amount;
    }

    /**----------------------------- Admin Functions ----------------------------------- */

    function setCountry(string[48] memory countries) public onlyOwner {
        for (uint256 i = 0; i < countries.length; ++i) {
            teams[i] = countries[i];
        }
        emit CountriesSet(countries);
    }

    function setWinner(uint256 countryIndex) public onlyOwner returns (string memory) {
        if (block.timestamp <= eventEndDate) {
            revert eventNotEnded();
        }

        require(countryIndex < teams.length, "Invalid country index");

        if (_setWinner) {
            revert WinnerAlreadySet();
        }

        winnerCountryId = countryIndex;
        winner = teams[countryIndex];

        _setWinner = true;

        _getWinnerShares();
        _setFinallizedVaultBalance();

        emit WinnerSet(winner);
        
        return winner;
    }

    function _setFinallizedVaultBalance() internal returns (uint256) {
        if (block.timestamp <= eventStartDate) {
            revert eventNotStarted();
        }

        return finalizedVaultAsset = asset.balanceOf(address(this));
    }

    function _convertToShares(uint256 assets) internal view returns (uint256 shares) {
        uint256 balanceOfVault = asset.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0 || balanceOfVault == 0) {
            return assets;
        }

        shares = Math.mulDiv(assets, totalShares, balanceOfVault);
    }

    function getWinner() public view returns (string memory) {
        return winner;
    }

    function getCountry(uint256 countryId) external view returns (string memory) {
        if (bytes(teams[countryId]).length == 0) {
            revert invalidCountry();
        }

        return teams[countryId];
    }

    function _getWinnerShares() internal returns (uint256) {
        for (uint256 i = 0; i < usersAddress.length; ++i) {
            address user = usersAddress[i]; 
            totalWinnerShares += userSharesToCountry[user][winnerCountryId];
        }
        return totalWinnerShares;
    }

    function _getParticipationFee(uint256 assets) internal view returns (uint256) {
        return (assets * participationFeeBsp) / BASE;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        require(receiver != address(0));

        if (block.timestamp >= eventStartDate) {
            revert eventStarted();
        }

        uint256 fee = _getParticipationFee(assets);
        
        if (minimumAmount + fee > assets) {
            revert lowFeeAndAmount();
        }

        uint256 stakeAsset = assets - fee;
        stakedAsset[receiver] = stakeAsset;
        uint256 participantShares = _convertToShares(stakeAsset);

        asset.safeTransferFrom(msg.sender, participationFeeAddress, fee);
        asset.safeTransferFrom(msg.sender, address(this), stakeAsset);

        _mint(msg.sender, participantShares);

        emit deposited(receiver, stakeAsset);

        return participantShares;
    }

    function joinEvent(uint256 countryId) public {
        if (stakedAsset[msg.sender] == 0) {
            revert noDeposit();
        }

       

        if (countryId >= teams.length) {
            revert invalidCountry();
        }

        if (block.timestamp > eventStartDate) {
            revert eventStarted();
        }

        userToCountry[msg.sender] = teams[countryId];
        
        uint256 participantShares = balanceOf(msg.sender);
        userSharesToCountry[msg.sender][countryId] = participantShares;

        usersAddress.push(msg.sender);
        numberOfParticipants++;
        totalParticipantShares += participantShares;

        emit joinedEvent(msg.sender, countryId);
    }

    function cancelParticipation() public {
        if (block.timestamp >= eventStartDate) {
            revert eventStarted();
        }

        uint256 refundAmount = stakedAsset[msg.sender];
        stakedAsset[msg.sender] = 0;

        uint256 shares = balanceOf(msg.sender);
        _burn(msg.sender, shares);

        asset.safeTransfer(msg.sender, refundAmount);
    }

    function withdraw() external winnerSet {
        if (block.timestamp < eventEndDate) {
            revert eventNotEnded();
        }

        if (
            keccak256(abi.encodePacked(userToCountry[msg.sender])) !=
            keccak256(abi.encodePacked(winner))
        ) {
            revert didNotWin();
        }
        
        uint256 shares = balanceOf(msg.sender);
        uint256 vaultAsset = finalizedVaultAsset;
        uint256 assetToWithdraw = Math.mulDiv(shares, vaultAsset, totalWinnerShares);
        
        _burn(msg.sender, shares);
        asset.safeTransfer(msg.sender, assetToWithdraw);

        emit Withdraw(msg.sender, assetToWithdraw);
    }
}
