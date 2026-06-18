```solidity

dd this test contract to test/vault/AerodromeDestinationVault.t.sol after line 571 (after AerodromeCollectRewards). AerodromeDestinationVault.t.sol:571


contract GaugeKilledPostInitialization is AerodromeDestinationVaultBaseTest {  
    function setUp() public virtual override {  
        super.setUp();  
        // Deposit LP tokens while gauge is alive  
        _runDVDeposit(1e18);  
    }  
  
    function test_RevertIf_WithdrawalWhenGaugeKilled() public {  
        // Expected: Withdrawal succeeds when gauge is alive  
        // Actual: Withdrawal reverts when gauge is killed, locking funds  
          
        uint256 gaugeBalanceBefore = _aeroGauge.balanceOf(address(_dv));  
        assertGt(gaugeBalanceBefore, 0, "Funds should be staked in gauge");  
  
        // Simulate Aerodrome governance killing the gauge  
        vm.mockCall(  
            AERODROME_VOTER_BASE,  
            abi.encodeWithSelector(IVoter.isAlive.selector, address(_aeroGauge)),  
            abi.encode(false)  
        );  
  
        // Mock gauge.withdraw to revert with specific error (simulating killed gauge behavior)  
        vm.mockCall(  
            address(_aeroGauge),  
            abi.encodeWithSelector(IAerodromeGauge.withdraw.selector),  
            abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled")  
        );  
  
        // Attempt to withdraw - should revert because gauge is killed  
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled"));  
        _dv.withdrawUnderlying(1e18, address(this));  
  
        // Verify funds remain locked in gauge (impact assertion)  
        uint256 gaugeBalanceAfter = _aeroGauge.balanceOf(address(_dv));  
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Funds remain stuck in killed gauge");  
    }  
  
    function test_RevertIf_DepositWhenGaugeKilled() public {  
        // Expected: Deposit succeeds when gauge is alive  
        // Actual: Deposit reverts when gauge is killed, preventing new deposits  
          
        // Simulate Aerodrome governance killing the gauge  
        vm.mockCall(  
            AERODROME_VOTER_BASE,  
            abi.encodeWithSelector(IVoter.isAlive.selector, address(_aeroGauge)),  
            abi.encode(false)  
        );  
  
        // Mock gauge.deposit to revert with specific error (simulating killed gauge behavior)  
        vm.mockCall(  
            address(_aeroGauge),  
            abi.encodeWithSelector(IAerodromeGauge.deposit.selector, 1e18),  
            abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled")  
        );  
  
        // Attempt new deposit - should revert because gauge is killed  
        _dealLP(address(this));  
        _approveUnderlyer(address(_dv));  
        _mockIsVault();  
  
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled"));  
        _dv.depositUnderlying(1e18);  
    }  
  
    function test_RevertIf_ensureLocalUnderlyingBalanceWhenGaugeKilled() public {  
        // Expected: Unstake succeeds when gauge is alive  
        // Actual: Unstake reverts when gauge is killed, preventing withdrawals  
          
        uint256 gaugeBalanceBefore = _aeroGauge.balanceOf(address(_dv));  
        assertGt(gaugeBalanceBefore, 0, "Funds should be staked in gauge");  
  
        // Simulate Aerodrome governance killing the gauge  
        vm.mockCall(  
            AERODROME_VOTER_BASE,  
            abi.encodeWithSelector(IVoter.isAlive.selector, address(_aeroGauge)),  
            abi.encode(false)  
        );  
  
        // Mock gauge.withdraw to revert with specific error (simulating killed gauge behavior)  
        vm.mockCall(  
            address(_aeroGauge),  
            abi.encodeWithSelector(IAerodromeGauge.withdraw.selector),  
            abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled")  
        );  
  
        // Direct call to unstake function - should revert  
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidParam.selector, "GaugeKilled"));  
        _dv.ensureLocalUnderlyingBalance(1e18);  
  
        // Verify funds remain locked in gauge (impact assertion)  
        uint256 gaugeBalanceAfter = _aeroGauge.balanceOf(address(_dv));  
        assertEq(gaugeBalanceAfter, gaugeBalanceBefore, "Funds remain stuck in killed gauge");  
    }  
}
```
