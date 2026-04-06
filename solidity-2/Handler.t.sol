// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {BurnableToken} from "src/BurnableToken.sol";
import {FeeAccount} from "src/FeeAccount.sol";
import {IWETH9} from "src/LiquidityMigrator.sol";
import {ISwapRouter} from "@velodrome-finance/slipstream/periphery/interfaces/ISwapRouter.sol";
import {Invariants} from "test/fuzz/Invariants.t.sol";

//Narrows down the way we call functioions

contract Handler is Test {
    ISwapRouter swapRouter;
    FeeAccount feeAccount;
    IWETH9 weth;
    BurnableToken burnableToken;
    Invariants invariant;

    address[] public holders;
    mapping(address holder => bool) isHolder;
    uint256 constant MAX_BUY_SIZE = 130e6 ether;
    address DEFAULT_RECEIVER = makeAddr("default_receiver");

    constructor(
        ISwapRouter _swapRouter,
        IWETH9 _weth,
        address _USER1,
        address _USER2,
        BurnableToken _burnableToken,
        FeeAccount _feeAccount,
        address _invariant
    ) {
        swapRouter = _swapRouter;
        weth = _weth;
        isHolder[_USER1] = true;
        isHolder[_USER2] = true;
        isHolder[_burnableToken.dev()] = true;
        holders.push(_USER1);
        holders.push(_USER2);
        burnableToken = _burnableToken;
        feeAccount = _feeAccount;
        invariant = Invariants(_invariant);

        address user = makeAddr("user3");
        vm.deal(user, 1000 ether);
        invariant.swapToken(1 ether, user, true);
        isHolder[user] = true;
        holders.push(user);
        user = makeAddr("user4");
        vm.deal(user, 1000 ether);
        invariant.swapToken(1 ether, user, true);
        isHolder[user] = true;
        holders.push(user);
        console2.log("balance token:", address(burnableToken).balance);
    }

    modifier holderExists() {
        if (holders.length == 0) {
            return;
        }
        _;
    }
    modifier supplyNotZero() {
        if (burnableToken.totalSupply() == 0) {
            return;
        }
        _;
    }
    modifier checkDividends() {
        invariant.checkTotalDividendsAndSetLastBalance();
        _;
        invariant.checkTotalDividendsAndSetLastBalance();
    }

    function buy(
        uint256 addressSeed,
        uint256 amount
    ) public holderExists checkDividends {
        (address holder, uint256 indexOfHolder) = _getHolderFromSeed(
            addressSeed
        );
        console2.log("ENTER buy", holder, amount);
        uint256 ethBalanceToken = invariant.getTokenBalance();
        console2.log("ethBalanceToken: ", ethBalanceToken);
        amount = bound(amount, 0.01 ether, MAX_BUY_SIZE);
        vm.deal(holder, amount);
        uint256 amountOut = invariant.swapToken(amount, holder, true);

        if (!isHolder[holder] && amountOut > 0) {
            isHolder[holder] = true;
            holders.push(holder);
            console2.log("holder", holder);
            console2.log("balanceOf", burnableToken.balanceOf(holder));
            console2.log(
                "balanceOf this",
                burnableToken.balanceOf(address(this))
            );
        }
    }

    function sell(
        uint256 addressSeed,
        uint256 amount
    ) public holderExists supplyNotZero checkDividends {
        (address holder, uint256 indexOfHolder) = _getHolderFromSeed(
            addressSeed
        );
        console2.log("ENTER sell", holder, amount);

        amount = bound(amount, 1, burnableToken.balanceOf(holder));
        invariant.swapToken(amount, holder, false);

        if (burnableToken.balanceOf(holder) == 0) {
            _removeHolder(indexOfHolder);
        }
    }

    function claimDividend(
        uint256 addressSeed
    ) public holderExists supplyNotZero checkDividends {
        (address holder, ) = _getHolderFromSeed(addressSeed);
        console2.log("ENTER claimDividend", holder);

        invariant.claimDividend(holder);
    }

    function collectFeesAndDistribute(
        address addressSeed
    ) public supplyNotZero checkDividends {
        console2.log("ENTER collectFeesAndDistribute", addressSeed);
        invariant.collectFeesAndDistribute(addressSeed);
    }

    function transfer(
        uint256 addressSeed,
        uint256 toSeed,
        uint256 amount
    ) public holderExists supplyNotZero checkDividends {
        (address to, ) = _getHolderFromSeed(toSeed);
        (address holder, uint256 indexOfHolder) = _getHolderFromSeed(
            addressSeed
        );
        if (to == holder) {
            to = DEFAULT_RECEIVER;
        }
        console2.log("ENTER transfer", holder, to, amount);
        amount = bound(amount, 1, burnableToken.balanceOf(holder));

        invariant.transfer(holder, to, amount);

        if (burnableToken.balanceOf(holder) == 0) {
            _removeHolder(indexOfHolder);
        }
        if (!isHolder[to]) {
            isHolder[to] = true;
            holders.push(to);
        }
    }

    function burn(
        uint256 addressSeed,
        uint256 amount
    ) public holderExists supplyNotZero checkDividends {
        (address holder, uint256 indexOfHolder) = _getHolderFromSeed(
            addressSeed
        );
        console2.log("ENTER burn", holder, amount);
        amount = bound(amount, 1, burnableToken.balanceOf(holder));

        vm.prank(holder);
        burnableToken.burn(amount);

        if (burnableToken.balanceOf(holder) == 0) {
            invariant.claimDividend(holder);
            _removeHolder(indexOfHolder);
        }
    }

    function _removeHolder(uint256 indexOfHolder) private {
        console2.log("remove holder", holders[indexOfHolder]);
        isHolder[holders[indexOfHolder]] = false;
        holders[indexOfHolder] = holders[holders.length - 1];
        holders.pop();
    }

    function _getHolderFromSeed(
        uint256 addressSeed
    ) private view returns (address, uint256) {
        uint256 indexOfHolder = addressSeed % holders.length;
        console2.log("indexOfHolder", indexOfHolder);

        return (holders[indexOfHolder], indexOfHolder);
    }

    function _getEtherBalance(address addressSeed) private returns (uint256) {
        return addressSeed == address(0) ? 0 : addressSeed.balance;
    }
}
