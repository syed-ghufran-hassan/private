module aptree::locking {
    use std::signer::address_of;
    use std::vector;
    use aptos_framework::event::emit;
    use aptos_framework::timestamp;
    use aptos_framework::account::{Self, SignerCapability};

    use aptree::moneyfi_adapter as MoneyFiBridge;

    // ============================================
    // Constants
    // ============================================

    const SEED: vector<u8> = b"APTreeLockingController";

    // Lock tiers
    const TIER_BRONZE: u8 = 1;
    const TIER_SILVER: u8 = 2;
    const TIER_GOLD: u8 = 3;

    // Durations in seconds
    const DURATION_BRONZE: u64 = 7_776_000;   // 90 days
    const DURATION_SILVER: u64 = 15_552_000;  // 180 days
    const DURATION_GOLD: u64 = 31_536_000;    // 365 days

    // Early withdrawal limits in basis points (1 bps = 0.01%)
    const EARLY_LIMIT_BRONZE_BPS: u64 = 200;  // 2%
    const EARLY_LIMIT_SILVER_BPS: u64 = 300;  // 3%
    const EARLY_LIMIT_GOLD_BPS: u64 = 500;    // 5%

    const BPS_DENOMINATOR: u64 = 10000;
    const AET_SCALE: u128 = 1_000_000_000;
    const PRECISION: u128 = 1_000_000_000_000; // For ratio calculations

    // ============================================
    // Errors
    // ============================================
    
    const EZERO_AMOUNT: u64 = 201;
    const EINVALID_TIER: u64 = 202;
    const EPOSITION_NOT_FOUND: u64 = 203;
    const EPOSITION_EXPIRED: u64 = 204;
    const EPOSITION_NOT_EXPIRED: u64 = 205;
    const ENOT_POSITION_OWNER: u64 = 206;
    const EINSUFFICIENT_EARLY_ALLOWANCE: u64 = 207;
    const ENO_YIELD_AVAILABLE: u64 = 208;
    const ELOCKS_DISABLED: u64 = 209;
    const ENOT_ADMIN: u64 = 210;
    const EUSE_WITHDRAW_UNLOCKED: u64 = 211;
    const EINSUFFICIENT_BALANCE: u64 = 212;

    // ============================================
    // Structs
    // ============================================

    /// Individual lock position
    struct LockPosition has store, drop, copy {
        /// Unique position identifier
        position_id: u64,
        /// Lock tier (BRONZE=1, SILVER=2, GOLD=3)
        tier: u8,
        /// Original principal deposited (in underlying token)
        principal: u64,
        /// AET tokens held for this position
        aet_amount: u64,
        /// Share price at time of deposit (for yield calculation)
        entry_share_price: u128,
        /// Timestamp when position was created
        created_at: u64,
        /// Timestamp when position unlocks
        unlock_at: u64,
        /// Amount already withdrawn early (in underlying token value)
        early_withdrawal_used: u64,
    }

    /// User's collection of lock positions
    struct UserLockPositions has key {
        /// All positions for this user
        positions: vector<LockPosition>,
        /// Counter for generating position IDs
        next_position_id: u64,
    }

    /// Global lock configuration
    struct LockConfig has key {
        /// Signer capability for the locking controller
        signer_cap: SignerCapability,
        /// Early withdrawal caps per tier in basis points [unused, bronze, silver, gold]
        tier_limits_bps: vector<u64>,
        /// Tier durations in seconds [unused, bronze, silver, gold]
        tier_durations: vector<u64>,
        /// Whether new locks are enabled
        locks_enabled: bool,
        /// Admin address for configuration changes
        admin: address,
    }

    // ============================================
    // Events
    // ============================================

    #[event]
    struct LockedDeposit has drop, store {
        user: address,
        position_id: u64,
        tier: u8,
        principal: u64,
        aet_received: u64,
        entry_share_price: u128,
        unlock_timestamp: u64,
        timestamp: u64,
    }

    #[event]
    struct PositionExtended has drop, store {
        user: address,
        position_id: u64,
        added_principal: u64,
        added_aet: u64,
        new_total_principal: u64,
        new_total_aet: u64,
        old_unlock_timestamp: u64,
        new_unlock_timestamp: u64,
        new_entry_share_price: u128,
        timestamp: u64,
    }

    #[event]
    struct EarlyWithdrawal has drop, store {
        user: address,
        position_id: u64,
        amount_withdrawn: u64,
        aet_burned: u64,
        remaining_early_allowance: u64,
        remaining_principal: u64,
        remaining_aet: u64,
        timestamp: u64,
    }

    #[event]
    struct UnlockedWithdrawal has drop, store {
        user: address,
        position_id: u64,
        total_withdrawn: u64,
        total_aet_burned: u64,
        original_principal: u64,
        profit_or_loss: u64,  // Absolute value, check if withdrawn > principal for profit
        is_profit: bool,
        lock_duration_actual: u64,
        timestamp: u64,
    }

    #[event]
    struct EmergencyUnlock has drop, store {
        user: address,
        position_id: u64,
        principal_returned: u64,
        yield_forfeited: u64,
        loss_absorbed: u64,
        aet_burned: u64,
        time_remaining_seconds: u64,
        timestamp: u64,
    }

    // ============================================
    // Init
    // ============================================

    fun init_module(admin: &signer) {
        let (controller_signer, signer_cap) = account::create_resource_account(admin, SEED);

        // Initialize tier limits [unused_index_0, bronze, silver, gold]
        let tier_limits = vector::empty<u64>();
        vector::push_back(&mut tier_limits, 0); // Index 0 unused
        vector::push_back(&mut tier_limits, EARLY_LIMIT_BRONZE_BPS);
        vector::push_back(&mut tier_limits, EARLY_LIMIT_SILVER_BPS);
        vector::push_back(&mut tier_limits, EARLY_LIMIT_GOLD_BPS);

        // Initialize tier durations [unused_index_0, bronze, silver, gold]
        let tier_durations = vector::empty<u64>();
        vector::push_back(&mut tier_durations, 0); // Index 0 unused
        vector::push_back(&mut tier_durations, DURATION_BRONZE);
        vector::push_back(&mut tier_durations, DURATION_SILVER);
        vector::push_back(&mut tier_durations, DURATION_GOLD);

        let config = LockConfig {
            signer_cap,
            tier_limits_bps: tier_limits,
            tier_durations,
            locks_enabled: true,
            admin: address_of(admin),
        };

        move_to(&controller_signer, config);
    }

    // ============================================
    // Entry Functions
    // ============================================

    /// Create a new locked deposit position
    public entry fun deposit_locked(
        user: &signer,
        amount: u64,
        tier: u8
    ) acquires LockConfig, UserLockPositions {
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(tier >= TIER_BRONZE && tier <= TIER_GOLD, EINVALID_TIER);

        let config = borrow_global<LockConfig>(get_config_address());
        assert!(config.locks_enabled, ELOCKS_DISABLED);

        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();
        let share_price = MoneyFiBridge::get_lp_price();

        // Calculate AET to receive
        let aet_amount = (((amount as u128) * AET_SCALE) / share_price) as u64;

        // Get tier duration
        let duration = *vector::borrow(&config.tier_durations, (tier as u64));
        let unlock_at = current_time + duration;

        // Perform the deposit through MoneyFiBridge
        MoneyFiBridge::deposit(user, amount);

        // Initialize user positions if needed
        if (!exists<UserLockPositions>(user_addr)) {
            move_to(user, UserLockPositions {
                positions: vector::empty(),
                next_position_id: 1,
            });
        };

        // Create position
        let user_positions = borrow_global_mut<UserLockPositions>(user_addr);
        let position_id = user_positions.next_position_id;
        user_positions.next_position_id = position_id + 1;

        let position = LockPosition {
            position_id,
            tier,
            principal: amount,
            aet_amount,
            entry_share_price: share_price,
            created_at: current_time,
            unlock_at,
            early_withdrawal_used: 0,
        };

        vector::push_back(&mut user_positions.positions, position);

        emit(LockedDeposit {
            user: user_addr,
            position_id,
            tier,
            principal: amount,
            aet_received: aet_amount,
            entry_share_price: share_price,
            unlock_timestamp: unlock_at,
            timestamp: current_time,
        });
    }

    /// Add funds to an existing position (extends lock proportionally)
    public entry fun add_to_position(
        user: &signer,
        position_id: u64,
        amount: u64
    ) acquires LockConfig, UserLockPositions {
        assert!(amount > 0, EZERO_AMOUNT);

        let config = borrow_global<LockConfig>(get_config_address());
        assert!(config.locks_enabled, ELOCKS_DISABLED);

        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();
        let share_price = MoneyFiBridge::get_lp_price();

        // Find position
        assert!(exists<UserLockPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserLockPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = vector::borrow_mut(&mut user_positions.positions, index);

        // Position must not be expired
        assert!(current_time < position.unlock_at, EPOSITION_EXPIRED);

        let old_unlock = position.unlock_at;
        let old_principal = position.principal;
        let old_entry_price = position.entry_share_price;

        // Calculate new AET
        let new_aet = (((amount as u128) * AET_SCALE) / share_price) as u64;

        // Calculate proportional lock extension
        let old_remaining = position.unlock_at - current_time;
        let tier_duration = *vector::borrow(&config.tier_durations, (position.tier as u64));

        // weighted_remaining = (old_principal * old_remaining + new_deposit * tier_duration) / total_principal
        let old_weight = (old_principal as u128) * (old_remaining as u128);
        let new_weight = (amount as u128) * (tier_duration as u128);
        let total_principal = (old_principal + amount) as u128;
        let weighted_remaining = ((old_weight + new_weight) / total_principal) as u64;

        let new_unlock = current_time + weighted_remaining;

        // Calculate weighted entry price
        let new_entry_price = calculate_weighted_entry_price(
            old_principal, old_entry_price, amount, share_price
        );

        // Perform deposit
        MoneyFiBridge::deposit(user, amount);

        // Update position
        position.principal = old_principal + amount;
        position.aet_amount = position.aet_amount + new_aet;
        position.entry_share_price = new_entry_price;
        position.unlock_at = new_unlock;

        emit(PositionExtended {
            user: user_addr,
            position_id,
            added_principal: amount,
            added_aet: new_aet,
            new_total_principal: position.principal,
            new_total_aet: position.aet_amount,
            old_unlock_timestamp: old_unlock,
            new_unlock_timestamp: new_unlock,
            new_entry_share_price: new_entry_price,
            timestamp: current_time,
        });
    }

    /// Withdraw early from a specific position (limited amount based on yield)
    public entry fun withdraw_early(
        user: &signer,
        position_id: u64,
        amount: u64
    ) acquires LockConfig, UserLockPositions {
        assert!(amount > 0, EZERO_AMOUNT);

        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();
        let share_price = MoneyFiBridge::get_lp_price();

        // Find position
        assert!(exists<UserLockPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserLockPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = vector::borrow_mut(&mut user_positions.positions, index);

        // Position must not be expired
        assert!(current_time < position.unlock_at, EPOSITION_EXPIRED);

        // Calculate available early withdrawal
        let config = borrow_global<LockConfig>(get_config_address());
        let available = calculate_early_withdrawal_available(position, share_price, config);
        assert!(available > 0, ENO_YIELD_AVAILABLE);
        assert!(amount <= available, EINSUFFICIENT_EARLY_ALLOWANCE);

        // Calculate current value of position
        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;

        // Calculate AET to burn for withdrawal amount
        let aet_to_burn = (((amount as u128) * AET_SCALE) / share_price) as u64;

        // Calculate principal reduction (proportional)
        let withdrawal_ratio = (amount as u128) * PRECISION / (current_value as u128);
        let principal_reduction = ((position.principal as u128) * withdrawal_ratio / PRECISION) as u64;

        // Update position
        position.aet_amount = position.aet_amount - aet_to_burn;
        position.principal = position.principal - principal_reduction;
        position.early_withdrawal_used = position.early_withdrawal_used + amount;

        // Calculate remaining allowance for event
        let remaining_allowance = calculate_early_withdrawal_available(position, share_price, config);

        // Perform withdrawal through MoneyFiBridge
        // First request, then withdraw
        MoneyFiBridge::request(user, amount, share_price);
        MoneyFiBridge::withdraw(user, amount);

        emit(EarlyWithdrawal {
            user: user_addr,
            position_id,
            amount_withdrawn: amount,
            aet_burned: aet_to_burn,
            remaining_early_allowance: remaining_allowance,
            remaining_principal: position.principal,
            remaining_aet: position.aet_amount,
            timestamp: current_time,
        });
    }

    /// Withdraw full amount after lock expires
    public entry fun withdraw_unlocked(
        user: &signer,
        position_id: u64
    ) acquires UserLockPositions {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();
        let share_price = MoneyFiBridge::get_lp_price();

        // Find position
        assert!(exists<UserLockPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserLockPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = vector::borrow(&user_positions.positions, index);

        // Position must be expired
        assert!(current_time >= position.unlock_at, EPOSITION_NOT_EXPIRED);

        // Calculate total value
        let total_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
        let original_principal = position.principal;
        let aet_to_burn = position.aet_amount;
        let lock_duration = current_time - position.created_at;

        // Calculate profit/loss
        let (profit_loss, is_profit) = if (total_value >= original_principal) {
            (total_value - original_principal, true)
        } else {
            (original_principal - total_value, false)
        };

        // Remove position (swap and pop for efficiency)
        vector::swap_remove(&mut user_positions.positions, index);

        // Perform withdrawal
        MoneyFiBridge::request(user, total_value, share_price);
        MoneyFiBridge::withdraw(user, total_value);

        emit(UnlockedWithdrawal {
            user: user_addr,
            position_id,
            total_withdrawn: total_value,
            total_aet_burned: aet_to_burn,
            original_principal,
            profit_or_loss: profit_loss,
            is_profit,
            lock_duration_actual: lock_duration,
            timestamp: current_time,
        });
    }

    /// Emergency unlock - get principal back, forfeit yield (anytime before unlock)
    public entry fun emergency_unlock(
        user: &signer,
        position_id: u64
    ) acquires UserLockPositions {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();
        let share_price = MoneyFiBridge::get_lp_price();

        // Find position
        assert!(exists<UserLockPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserLockPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = vector::borrow(&user_positions.positions, index);

        // Position must NOT be expired (use withdraw_unlocked instead)
        assert!(current_time < position.unlock_at, EUSE_WITHDRAW_UNLOCKED);

        // Calculate current value
        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
        let principal = position.principal;
        let aet_amount = position.aet_amount;
        let time_remaining = position.unlock_at - current_time;

        // User gets MIN(principal, current_value)
        let payout = if (current_value < principal) { current_value } else { principal };

        // Calculate forfeited yield or absorbed loss
        let (yield_forfeited, loss_absorbed) = if (current_value > principal) {
            (current_value - principal, 0u64)
        } else if (current_value < principal) {
            (0u64, principal - current_value)
        } else {
            (0u64, 0u64)
        };

        // Remove position
        vector::swap_remove(&mut user_positions.positions, index);

        // Perform withdrawal for payout amount only
        // The forfeited yield stays in the pool (AET is burned, value remains)
        MoneyFiBridge::request(user, payout, share_price);
        MoneyFiBridge::withdraw(user, payout);

        emit(EmergencyUnlock {
            user: user_addr,
            position_id,
            principal_returned: payout,
            yield_forfeited,
            loss_absorbed,
            aet_burned: aet_amount,
            time_remaining_seconds: time_remaining,
            timestamp: current_time,
        });
    }

    // ============================================
    // Admin Functions
    // ============================================

    /// Update tier early withdrawal limit (admin only)
    public entry fun set_tier_limit(
        admin: &signer,
        tier: u8,
        new_limit_bps: u64
    ) acquires LockConfig {
        let config = borrow_global_mut<LockConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        assert!(tier >= TIER_BRONZE && tier <= TIER_GOLD, EINVALID_TIER);

        *vector::borrow_mut(&mut config.tier_limits_bps, (tier as u64)) = new_limit_bps;
    }

    /// Enable/disable new lock creation (admin only)
    public entry fun set_locks_enabled(
        admin: &signer,
        enabled: bool
    ) acquires LockConfig {
        let config = borrow_global_mut<LockConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);

        config.locks_enabled = enabled;
    }

    // ============================================
    // View Functions
    // ============================================

    #[view]
    /// Get all positions for a user
    public fun get_user_positions(user: address): vector<LockPosition> acquires UserLockPositions {
        if (!exists<UserLockPositions>(user)) {
            return vector::empty()
        };
        let user_positions = borrow_global<UserLockPositions>(user);
        user_positions.positions
    }

    #[view]
    /// Get a specific position
    public fun get_position(user: address, position_id: u64): LockPosition acquires UserLockPositions {
        assert!(exists<UserLockPositions>(user), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global<UserLockPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);
        *vector::borrow(&user_positions.positions, index)
    }

    #[view]
    /// Get available early withdrawal for a position
    public fun get_early_withdrawal_available(user: address, position_id: u64): u64 acquires LockConfig, UserLockPositions {
        if (!exists<UserLockPositions>(user)) {
            return 0
        };

        let user_positions = borrow_global<UserLockPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        if (!found) {
            return 0
        };

        let position = vector::borrow(&user_positions.positions, index);
        let current_time = timestamp::now_seconds();

        // If expired, no early withdrawal (use withdraw_unlocked)
        if (current_time >= position.unlock_at) {
            return 0
        };

        let share_price = MoneyFiBridge::get_lp_price();
        let config = borrow_global<LockConfig>(get_config_address());

        calculate_early_withdrawal_available(position, share_price, config)
    }

    #[view]
    /// Check if a position is unlocked
    public fun is_position_unlocked(user: address, position_id: u64): bool acquires UserLockPositions {
        if (!exists<UserLockPositions>(user)) {
            return false
        };

        let user_positions = borrow_global<UserLockPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        if (!found) {
            return false
        };

        let position = vector::borrow(&user_positions.positions, index);
        timestamp::now_seconds() >= position.unlock_at
    }

    #[view]
    /// Get total locked value for a user (across all positions)
    public fun get_user_total_locked_value(user: address): u64 acquires UserLockPositions {
        if (!exists<UserLockPositions>(user)) {
            return 0
        };

        let user_positions = borrow_global<UserLockPositions>(user);
        let share_price = MoneyFiBridge::get_lp_price();
        let total = 0u64;
        let len = vector::length(&user_positions.positions);
        let i = 0;

        while (i < len) {
            let position = vector::borrow(&user_positions.positions, i);
            let value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
            total = total + value;
            i = i + 1;
        };

        total
    }

    #[view]
    /// Get tier configuration (duration_seconds, early_limit_bps)
    public fun get_tier_config(tier: u8): (u64, u64) acquires LockConfig {
        assert!(tier >= TIER_BRONZE && tier <= TIER_GOLD, EINVALID_TIER);

        let config = borrow_global<LockConfig>(get_config_address());
        let duration = *vector::borrow(&config.tier_durations, (tier as u64));
        let limit_bps = *vector::borrow(&config.tier_limits_bps, (tier as u64));

        (duration, limit_bps)
    }

    #[view]
    /// Preview emergency unlock payout and forfeited yield
    public fun get_emergency_unlock_preview(user: address, position_id: u64): (u64, u64) acquires UserLockPositions {
        if (!exists<UserLockPositions>(user)) {
            return (0, 0)
        };

        let user_positions = borrow_global<UserLockPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        if (!found) {
            return (0, 0)
        };

        let position = vector::borrow(&user_positions.positions, index);
        let share_price = MoneyFiBridge::get_lp_price();

        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
        let principal = position.principal;

        let payout = if (current_value < principal) { current_value } else { principal };
        let forfeited = if (current_value > principal) { current_value - principal } else { 0 };

        (payout, forfeited)
    }

    // ============================================
    // Internal Functions
    // ============================================

    fun get_config_address(): address {
        account::create_resource_address(&@aptree, SEED)
    }

    fun find_position_index(positions: &vector<LockPosition>, position_id: u64): (bool, u64) {
        let len = vector::length(positions);
        let i = 0;

        while (i < len) {
            let position = vector::borrow(positions, i);
            if (position.position_id == position_id) {
                return (true, i)
            };
            i = i + 1;
        };

        (false, 0)
    }

    fun calculate_early_withdrawal_available(
        position: &LockPosition,
        current_share_price: u128,
        config: &LockConfig
    ): u64 {
        // Calculate current value of position
        let current_value = ((position.aet_amount as u128) * current_share_price / AET_SCALE) as u64;

        // Calculate accrued yield (0 if negative)
        let accrued_yield = if (current_value > position.principal) {
            current_value - position.principal
        } else {
            0
        };

        // Get cap based on tier
        let cap_bps = *vector::borrow(&config.tier_limits_bps, (position.tier as u64));
        let principal_cap = (position.principal * cap_bps) / BPS_DENOMINATOR;

        // Available = min(yield, cap) - already used
        let limit = if (accrued_yield < principal_cap) { accrued_yield } else { principal_cap };

        if (limit > position.early_withdrawal_used) {
            limit - position.early_withdrawal_used
        } else {
            0
        }
    }

    fun calculate_weighted_entry_price(
        old_principal: u64,
        old_entry_price: u128,
        new_deposit: u64,
        current_price: u128
    ): u128 {
        let old_weight = (old_principal as u128) * old_entry_price;
        let new_weight = (new_deposit as u128) * current_price;
        let total_principal = (old_principal + new_deposit) as u128;

        (old_weight + new_weight) / total_principal
    }

    // ============================================
    // Test Functions
    // ============================================

    #[test_only]
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }

    #[test_only]
    public fun get_tier_bronze(): u8 { TIER_BRONZE }

    #[test_only]
    public fun get_tier_silver(): u8 { TIER_SILVER }

    #[test_only]
    public fun get_tier_gold(): u8 { TIER_GOLD }
}
