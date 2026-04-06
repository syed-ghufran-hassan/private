/// Mock MoneyFi Vault for Testing
///
/// This module provides a tunable mock implementation of the MoneyFi vault
/// interface for testing the APTree Earn contracts without requiring the
/// actual MoneyFi deployment.
///
/// Key Features:
/// - Tunable yield simulation (set share price multiplier)
/// - Deposit/withdrawal tracking
/// - Configurable withdrawal delays
/// - Test helpers for various scenarios
module moneyfi_mock::vault {
    use std::signer::address_of;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;

    // ============================================
    // Constants
    // ============================================

    const SEED: vector<u8> = b"MockMoneyFiVault";

    /// Precision for yield calculations (10^9)
    const YIELD_PRECISION: u128 = 1_000_000_000;

    // ============================================
    // Errors
    // ============================================

    const ENOT_INITIALIZED: u64 = 1;
    const EINSUFFICIENT_BALANCE: u64 = 2;
    const ENO_PENDING_WITHDRAWAL: u64 = 3;
    const ENOT_ADMIN: u64 = 4;

    // ============================================
    // Structs
    // ============================================

    /// Mock vault state - tunable for testing
    struct MockVaultState has key {
        /// Signer capability for vault operations
        signer_cap: SignerCapability,

        /// Total deposits received (before yield)
        total_deposits: u64,

        /// Yield multiplier in basis points (10000 = 1x, 11000 = 1.1x, 9000 = 0.9x)
        /// This simulates vault performance
        yield_multiplier_bps: u64,

        /// Pending withdrawal requests per user (simplified: one per address)
        /// In production MoneyFi this would be more complex
        pending_withdrawals: u64,

        /// Admin address for tuning
        admin: address
    }

    /// Per-depositor tracking
    struct DepositorState has key {
        /// Amount deposited by this address
        deposited: u64,
        /// Pending withdrawal amount
        pending_withdrawal: u64
    }

    // ============================================
    // Init - Called automatically or manually for tests
    // ============================================

    fun init_module(admin: &signer) {
        let (vault_signer, signer_cap) = account::create_resource_account(admin, SEED);

        let state = MockVaultState {
            signer_cap,
            total_deposits: 0,
            yield_multiplier_bps: 10000, // 1x = no yield initially
            pending_withdrawals: 0,
            admin: address_of(admin)
        };

        move_to(&vault_signer, state);
    }

    // ============================================
    // Core Vault Interface (matches MoneyFi)
    // ============================================

    /// Deposit tokens into the vault
    /// In real MoneyFi, this would invest in yield strategies
    public entry fun deposit(
        depositor: &signer, token: Object<Metadata>, amount: u64
    ) acquires MockVaultState, DepositorState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);

        // Transfer tokens to vault
        primary_fungible_store::transfer(depositor, token, vault_address, amount);

        // Track deposit
        state.total_deposits = state.total_deposits + amount;

        // Track per-depositor
        let depositor_addr = address_of(depositor);
        if (!exists<DepositorState>(depositor_addr)) {
            move_to(
                depositor,
                DepositorState { deposited: amount, pending_withdrawal: 0 }
            );
        } else {
            let depositor_state = borrow_global_mut<DepositorState>(depositor_addr);
            depositor_state.deposited = depositor_state.deposited + amount;
        };
    }

    /// Request a withdrawal from the vault
    /// In real MoneyFi, this queues the withdrawal for processing
    public entry fun request_withdraw(
        depositor: &signer, _token: Object<Metadata>, amount: u64
    ) acquires MockVaultState, DepositorState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);

        // Track pending withdrawal
        state.pending_withdrawals = state.pending_withdrawals + amount;

        // Track per-depositor
        let depositor_addr = address_of(depositor);
        if (!exists<DepositorState>(depositor_addr)) {
            move_to(
                depositor,
                DepositorState { deposited: 0, pending_withdrawal: amount }
            );
        } else {
            let depositor_state = borrow_global_mut<DepositorState>(depositor_addr);
            depositor_state.pending_withdrawal =
                depositor_state.pending_withdrawal + amount;
        };
    }

    /// Complete a withdrawal request
    /// In real MoneyFi, this would process queued withdrawals
    public entry fun withdraw_requested_amount(
        depositor: &signer, token: Object<Metadata>
    ) acquires MockVaultState, DepositorState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        let vault_signer = account::create_signer_with_capability(&state.signer_cap);

        let depositor_addr = address_of(depositor);
        assert!(exists<DepositorState>(depositor_addr), ENO_PENDING_WITHDRAWAL);

        let depositor_state = borrow_global_mut<DepositorState>(depositor_addr);
        let amount = depositor_state.pending_withdrawal;
        assert!(amount > 0, ENO_PENDING_WITHDRAWAL);

        // Transfer tokens back to depositor
        primary_fungible_store::transfer(&vault_signer, token, depositor_addr, amount);

        // Update state
        state.pending_withdrawals = state.pending_withdrawals - amount;
        state.total_deposits =
            if (state.total_deposits >= amount) {
                state.total_deposits - amount
            } else { 0 };
        depositor_state.pending_withdrawal = 0;
        depositor_state.deposited =
            if (depositor_state.deposited >= amount) {
                depositor_state.deposited - amount
            } else { 0 };
    }

    /// Estimate total fund value for a depositor
    /// This is the key function for share price calculation
    ///
    /// Returns: total_deposits * yield_multiplier
    ///
    /// Example:
    /// - Deposited 1000, multiplier 10000 (1x) -> returns 1000
    /// - Deposited 1000, multiplier 11000 (1.1x) -> returns 1100 (10% yield)
    /// - Deposited 1000, multiplier 9500 (0.95x) -> returns 950 (5% loss)
    #[view]
    public fun estimate_total_fund_value(
        _depositor: address, _token: Object<Metadata>
    ): u64 acquires MockVaultState {
        let vault_address = get_vault_address();

        if (!exists<MockVaultState>(vault_address)) {
            return 0
        };

        let state = borrow_global<MockVaultState>(vault_address);

        // Apply yield multiplier to total deposits
        let value =
            ((state.total_deposits as u128) * (state.yield_multiplier_bps as u128)
                / 10000) as u64;

        value
    }

    /// Get the vault address
    #[view]
    public fun get_vault_address(): address {
        account::create_resource_address(&@moneyfi_mock, SEED)
    }

    // ============================================
    // Test Tuning Functions
    // ============================================

    /// Set the yield multiplier (admin only)
    ///
    /// multiplier_bps:
    /// - 10000 = 1.0x (no change)
    /// - 11000 = 1.1x (10% yield)
    /// - 12000 = 1.2x (20% yield)
    /// - 9000 = 0.9x (10% loss)
    /// - 8000 = 0.8x (20% loss)
    public entry fun set_yield_multiplier(
        admin: &signer, multiplier_bps: u64
    ) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        assert!(address_of(admin) == state.admin, ENOT_ADMIN);

        state.yield_multiplier_bps = multiplier_bps;
    }

    /// Simulate yield by adding a percentage
    ///
    /// yield_bps: yield in basis points (100 = 1%, 1000 = 10%)
    public entry fun simulate_yield(admin: &signer, yield_bps: u64) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        assert!(address_of(admin) == state.admin, ENOT_ADMIN);

        // Add yield to multiplier
        // e.g., current 10000 + 500 yield = 10500 (5% total yield)
        state.yield_multiplier_bps = state.yield_multiplier_bps + yield_bps;
    }

    /// Simulate loss by subtracting a percentage
    ///
    /// loss_bps: loss in basis points (100 = 1%, 1000 = 10%)
    public entry fun simulate_loss(admin: &signer, loss_bps: u64) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        assert!(address_of(admin) == state.admin, ENOT_ADMIN);

        // Subtract loss from multiplier
        state.yield_multiplier_bps =
            if (state.yield_multiplier_bps > loss_bps) {
                state.yield_multiplier_bps - loss_bps
            } else { 0 };
    }

    /// Reset vault state for a fresh test
    public entry fun reset_vault(admin: &signer) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        assert!(address_of(admin) == state.admin, ENOT_ADMIN);

        state.total_deposits = 0;
        state.yield_multiplier_bps = 10000;
        state.pending_withdrawals = 0;
    }

    /// Directly set total deposits (for testing specific scenarios)
    public entry fun set_total_deposits(admin: &signer, amount: u64) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        assert!(address_of(admin) == state.admin, ENOT_ADMIN);

        state.total_deposits = amount;
    }

    // ============================================
    // View Functions for Testing
    // ============================================

    #[view]
    /// Get current yield multiplier
    public fun get_yield_multiplier(): u64 acquires MockVaultState {
        let vault_address = get_vault_address();
        if (!exists<MockVaultState>(vault_address)) {
            return 10000
        };
        borrow_global<MockVaultState>(vault_address).yield_multiplier_bps
    }

    #[view]
    /// Get total deposits in vault
    public fun get_total_deposits(): u64 acquires MockVaultState {
        let vault_address = get_vault_address();
        if (!exists<MockVaultState>(vault_address)) {
            return 0
        };
        borrow_global<MockVaultState>(vault_address).total_deposits
    }

    #[view]
    /// Get total pending withdrawals
    public fun get_pending_withdrawals(): u64 acquires MockVaultState {
        let vault_address = get_vault_address();
        if (!exists<MockVaultState>(vault_address)) {
            return 0
        };
        borrow_global<MockVaultState>(vault_address).pending_withdrawals
    }

    #[view]
    /// Get depositor's state
    public fun get_depositor_state(depositor: address): (u64, u64) acquires DepositorState {
        if (!exists<DepositorState>(depositor)) {
            return (0, 0)
        };
        let state = borrow_global<DepositorState>(depositor);
        (state.deposited, state.pending_withdrawal)
    }

    // ============================================
    // Test-Only Helpers
    // ============================================

    #[test_only]
    /// Initialize the mock vault for testing
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }

    #[test_only]
    /// Set yield multiplier without admin check (for tests)
    public fun set_yield_multiplier_for_testing(multiplier_bps: u64) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        state.yield_multiplier_bps = multiplier_bps;
    }

    #[test_only]
    /// Set total deposits without admin check (for tests)
    public fun set_total_deposits_for_testing(amount: u64) acquires MockVaultState {
        let vault_address = get_vault_address();
        let state = borrow_global_mut<MockVaultState>(vault_address);
        state.total_deposits = amount;
    }
}
