#Looping Contracts

# Scope files:

src/StrategyManagerFactory.sol
src/StrategyManager.sol
src/Looping.sol
src/periphery/GluexAdapter.sol
src/periphery/LiquidSwapAdapter.sol

---

To open position:

- use flashloan to get debtAsset
- swap debtAsset to yieldAsset
- supply yieldAsset
- borrow debtAsset to repay flashloan

To close position:

- use flashloan to get debtAsset
- repay debt
- withdraw yieldAsset
- swap yieldAsset to debtAsset
- repay flashloan

---

Users must approve:

- `Looping` contract to spend the initial amount of `debtAsset`
- `Looping` contract to spend `VariableDebtToken` of `debtAsset` (using `approveDelegation`, so contract can borrow on behalf of the user).

---

## PositionsManager

Positions Manager keeps track of different leveraged positions.
