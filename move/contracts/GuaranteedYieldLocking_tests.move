#[test_only]
module aptree::GuaranteedYieldLocking_tests {
    use std::signer;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::timestamp;

    use aptree::GuaranteedYieldLocking;

    // ============================================
    // Test Constants
    // ============================================

    const ONE_MONTH: u64 = 2_592_000;
    const THREE_MONTHS: u64 = 7_776_000;
    const SIX_MONTHS: u64 = 15_552_000;
    const ONE_YEAR: u64 = 31_536_000;

    const DECIMALS: u64 = 100000000; // 8 decimals

    // ============================================
    // Setup Helpers
    // ============================================

    fun setup_test(aptos_framework: &signer, admin: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(admin));
        GuaranteedYieldLocking::init_for_testing(admin);
    }

    // ============================================
    // Tier Configuration Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test tier constants are correct
    fun test_tier_constants(aptos_framework: &signer, admin: &signer) {
        setup_test(aptos_framework, admin);

        assert!(GuaranteedYieldLocking::get_tier_starter() == 1, 1);
        assert!(GuaranteedYieldLocking::get_tier_bronze() == 2, 2);
        assert!(GuaranteedYieldLocking::get_tier_silver() == 3, 3);
        assert!(GuaranteedYieldLocking::get_tier_gold() == 4, 4);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test default tier configurations
    fun test_tier_configurations(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        // Starter: 1 month, 0.4%
        let (duration, yield_bps) = GuaranteedYieldLocking::get_tier_config(1);
        assert!(duration == ONE_MONTH, 1);
        assert!(yield_bps == 40, 2);

        // Bronze: 3 months, 1.25%
        let (duration, yield_bps) = GuaranteedYieldLocking::get_tier_config(2);
        assert!(duration == THREE_MONTHS, 3);
        assert!(yield_bps == 125, 4);

        // Silver: 6 months, 2.5%
        let (duration, yield_bps) = GuaranteedYieldLocking::get_tier_config(3);
        assert!(duration == SIX_MONTHS, 5);
        assert!(yield_bps == 250, 6);

        // Gold: 12 months, 5%
        let (duration, yield_bps) = GuaranteedYieldLocking::get_tier_config(4);
        assert!(duration == ONE_YEAR, 7);
        assert!(yield_bps == 500, 8);
    }

    // ============================================
    // Cashback Calculation Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test cashback calculation for each tier
    fun test_cashback_calculation(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let amount = 1000 * DECIMALS; // 1000 USDT

        // Starter: 0.4% of 1000 = 4 USDT
        let cashback = GuaranteedYieldLocking::calculate_cashback(amount, 1);
        assert!(cashback == 4 * DECIMALS, 1);

        // Bronze: 1.25% of 1000 = 12.5 USDT
        let cashback = GuaranteedYieldLocking::calculate_cashback(amount, 2);
        assert!(cashback == 125 * DECIMALS / 10, 2); // 12.5 USDT

        // Silver: 2.5% of 1000 = 25 USDT
        let cashback = GuaranteedYieldLocking::calculate_cashback(amount, 3);
        assert!(cashback == 25 * DECIMALS, 3);

        // Gold: 5% of 1000 = 50 USDT
        let cashback = GuaranteedYieldLocking::calculate_cashback(amount, 4);
        assert!(cashback == 50 * DECIMALS, 4);
    }

    #[test]
    /// Unit test for cashback calculation formula (uses u128 to prevent overflow)
    fun test_cashback_formula() {
        // cashback = (amount as u128 * yield_bps as u128 / 10000) as u64

        // 1000 USDT at 0.4% (40 bps)
        let amount: u64 = 1000 * 100000000;
        let yield_bps: u64 = 40;
        let cashback = (((amount as u128) * (yield_bps as u128)) / 10000) as u64;
        assert!(cashback == 4 * 100000000, 1); // 4 USDT

        // 5000 USDT at 2.5% (250 bps)
        let amount: u64 = 5000 * 100000000;
        let yield_bps: u64 = 250;
        let cashback = (((amount as u128) * (yield_bps as u128)) / 10000) as u64;
        assert!(cashback == 125 * 100000000, 2); // 125 USDT

        // 10000 USDT at 5% (500 bps)
        let amount: u64 = 10000 * 100000000;
        let yield_bps: u64 = 500;
        let cashback = (((amount as u128) * (yield_bps as u128)) / 10000) as u64;
        assert!(cashback == 500 * 100000000, 3); // 500 USDT
    }

    // ============================================
    // View Function Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test view functions return empty for non-existent user
    fun test_view_functions_empty(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let fake_user = @0x9999;

        let positions = GuaranteedYieldLocking::get_user_guaranteed_positions(fake_user);
        assert!(vector::length(&positions) == 0, 1);

        let is_unlockable = GuaranteedYieldLocking::is_position_unlockable(fake_user, 1);
        assert!(!is_unlockable, 2);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    #[expected_failure(abort_code = 303)]
    // EPOSITION_NOT_FOUND
    /// Test get_guaranteed_position fails for non-existent
    fun test_get_position_not_found(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let _ = GuaranteedYieldLocking::get_guaranteed_position(@0x9999, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test deposits are enabled by default
    fun test_deposits_enabled_default(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        assert!(GuaranteedYieldLocking::are_deposits_enabled(), 1);
    }

    // ============================================
    // Admin Function Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test admin can update tier yield
    fun test_admin_set_tier_yield(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        // Change Starter from 0.4% to 0.5%
        GuaranteedYieldLocking::set_tier_yield(admin, 1, 50);

        let yield_bps = GuaranteedYieldLocking::get_tier_guaranteed_yield(1);
        assert!(yield_bps == 50, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot update tier yield
    fun test_non_admin_cannot_set_yield(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::set_tier_yield(attacker, 1, 100);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test admin can disable deposits
    fun test_admin_disable_deposits(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        GuaranteedYieldLocking::set_deposits_enabled(admin, false);
        assert!(!GuaranteedYieldLocking::are_deposits_enabled(), 1);

        GuaranteedYieldLocking::set_deposits_enabled(admin, true);
        assert!(GuaranteedYieldLocking::are_deposits_enabled(), 2);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot disable deposits
    fun test_non_admin_cannot_disable_deposits(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::set_deposits_enabled(attacker, false);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test admin can set treasury
    fun test_admin_set_treasury(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let new_treasury = @0x12345;
        GuaranteedYieldLocking::set_treasury(admin, new_treasury);

        let treasury = GuaranteedYieldLocking::get_treasury();
        assert!(treasury == new_treasury, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot set treasury
    fun test_non_admin_cannot_set_treasury(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::set_treasury(attacker, @0x12345);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, new_admin = @0x99999)]
    /// Test two-step admin transfer: propose + accept
    fun test_two_step_admin_transfer(
        aptos_framework: &signer, admin: &signer, new_admin: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(new_admin));

        // Propose new admin
        GuaranteedYieldLocking::propose_admin(admin, @0x99999);

        // Accept as new admin
        GuaranteedYieldLocking::accept_admin(new_admin);

        // Old admin should now fail to set treasury
        // Verify new admin can operate
        GuaranteedYieldLocking::set_treasury(new_admin, @0x12345);
        let treasury = GuaranteedYieldLocking::get_treasury();
        assert!(treasury == @0x12345, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot propose admin
    fun test_non_admin_cannot_propose(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::propose_admin(attacker, @0x12345);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, wrong_acceptor = @0x888)]
    #[expected_failure(abort_code = 314)]
    // ENOT_PENDING_ADMIN
    /// Test wrong address cannot accept admin
    fun test_wrong_acceptor_fails(
        aptos_framework: &signer, admin: &signer, wrong_acceptor: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(wrong_acceptor));

        GuaranteedYieldLocking::propose_admin(admin, @0x99999);
        GuaranteedYieldLocking::accept_admin(wrong_acceptor);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, someone = @0x888)]
    #[expected_failure(abort_code = 315)]
    // ENO_PENDING_ADMIN
    /// Test accept_admin fails when no pending admin
    fun test_accept_admin_no_pending(
        aptos_framework: &signer, admin: &signer, someone: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(someone));

        GuaranteedYieldLocking::accept_admin(someone);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    #[expected_failure(abort_code = 310)]
    // EINVALID_ADDRESS
    /// Test propose admin with zero address fails
    fun test_propose_admin_zero_address(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        GuaranteedYieldLocking::propose_admin(admin, @0x0);
    }

    // ============================================
    // Error Code Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    #[expected_failure(abort_code = 302)]
    // EINVALID_TIER
    /// Test invalid tier 0
    fun test_invalid_tier_zero(aptos_framework: &signer, admin: &signer) {
        setup_test(aptos_framework, admin);

        let (_duration, _yield_bps) = GuaranteedYieldLocking::get_tier_config(0);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    #[expected_failure(abort_code = 302)]
    // EINVALID_TIER
    /// Test invalid tier 5
    fun test_invalid_tier_five(aptos_framework: &signer, admin: &signer) {
        setup_test(aptos_framework, admin);

        let (_duration, _yield_bps) = GuaranteedYieldLocking::get_tier_config(5);
    }

    // ============================================
    // Protocol Stats Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test initial protocol stats are zero
    fun test_initial_protocol_stats(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let (total_locked, total_aet, total_cashback, total_yield) =
            GuaranteedYieldLocking::get_protocol_stats();

        assert!(total_locked == 0, 1);
        assert!(total_aet == 0, 2);
        assert!(total_cashback == 0, 3);
        assert!(total_yield == 0, 4);
    }

    // ============================================
    // Calculation Unit Tests (Pure Logic)
    // ============================================

    #[test]
    /// Test protocol profit/loss calculation scenarios
    fun test_protocol_pnl_scenarios() {
        // Scenario 1: Protocol profit (actual > guaranteed)
        // User deposited 1000, got 25 cashback (2.5%)
        // MoneyFi returned 60 (6%)
        let cashback_paid: u64 = 25;
        let actual_yield: u64 = 60;

        let (pnl, is_profit) =
            if (actual_yield >= cashback_paid) {
                (actual_yield - cashback_paid, true)
            } else {
                (cashback_paid - actual_yield, false)
            };

        assert!(pnl == 35, 1); // 60 - 25 = 35 profit
        assert!(is_profit, 2);

        // Scenario 2: Protocol loss (actual < guaranteed)
        // User deposited 1000, got 50 cashback (5%)
        // MoneyFi returned 20 (2%)
        let cashback_paid: u64 = 50;
        let actual_yield: u64 = 20;

        let (pnl, is_profit) =
            if (actual_yield >= cashback_paid) {
                (actual_yield - cashback_paid, true)
            } else {
                (cashback_paid - actual_yield, false)
            };

        assert!(pnl == 30, 3); // 50 - 20 = 30 loss
        assert!(!is_profit, 4);

        // Scenario 3: Break-even
        let cashback_paid: u64 = 50;
        let actual_yield: u64 = 50;

        let (pnl, is_profit) =
            if (actual_yield >= cashback_paid) {
                (actual_yield - cashback_paid, true)
            } else {
                (cashback_paid - actual_yield, false)
            };

        assert!(pnl == 0, 5);
        assert!(is_profit, 6); // Zero profit is still "profit"
    }

    #[test]
    /// Test unlock payout calculation
    fun test_unlock_payout_scenarios() {
        let principal: u64 = 1000;

        // Scenario 1: MoneyFi has profit
        let current_value: u64 = 1080; // 8% yield

        let to_user =
            if (current_value >= principal) {
                principal
            } else {
                current_value
            };
        let to_treasury =
            if (current_value > principal) {
                current_value - principal
            } else { 0 };

        assert!(to_user == 1000, 1);
        assert!(to_treasury == 80, 2);

        // Scenario 2: MoneyFi has loss
        let current_value: u64 = 950; // -5% loss

        let to_user =
            if (current_value >= principal) {
                principal
            } else {
                current_value
            };
        let to_treasury =
            if (current_value > principal) {
                current_value - principal
            } else { 0 };

        assert!(to_user == 950, 3); // User gets less than principal
        assert!(to_treasury == 0, 4);

        // Scenario 3: Break-even
        let current_value: u64 = 1000;

        let to_user =
            if (current_value >= principal) {
                principal
            } else {
                current_value
            };
        let to_treasury =
            if (current_value > principal) {
                current_value - principal
            } else { 0 };

        assert!(to_user == 1000, 5);
        assert!(to_treasury == 0, 6);
    }

    // ============================================
    // Yield APY Equivalence Tests
    // ============================================

    #[test]
    /// Verify yield rates make sense as APY equivalents
    fun test_yield_apy_equivalence() {
        // Starter: 0.4% for 1 month ≈ 4.8% APY (0.4 * 12)
        // Bronze: 1.25% for 3 months ≈ 5% APY (1.25 * 4)
        // Silver: 2.5% for 6 months ≈ 5% APY (2.5 * 2)
        // Gold: 5% for 12 months = 5% APY

        // All roughly equivalent to ~5% APY, which makes sense
        // as they should be consistent incentives

        let starter_apy = 40 * 12; // 480 bps = 4.8%
        let bronze_apy = 125 * 4; // 500 bps = 5%
        let silver_apy = 250 * 2; // 500 bps = 5%
        let gold_apy = 500 * 1; // 500 bps = 5%

        // Starter is slightly lower APY as incentive for longer locks
        assert!(starter_apy == 480, 1);
        assert!(bronze_apy == 500, 2);
        assert!(silver_apy == 500, 3);
        assert!(gold_apy == 500, 4);
    }

    // ============================================
    // Treasury Validation Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    #[expected_failure(abort_code = 310)]
    // EINVALID_ADDRESS
    /// Test set_treasury rejects zero address
    fun test_treasury_zero_address_fails(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        GuaranteedYieldLocking::set_treasury(admin, @0x0);
    }

    // ============================================
    // Circuit Breaker Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test max total locked defaults to 0 (unlimited)
    fun test_max_total_locked_default(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let max_locked = GuaranteedYieldLocking::get_max_total_locked();
        assert!(max_locked == 0, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test admin can set max total locked
    fun test_admin_set_max_total_locked(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let new_max = 1000000 * DECIMALS; // 1M USDT
        GuaranteedYieldLocking::set_max_total_locked(admin, new_max);

        let max_locked = GuaranteedYieldLocking::get_max_total_locked();
        assert!(max_locked == new_max, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot set max total locked
    fun test_non_admin_cannot_set_max_locked(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::set_max_total_locked(attacker, 1000);
    }

    // ============================================
    // Minimum Deposit Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test min deposit defaults to 1 USDT
    fun test_min_deposit_default(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let min_deposit = GuaranteedYieldLocking::get_min_deposit();
        assert!(min_deposit == 1 * DECIMALS, 1); // 1 USDT
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test admin can set min deposit
    fun test_admin_set_min_deposit(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let new_min = 10 * DECIMALS; // 10 USDT
        GuaranteedYieldLocking::set_min_deposit(admin, new_min);

        let min_deposit = GuaranteedYieldLocking::get_min_deposit();
        assert!(min_deposit == new_min, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, attacker = @0x999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test non-admin cannot set min deposit
    fun test_non_admin_cannot_set_min_deposit(
        aptos_framework: &signer, admin: &signer, attacker: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(attacker));

        GuaranteedYieldLocking::set_min_deposit(attacker, 1000);
    }

    // ============================================
    // Emergency Unlock Clawback Calculation Tests
    // ============================================

    #[test]
    /// Test emergency unlock with clawback - vault has profit
    /// cv=1200, principal=1000, cashback=50
    /// base_payout = MIN(1000,1200) = 1000, clawback = 50, payout = 950
    fun test_emergency_unlock_clawback_vault_profit() {
        let principal: u64 = 1000;
        let current_value: u64 = 1200; // 20% gain
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        let (yield_forfeited, _loss_absorbed) =
            if (current_value > principal) {
                (current_value - principal, 0u64)
            } else if (current_value < principal) {
                (0u64, principal - current_value)
            } else {
                (0u64, 0u64)
            };

        assert!(payout == 950, 1); // User gets principal - cashback
        assert!(cashback_clawback == 50, 2); // Full cashback recovered
        assert!(yield_forfeited == 200, 3); // 200 yield stays in pool
    }

    #[test]
    /// Test emergency unlock with clawback - vault breakeven
    /// cv=1000, principal=1000, cashback=50
    /// base_payout = 1000, clawback = 50, payout = 950
    fun test_emergency_unlock_clawback_breakeven() {
        let principal: u64 = 1000;
        let current_value: u64 = 1000;
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        assert!(payout == 950, 1); // User gets principal - cashback
        assert!(cashback_clawback == 50, 2); // Full cashback recovered
    }

    #[test]
    /// Test emergency unlock with clawback - vault has small loss
    /// cv=900, principal=1000, cashback=50
    /// base_payout = 900, clawback = 50, payout = 850
    fun test_emergency_unlock_clawback_vault_loss() {
        let principal: u64 = 1000;
        let current_value: u64 = 900; // 10% loss
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        let (_yield_forfeited, loss_absorbed) =
            if (current_value > principal) {
                (current_value - principal, 0u64)
            } else if (current_value < principal) {
                (0u64, principal - current_value)
            } else {
                (0u64, 0u64)
            };

        assert!(payout == 850, 1); // User gets cv - cashback
        assert!(cashback_clawback == 50, 2); // Full cashback recovered
        assert!(loss_absorbed == 100, 3); // 100 loss absorbed
    }

    #[test]
    /// Test emergency unlock with clawback - vault has big loss (payout = 0)
    /// cv=30, principal=1000, cashback=50
    /// base_payout = 30, clawback = 30 (capped at base_payout), payout = 0
    fun test_emergency_unlock_clawback_big_loss() {
        let principal: u64 = 1000;
        let current_value: u64 = 30; // 97% loss
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        assert!(payout == 0, 1); // User gets nothing
        assert!(cashback_clawback == 30, 2); // Only 30 recovered (capped at base_payout)
        // Protocol lost 20 of the cashback (50 paid - 30 recovered)
    }

    #[test]
    /// Test emergency unlock with clawback - zero current value
    fun test_emergency_unlock_clawback_zero_value() {
        let principal: u64 = 1000;
        let current_value: u64 = 0; // Total loss
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        assert!(payout == 0, 1);
        assert!(cashback_clawback == 0, 2); // Nothing to recover
    }

    // ============================================
    // New Config Default Tests
    // ============================================

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test emergency unlock preview returns (0, 0, 0) for non-existent user
    fun test_emergency_preview_empty(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        let (payout, forfeited, clawback) =
            GuaranteedYieldLocking::get_emergency_unlock_preview(@0x9999, 1);
        assert!(payout == 0, 1);
        assert!(forfeited == 0, 2);
        assert!(clawback == 0, 3);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, new_admin = @0x99999)]
    #[expected_failure(abort_code = 305)]
    // ENOT_ADMIN
    /// Test old admin loses power after transfer
    fun test_old_admin_loses_power(
        aptos_framework: &signer, admin: &signer, new_admin: &signer
    ) {
        setup_test(aptos_framework, admin);
        account::create_account_for_test(signer::address_of(new_admin));

        GuaranteedYieldLocking::propose_admin(admin, @0x99999);
        GuaranteedYieldLocking::accept_admin(new_admin);

        // Old admin should fail
        GuaranteedYieldLocking::set_tier_yield(admin, 1, 100);
    }

    // ============================================
    // Overflow Protection Tests
    // ============================================

    #[test]
    /// Test cashback calculation doesn't overflow for large amounts
    /// 10M USDT at 5% should work: 10_000_000 * 100_000_000 * 500 = 5 * 10^17
    /// This overflows u64 (max ~1.8 * 10^19) without u128 intermediate
    fun test_cashback_no_overflow_large_amount() {
        let amount: u64 = 10_000_000 * 100000000; // 10M USDT (8 decimals)
        let yield_bps: u64 = 500; // 5%
        let bps_denom: u128 = 10000;

        // u128 intermediate prevents overflow
        let cashback = (((amount as u128) * (yield_bps as u128)) / bps_denom) as u64;

        // 10M * 5% = 500K USDT
        assert!(cashback == 500_000 * 100000000, 1);
    }

    #[test]
    /// Test cashback calculation for max realistic deposit (100M USDT)
    fun test_cashback_no_overflow_max_deposit() {
        let amount: u64 = 100_000_000 * 100000000; // 100M USDT (8 decimals)
        let yield_bps: u64 = 500; // 5%
        let bps_denom: u128 = 10000;

        // Would overflow u64: 100M * 10^8 * 500 = 5 * 10^18 (within u64)
        // But 100M * 10^8 = 10^16, * 500 = 5 * 10^18 < 1.8 * 10^19 (u64 max)
        // Actually this one barely fits u64, but using u128 is still safer
        let cashback = (((amount as u128) * (yield_bps as u128)) / bps_denom) as u64;

        assert!(cashback == 5_000_000 * 100000000, 1); // 5M USDT
    }

    #[test(aptos_framework = @0x1, admin = @aptree)]
    /// Test calculate_cashback view function with large amount
    fun test_calculate_cashback_large_amount(
        aptos_framework: &signer, admin: &signer
    ) {
        setup_test(aptos_framework, admin);

        // 10M USDT at Gold tier (5%)
        let amount = 10_000_000 * DECIMALS;
        let cashback = GuaranteedYieldLocking::calculate_cashback(amount, 4);
        assert!(cashback == 500_000 * DECIMALS, 1); // 500K USDT
    }

    // ============================================
    // Clawback Formula Comprehensive Tests
    // ============================================

    #[test]
    /// Test clawback formula: exact cashback equals current_value
    fun test_emergency_unlock_clawback_exact_match() {
        let principal: u64 = 1000;
        let current_value: u64 = 50; // Same as cashback
        let cashback_paid: u64 = 50;

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        assert!(payout == 0, 1); // User gets nothing (all goes to protocol)
        assert!(cashback_clawback == 50, 2); // Exact cashback recovered
    }

    #[test]
    /// Test clawback formula: no cashback was paid (tier 0 edge case)
    fun test_emergency_unlock_clawback_zero_cashback() {
        let principal: u64 = 1000;
        let current_value: u64 = 1100;
        let cashback_paid: u64 = 0; // No cashback paid

        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };
        let cashback_clawback =
            if (base_payout > cashback_paid) {
                cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        assert!(payout == 1000, 1); // User gets full principal
        assert!(cashback_clawback == 0, 2); // Nothing to claw back
    }
}
