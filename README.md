0xfaaA795B8c074B8573E505CB4E5C415c90545fcF

```solidity
  
========== POC 4: MULTIPLE JOINS INFLATE WINNER SHARES ==========

  Winner country: Japan (index 10)
  
User1 deposits 5 ETH
  User1 joins Japan - 1st time
  User1 joins Japan - 2nd time (VULNERABILITY!)
  User1 joins Japan - 3rd time (VULNERABILITY!)
  
User1 total shares: 4925000000000000000
  
=== VULNERABILITY DETECTED ===
  User shares: 4925000000000000000
  Total winner shares (inflated): 14775000000000000000
  User appears in usersAddress array multiple times!
  
=== IMPACT ===
  Finalized vault asset: 4925000000000000000
  Expected payout (if no vulnerability): 4925000000000000000
  Actual payout (reduced by 3x denominator): 1641666666666666666
  
Actual payout received: 1641666666666666666
  Loss due to vulnerability: 3283333333333333334
  
  POC 4 Successful: User lost 2/3 of their rightful winnings!
     Root cause: Same user can join multiple times, inflating totalWinnerShares

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 8.04ms (2.43ms CPU time)


```

```solidity
 mapping(address => uint256) public userCountryId; 
    mapping(address => bool) public hasJoined; 

      require(userCountryId[msg.sender] == 0 && !hasJoined[msg.sender], "Already joined");

      ```
```
