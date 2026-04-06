/// GuaranteedYieldLocking - Fixed-rate yield with instant cashback
///
/// Users lock funds for a fixed period and receive guaranteed yield INSTANTLY
/// as cashback. The protocol takes the risk/reward of actual MoneyFi performance.
module aptree::GuaranteedYieldLocking {
    use std::option::{Self, Option};
    use std::signer::address_of;
    use std::vector;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event::emit;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;

    use aptree::moneyfi_adapter as MoneyFiBridge;

    // ============================================
    // Constants
    // ============================================

    const SEED: vector<u8> = b"GuaranteedYieldController";
    const CASHBACK_VAULT_SEED: vector<u8> = b"GuaranteedYieldCashbackVault";

    // Lock tiers
    const TIER_STARTER: u8 = 1; // 1 month
    const TIER_BRONZE: u8 = 2; // 3 months
    const TIER_SILVER: u8 = 3; // 6 months
    const TIER_GOLD: u8 = 4; // 12 months

    // Durations in seconds
    const DURATION_STARTER: u64 = 2_592_000; // 30 days
    const DURATION_BRONZE: u64 = 7_776_000; // 90 days
    const DURATION_SILVER: u64 = 15_552_000; // 180 days
    const DURATION_GOLD: u64 = 31_536_000; // 365 days

    // Default guaranteed yields in basis points
    const DEFAULT_YIELD_STARTER_BPS: u64 = 40; // 0.4%
    const DEFAULT_YIELD_BRONZE_BPS: u64 = 125; // 1.25%
    const DEFAULT_YIELD_SILVER_BPS: u64 = 250; // 2.5%
    const DEFAULT_YIELD_GOLD_BPS: u64 = 500; // 5%

    const BPS_DENOMINATOR: u64 = 10000;
    const AET_SCALE: u128 = 1_000_000_000;

    // Warning threshold for cashback vault (configurable)
    const CASHBACK_LOW_THRESHOLD: u64 = 100_00000000; // 100 USDT

    // Deposit guards
    const MAX_POSITIONS_PER_USER: u64 = 50;
    const DEFAULT_MIN_DEPOSIT: u64 = 1_000000; // 1 USDT (6 decimals)

    // ============================================
    // Errors
    // ============================================

    /// Amount must be greater than zero.
    const EZERO_AMOUNT: u64 = 301;
    /// Tier must be one of the supported tiers.
    const EINVALID_TIER: u64 = 302;
    /// Position was not found for the given user and id.
    const EPOSITION_NOT_FOUND: u64 = 303;
    /// Position has not reached its unlock time.
    const EPOSITION_NOT_EXPIRED: u64 = 304;
    /// Caller is not the admin.
    const ENOT_ADMIN: u64 = 305;
    /// Deposits are currently disabled.
    const EDEPOSITS_DISABLED: u64 = 306;
    /// Cashback vault does not have enough balance.
    const EINSUFFICIENT_CASHBACK_VAULT: u64 = 307;
    /// Account balance is insufficient.
    const EINSUFFICIENT_BALANCE: u64 = 308;
    /// Position is mature; use the normal unlock flow instead.
    const EUSE_UNLOCK_GUARANTEED: u64 = 309;
    /// Address must be a non-zero address.
    const EINVALID_ADDRESS: u64 = 310;
    /// Deposit amount is below the minimum allowed.
    const EBELOW_MINIMUM_DEPOSIT: u64 = 311;
    /// User has too many active positions.
    const ETOO_MANY_POSITIONS: u64 = 312;
    /// Max total locked principal would be exceeded.
    const EMAX_LOCKED_EXCEEDED: u64 = 313;
    /// Caller is not the pending admin.
    const ENOT_PENDING_ADMIN: u64 = 314;
    /// No pending admin is set.
    const ENO_PENDING_ADMIN: u64 = 315;
    /// Slippage exceeds the user's minimum expected AET.
    const ESLIPPAGE_EXCEEDED: u64 = 316;
    /// Position already has a pending unlock.
    const EPOSITION_ALREADY_PENDING: u64 = 317;
    /// Position does not have a pending unlock.
    const EPOSITION_NOT_PENDING: u64 = 318;

    // ============================================
    // Structs
    // ============================================

    /// Configuration for the guaranteed yield system
    struct GuaranteedYieldConfig has key {
        /// Signer capability for contract operations
        signer_cap: SignerCapability,

        /// Signer capability for cashback vault
        cashback_vault_cap: SignerCapability,

        /// Address of the treasury (receives actual yield)
        treasury: address,

        /// Admin address
        admin: address,

        /// Guaranteed yields per tier in basis points
        /// Index: [0=unused, 1=starter, 2=bronze, 3=silver, 4=gold]
        tier_yields_bps: vector<u64>,

        /// Tier durations in seconds
        tier_durations: vector<u64>,

        /// Whether new deposits are enabled
        deposits_enabled: bool,

        /// Total principal locked across all users
        total_locked_principal: u64,

        /// Total AET tokens held by contract
        total_aet_held: u64,

        /// Total cashback paid out
        total_cashback_paid: u64,

        /// Total yield sent to treasury
        total_yield_to_treasury: u64,

        /// Pending admin for two-step transfer
        pending_admin: Option<address>,

        /// Maximum total locked principal (0 = unlimited)
        max_total_locked_principal: u64,

        /// Minimum deposit amount
        min_deposit_amount: u64
    }

    /// Individual lock position
    struct GuaranteedLockPosition has store, drop, copy {
        /// Unique position identifier
        position_id: u64,

        /// Lock tier
        tier: u8,

        /// Principal amount locked (what user deposited)
        principal: u64,

        /// AET tokens held for this position
        aet_amount: u64,

        /// Cashback amount that was paid to user
        cashback_paid: u64,

        /// Guaranteed yield rate at time of deposit (in bps)
        guaranteed_yield_bps: u64,

        /// Timestamp when position was created
        created_at: u64,

        /// Timestamp when position unlocks
        unlock_at: u64
    }

    /// User's collection of guaranteed yield positions
    struct UserGuaranteedPositions has key {
        positions: vector<GuaranteedLockPosition>,
        next_position_id: u64
    }

    /// Tracks a pending unlock/emergency-unlock that has been requested but not yet withdrawn.
    /// Created during request_unlock_guaranteed / request_emergency_unlock_guaranteed,
    /// consumed during withdraw_guaranteed / withdraw_emergency_guaranteed.
    struct PendingUnlock has store, drop, copy {
        /// The position being unlocked
        position: GuaranteedLockPosition,
        /// Amount to withdraw from MoneyFi (already requested via MoneyFiBridge::request)
        withdrawal_amount: u64,
        /// Amount to send to the user
        to_user: u64,
        /// Amount to send to the treasury
        to_treasury: u64,
        /// Whether this is an emergency unlock
        is_emergency: bool
    }

    /// User's collection of pending unlock requests
    struct UserPendingUnlocks has key {
        pending: vector<PendingUnlock>
    }

    // ============================================
    // Events
    // ============================================

    #[event]
    struct GuaranteedDeposit has drop, store {
        user: address,
        position_id: u64,
        tier: u8,
        principal: u64,
        cashback_paid: u64,
        guaranteed_yield_bps: u64,
        aet_received: u64,
        unlock_timestamp: u64,
        timestamp: u64
    }

    #[event]
    struct GuaranteedUnlock has drop, store {
        user: address,
        position_id: u64,
        principal_returned: u64,
        actual_yield_generated: u64,
        yield_to_treasury: u64,
        original_cashback_paid: u64,
        protocol_profit_or_loss: u64,
        is_profit: bool,
        timestamp: u64
    }

    #[event]
    struct CashbackVaultFunded has drop, store {
        funder: address,
        amount: u64,
        new_balance: u64,
        timestamp: u64
    }

    #[event]
    struct CashbackVaultLow has drop, store {
        current_balance: u64,
        threshold: u64,
        timestamp: u64
    }

    #[event]
    struct TierYieldUpdated has drop, store {
        tier: u8,
        old_yield_bps: u64,
        new_yield_bps: u64,
        timestamp: u64
    }

    #[event]
    struct GuaranteedEmergencyUnlock has drop, store {
        user: address,
        position_id: u64,
        principal_returned: u64,
        yield_forfeited: u64,
        loss_absorbed: u64,
        original_cashback_paid: u64,
        cashback_clawed_back: u64,
        to_treasury: u64,
        aet_burned: u64,
        time_remaining_seconds: u64,
        timestamp: u64
    }

    #[event]
    struct AdminProposed has drop, store {
        current_admin: address,
        proposed_admin: address,
        timestamp: u64
    }

    #[event]
    struct AdminTransferred has drop, store {
        old_admin: address,
        new_admin: address,
        timestamp: u64
    }

    #[event]
    struct TreasuryUpdated has drop, store {
        old_treasury: address,
        new_treasury: address,
        timestamp: u64
    }

    #[event]
    struct DepositsToggled has drop, store {
        enabled: bool,
        timestamp: u64
    }

    #[event]
    struct ConfigValueUpdated has drop, store {
        field: u8, // 1 = max_total_locked, 2 = min_deposit
        old_value: u64,
        new_value: u64,
        timestamp: u64
    }

    // ============================================
    // Init
    // ============================================

    fun init_module(admin: &signer) {
        let (controller_signer, signer_cap) =
            account::create_resource_account(admin, SEED);
        let (_, cashback_vault_cap) =
            account::create_resource_account(admin, CASHBACK_VAULT_SEED);

        // Initialize tier yields [unused, starter, bronze, silver, gold]
        let tier_yields = vector::empty<u64>();
        tier_yields.push_back(0);
        tier_yields.push_back(DEFAULT_YIELD_STARTER_BPS);
        tier_yields.push_back(DEFAULT_YIELD_BRONZE_BPS);
        tier_yields.push_back(DEFAULT_YIELD_SILVER_BPS);
        tier_yields.push_back(DEFAULT_YIELD_GOLD_BPS);

        // Initialize tier durations [unused, starter, bronze, silver, gold]
        let tier_durations = vector::empty<u64>();
        tier_durations.push_back(0);
        tier_durations.push_back(DURATION_STARTER);
        tier_durations.push_back(DURATION_BRONZE);
        tier_durations.push_back(DURATION_SILVER);
        tier_durations.push_back(DURATION_GOLD);

        let config = GuaranteedYieldConfig {
            signer_cap,
            cashback_vault_cap,
            treasury: address_of(admin), // Default to admin, should be updated
            admin: address_of(admin),
            tier_yields_bps: tier_yields,
            tier_durations,
            deposits_enabled: true,
            total_locked_principal: 0,
            total_aet_held: 0,
            total_cashback_paid: 0,
            total_yield_to_treasury: 0,
            pending_admin: option::none(),
            max_total_locked_principal: 0, // 0 = unlimited, admin should set before launch
            min_deposit_amount: DEFAULT_MIN_DEPOSIT
        };

        move_to(&controller_signer, config);
    }

    // ============================================
    // Entry Functions
    // ============================================

    /// Deposit funds and receive instant cashback.
    /// Pass min_aet_received = 0 to skip slippage check.
    public entry fun deposit_guaranteed(
        user: &signer,
        amount: u64,
        tier: u8,
        min_aet_received: u64
    ) acquires GuaranteedYieldConfig, UserGuaranteedPositions {
        assert!(amount > 0, EZERO_AMOUNT);
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );

        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(config.deposits_enabled, EDEPOSITS_DISABLED);
        assert!(amount >= config.min_deposit_amount, EBELOW_MINIMUM_DEPOSIT);

        // Circuit breaker: check max total locked principal
        if (config.max_total_locked_principal > 0) {
            assert!(
                config.total_locked_principal + amount
                    <= config.max_total_locked_principal,
                EMAX_LOCKED_EXCEEDED
            );
        };

        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();

        // Get tier configuration
        let guaranteed_yield_bps = config.tier_yields_bps[(tier as u64)];
        let duration = config.tier_durations[(tier as u64)];
        let unlock_at = current_time + duration;

        // Calculate cashback (use u128 to prevent overflow for large deposits)
        let cashback =
            (((amount as u128) * (guaranteed_yield_bps as u128)) / (
                BPS_DENOMINATOR as u128
            )) as u64;

        // Verify cashback vault has sufficient funds
        let cashback_vault_addr = get_cashback_vault_address();
        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());
        let vault_balance =
            primary_fungible_store::balance(cashback_vault_addr, token_metadata);
        assert!(vault_balance >= cashback, EINSUFFICIENT_CASHBACK_VAULT);

        // Get current share price for AET calculation
        // Note: On Aptos, share price can't change mid-transaction (atomic execution),
        // so querying before deposit is safe (see H2)
        let share_price = MoneyFiBridge::get_lp_price();
        // Note: integer division rounds down, user gets slightly fewer shares (see H1, H6)
        let expected_aet = (((amount as u128) * AET_SCALE) / share_price) as u64;

        // Slippage protection: verify AET received meets user's minimum expectation
        if (min_aet_received > 0) {
            assert!(expected_aet >= min_aet_received, ESLIPPAGE_EXCEEDED);
        };

        // Verify user has sufficient balance before transfer
        let user_balance = primary_fungible_store::balance(user_addr, token_metadata);
        assert!(user_balance >= amount, EINSUFFICIENT_BALANCE);

        // Transfer principal from user to contract
        let controller_addr = get_config_address();
        primary_fungible_store::transfer(user, token_metadata, controller_addr, amount);

        // Transfer cashback from vault to user (INSTANT YIELD)
        let cashback_vault_signer =
            account::create_signer_with_capability(&config.cashback_vault_cap);
        primary_fungible_store::transfer(
            &cashback_vault_signer,
            token_metadata,
            user_addr,
            cashback
        );

        // Contract deposits to MoneyFi
        let controller_signer =
            account::create_signer_with_capability(&config.signer_cap);
        MoneyFiBridge::deposit(&controller_signer, amount);

        // Initialize user positions if needed
        if (!exists<UserGuaranteedPositions>(user_addr)) {
            move_to(
                user,
                UserGuaranteedPositions { positions: vector::empty(), next_position_id: 1 }
            );
        };

        // Create position
        let user_positions = borrow_global_mut<UserGuaranteedPositions>(user_addr);
        assert!(
            user_positions.positions.length() < MAX_POSITIONS_PER_USER,
            ETOO_MANY_POSITIONS
        );
        let position_id = user_positions.next_position_id;
        user_positions.next_position_id = position_id + 1;

        let position = GuaranteedLockPosition {
            position_id,
            tier,
            principal: amount,
            aet_amount: expected_aet,
            cashback_paid: cashback,
            guaranteed_yield_bps,
            created_at: current_time,
            unlock_at
        };

        user_positions.positions.push_back(position);

        // Update global stats
        config.total_locked_principal += amount;
        config.total_aet_held += expected_aet;
        config.total_cashback_paid += cashback;

        // Check if vault is running low
        let new_vault_balance = vault_balance - cashback;
        if (new_vault_balance < CASHBACK_LOW_THRESHOLD) {
            emit(
                CashbackVaultLow {
                    current_balance: new_vault_balance,
                    threshold: CASHBACK_LOW_THRESHOLD,
                    timestamp: current_time
                }
            );
        };

        emit(
            GuaranteedDeposit {
                user: user_addr,
                position_id,
                tier,
                principal: amount,
                cashback_paid: cashback,
                guaranteed_yield_bps,
                aet_received: expected_aet,
                unlock_timestamp: unlock_at,
                timestamp: current_time
            }
        );
    }

    /// Request unlock of a matured position (step 1 of 2).
    /// Initiates withdrawal from MoneyFi. Off-chain confirmation is required
    /// before calling withdraw_guaranteed to complete the process.
    public entry fun request_unlock_guaranteed(
        user: &signer, position_id: u64
    ) acquires GuaranteedYieldConfig, UserGuaranteedPositions, UserPendingUnlocks {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();

        // Find position
        assert!(exists<UserGuaranteedPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserGuaranteedPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = user_positions.positions[index];

        // Validate unlock time
        assert!(current_time >= position.unlock_at, EPOSITION_NOT_EXPIRED);

        // Check position is not already pending
        if (exists<UserPendingUnlocks>(user_addr)) {
            let pending = borrow_global<UserPendingUnlocks>(user_addr);
            let (pending_found, _) = find_pending_index(&pending.pending, position_id);
            assert!(!pending_found, EPOSITION_ALREADY_PENDING);
        };

        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        let controller_signer =
            account::create_signer_with_capability(&config.signer_cap);
        let share_price = MoneyFiBridge::get_lp_price();

        // Calculate current value of position
        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;

        // Request withdrawal from MoneyFi (async — needs off-chain confirmation)
        MoneyFiBridge::request(&controller_signer, current_value, share_price);

        // Calculate amounts for distribution after withdrawal completes
        let to_user =
            if (current_value >= position.principal) {
                position.principal
            } else {
                current_value
            };

        let to_treasury =
            if (current_value > position.principal) {
                current_value - position.principal
            } else { 0 };

        // Store pending unlock
        let pending_unlock = PendingUnlock {
            position,
            withdrawal_amount: current_value,
            to_user,
            to_treasury,
            is_emergency: false
        };

        if (!exists<UserPendingUnlocks>(user_addr)) {
            move_to(user, UserPendingUnlocks { pending: vector::empty() });
        };

        let user_pending = borrow_global_mut<UserPendingUnlocks>(user_addr);
        user_pending.pending.push_back(pending_unlock);

        // Update global stats
        config.total_locked_principal -= position.principal;
        config.total_aet_held -= position.aet_amount;

        // Remove position from active positions
        user_positions.positions.swap_remove(index);
    }

    /// Complete unlock after off-chain confirmation (step 2 of 2).
    /// Withdraws from MoneyFi and distributes tokens to user and treasury.
    public entry fun withdraw_guaranteed(
        user: &signer, position_id: u64
    ) acquires GuaranteedYieldConfig, UserPendingUnlocks {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();

        // Find pending unlock
        assert!(exists<UserPendingUnlocks>(user_addr), EPOSITION_NOT_PENDING);
        let user_pending = borrow_global_mut<UserPendingUnlocks>(user_addr);
        let (found, index) = find_pending_index(&user_pending.pending, position_id);
        assert!(found, EPOSITION_NOT_PENDING);

        let pending = user_pending.pending[index];
        assert!(!pending.is_emergency, EPOSITION_NOT_PENDING);

        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        let controller_signer =
            account::create_signer_with_capability(&config.signer_cap);

        // Complete withdrawal from MoneyFi
        MoneyFiBridge::withdraw(&controller_signer, pending.withdrawal_amount);

        // Transfer principal to user
        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());
        if (pending.to_user > 0) {
            primary_fungible_store::transfer(
                &controller_signer,
                token_metadata,
                user_addr,
                pending.to_user
            );
        };

        // Transfer actual yield to treasury
        if (pending.to_treasury > 0) {
            primary_fungible_store::transfer(
                &controller_signer,
                token_metadata,
                config.treasury,
                pending.to_treasury
            );
            config.total_yield_to_treasury += pending.to_treasury;
        };

        // Calculate protocol P/L
        let actual_yield =
            if (pending.withdrawal_amount > pending.position.principal) {
                pending.withdrawal_amount - pending.position.principal
            } else { 0 };

        let (profit_or_loss, is_profit) =
            if (actual_yield >= pending.position.cashback_paid) {
                (actual_yield - pending.position.cashback_paid, true)
            } else {
                (pending.position.cashback_paid - actual_yield, false)
            };

        // Remove pending unlock
        user_pending.pending.swap_remove(index);

        emit(
            GuaranteedUnlock {
                user: user_addr,
                position_id,
                principal_returned: pending.to_user,
                actual_yield_generated: actual_yield,
                yield_to_treasury: pending.to_treasury,
                original_cashback_paid: pending.position.cashback_paid,
                protocol_profit_or_loss: profit_or_loss,
                is_profit,
                timestamp: current_time
            }
        );
    }

    /// Fund the cashback vault (anyone can call)
    public entry fun fund_cashback_vault(funder: &signer, amount: u64) {
        assert!(amount > 0, EZERO_AMOUNT);

        let cashback_vault_addr = get_cashback_vault_address();
        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());

        // Transfer funds to cashback vault
        primary_fungible_store::transfer(
            funder,
            token_metadata,
            cashback_vault_addr,
            amount
        );

        let new_balance =
            primary_fungible_store::balance(cashback_vault_addr, token_metadata);

        emit(
            CashbackVaultFunded {
                funder: address_of(funder),
                amount,
                new_balance,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Request emergency unlock - exit position early before maturity (step 1 of 2).
    /// Protocol claws back the cashback that was paid upfront and keeps any yield.
    /// Initiates withdrawal from MoneyFi. Off-chain confirmation is required
    /// before calling withdraw_emergency_guaranteed to complete the process.
    public entry fun request_emergency_unlock_guaranteed(
        user: &signer, position_id: u64
    ) acquires GuaranteedYieldConfig, UserGuaranteedPositions, UserPendingUnlocks {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();

        // Find position
        assert!(exists<UserGuaranteedPositions>(user_addr), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global_mut<UserGuaranteedPositions>(user_addr);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);

        let position = user_positions.positions[index];

        // Position must NOT be expired (use request_unlock_guaranteed instead)
        assert!(current_time < position.unlock_at, EUSE_UNLOCK_GUARANTEED);

        // Check position is not already pending
        if (exists<UserPendingUnlocks>(user_addr)) {
            let pending = borrow_global<UserPendingUnlocks>(user_addr);
            let (pending_found, _) = find_pending_index(&pending.pending, position_id);
            assert!(!pending_found, EPOSITION_ALREADY_PENDING);
        };

        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        let controller_signer =
            account::create_signer_with_capability(&config.signer_cap);
        let share_price = MoneyFiBridge::get_lp_price();

        // Calculate current value of position from AET at current share price
        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
        let principal = position.principal;

        // Base payout is capped at principal (protocol keeps any yield above principal)
        let base_payout =
            if (current_value < principal) {
                current_value
            } else {
                principal
            };

        // Deduct cashback clawback — protocol recovers the upfront cashback from the payout
        let cashback_clawback =
            if (base_payout > position.cashback_paid) {
                position.cashback_paid
            } else {
                base_payout
            };
        let payout = base_payout - cashback_clawback;

        // Request withdrawal from MoneyFi (async — needs off-chain confirmation)
        if (base_payout > 0) {
            MoneyFiBridge::request(&controller_signer, base_payout, share_price);
        };

        // Store pending unlock
        let pending_unlock = PendingUnlock {
            position,
            withdrawal_amount: base_payout,
            to_user: payout,
            to_treasury: base_payout - payout,
            is_emergency: true
        };

        if (!exists<UserPendingUnlocks>(user_addr)) {
            move_to(user, UserPendingUnlocks { pending: vector::empty() });
        };

        let user_pending = borrow_global_mut<UserPendingUnlocks>(user_addr);
        user_pending.pending.push_back(pending_unlock);

        // Update global stats
        config.total_locked_principal -= principal;
        config.total_aet_held -= position.aet_amount;

        // Remove position from active positions
        user_positions.positions.swap_remove(index);
    }

    /// Complete emergency unlock after off-chain confirmation (step 2 of 2).
    /// User receives: MAX(0, MIN(principal, current_value) - cashback_paid)
    /// Treasury receives: the remainder (cashback recovery + any forfeited yield)
    public entry fun withdraw_emergency_guaranteed(
        user: &signer, position_id: u64
    ) acquires GuaranteedYieldConfig, UserPendingUnlocks {
        let user_addr = address_of(user);
        let current_time = timestamp::now_seconds();

        // Find pending unlock
        assert!(exists<UserPendingUnlocks>(user_addr), EPOSITION_NOT_PENDING);
        let user_pending = borrow_global_mut<UserPendingUnlocks>(user_addr);
        let (found, index) = find_pending_index(&user_pending.pending, position_id);
        assert!(found, EPOSITION_NOT_PENDING);

        let pending = user_pending.pending[index];
        assert!(pending.is_emergency, EPOSITION_NOT_PENDING);

        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        let controller_signer =
            account::create_signer_with_capability(&config.signer_cap);

        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());

        if (pending.withdrawal_amount > 0) {
            // Complete withdrawal from MoneyFi
            MoneyFiBridge::withdraw(&controller_signer, pending.withdrawal_amount);

            // Transfer user's portion
            if (pending.to_user > 0) {
                primary_fungible_store::transfer(
                    &controller_signer,
                    token_metadata,
                    user_addr,
                    pending.to_user
                );
            };

            // Transfer cashback recovery to treasury
            if (pending.to_treasury > 0) {
                primary_fungible_store::transfer(
                    &controller_signer,
                    token_metadata,
                    config.treasury,
                    pending.to_treasury
                );
            };
        };

        // Reconstruct event data from pending state
        let principal = pending.position.principal;
        let current_value = pending.withdrawal_amount + (
            if (pending.position.aet_amount > 0) {
                // If base_payout < current_value, yield was forfeited (stayed in pool)
                // We stored base_payout as withdrawal_amount, so compute original current_value
                let share_price_at_request = ((pending.withdrawal_amount as u128) * AET_SCALE) / (pending.position.aet_amount as u128);
                let original_current_value = ((pending.position.aet_amount as u128) * share_price_at_request / AET_SCALE) as u64;
                if (original_current_value > principal) { original_current_value - principal } else { 0 }
            } else { 0 }
        );

        let yield_forfeited =
            if (current_value > principal) {
                current_value - principal
            } else { 0 };

        let loss_absorbed =
            if (pending.withdrawal_amount < principal) {
                principal - pending.withdrawal_amount
            } else { 0 };

        let time_remaining =
            if (pending.position.unlock_at > current_time) {
                pending.position.unlock_at - current_time
            } else { 0 };

        // Remove pending unlock
        user_pending.pending.swap_remove(index);

        emit(
            GuaranteedEmergencyUnlock {
                user: user_addr,
                position_id,
                principal_returned: pending.to_user,
                yield_forfeited,
                loss_absorbed,
                original_cashback_paid: pending.position.cashback_paid,
                cashback_clawed_back: pending.to_treasury,
                to_treasury: pending.to_treasury,
                aet_burned: pending.position.aet_amount,
                time_remaining_seconds: time_remaining,
                timestamp: current_time
            }
        );
    }

    // ============================================
    // Admin Functions
    // ============================================

    /// Update guaranteed yield for a tier (only affects new deposits)
    public entry fun set_tier_yield(
        admin: &signer, tier: u8, new_yield_bps: u64
    ) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );

        let old_yield = config.tier_yields_bps[(tier as u64)];
        *config.tier_yields_bps.borrow_mut((tier as u64)) = new_yield_bps;

        emit(
            TierYieldUpdated {
                tier,
                old_yield_bps: old_yield,
                new_yield_bps,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Update treasury address
    public entry fun set_treasury(
        admin: &signer, new_treasury: address
    ) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        assert!(new_treasury != @0x0, EINVALID_ADDRESS);

        let old_treasury = config.treasury;
        config.treasury = new_treasury;

        emit(
            TreasuryUpdated {
                old_treasury,
                new_treasury,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Enable/disable deposits
    public entry fun set_deposits_enabled(
        admin: &signer, enabled: bool
    ) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        config.deposits_enabled = enabled;

        emit(DepositsToggled { enabled, timestamp: timestamp::now_seconds() });
    }

    /// Emergency withdraw from cashback vault (admin only)
    public entry fun admin_withdraw_cashback_vault(
        admin: &signer, amount: u64
    ) acquires GuaranteedYieldConfig {
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);

        let cashback_vault_signer =
            account::create_signer_with_capability(&config.cashback_vault_cap);
        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());

        primary_fungible_store::transfer(
            &cashback_vault_signer,
            token_metadata,
            address_of(admin),
            amount
        );
    }

    /// Propose a new admin (two-step transfer)
    public entry fun propose_admin(admin: &signer, new_admin: address) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        assert!(new_admin != @0x0, EINVALID_ADDRESS);

        config.pending_admin = option::some(new_admin);

        emit(
            AdminProposed {
                current_admin: config.admin,
                proposed_admin: new_admin,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Accept admin role (must be called by pending admin)
    public entry fun accept_admin(new_admin: &signer) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(config.pending_admin.is_some(), ENO_PENDING_ADMIN);
        assert!(
            address_of(new_admin) == *config.pending_admin.borrow(),
            ENOT_PENDING_ADMIN
        );

        let old_admin = config.admin;
        config.admin = address_of(new_admin);
        config.pending_admin = option::none();

        emit(
            AdminTransferred {
                old_admin,
                new_admin: address_of(new_admin),
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Set maximum total locked principal (circuit breaker). 0 = unlimited.
    public entry fun set_max_total_locked(admin: &signer, new_max: u64) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        let old_max = config.max_total_locked_principal;
        config.max_total_locked_principal = new_max;

        emit(
            ConfigValueUpdated {
                field: 1, // max_total_locked
                old_value: old_max,
                new_value: new_max,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Set minimum deposit amount
    public entry fun set_min_deposit(admin: &signer, new_min: u64) acquires GuaranteedYieldConfig {
        let config = borrow_global_mut<GuaranteedYieldConfig>(get_config_address());
        assert!(address_of(admin) == config.admin, ENOT_ADMIN);
        let old_min = config.min_deposit_amount;
        config.min_deposit_amount = new_min;

        emit(
            ConfigValueUpdated {
                field: 2, // min_deposit
                old_value: old_min,
                new_value: new_min,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    // ============================================
    // View Functions
    // ============================================

    #[view]
    /// Get all guaranteed positions for a user
    public fun get_user_guaranteed_positions(
        user: address
    ): vector<GuaranteedLockPosition> acquires UserGuaranteedPositions {
        if (!exists<UserGuaranteedPositions>(user)) {
            return vector::empty()
        };
        borrow_global<UserGuaranteedPositions>(user).positions
    }

    #[view]
    /// Get a specific position
    public fun get_guaranteed_position(
        user: address, position_id: u64
    ): GuaranteedLockPosition acquires UserGuaranteedPositions {
        assert!(exists<UserGuaranteedPositions>(user), EPOSITION_NOT_FOUND);
        let user_positions = borrow_global<UserGuaranteedPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        assert!(found, EPOSITION_NOT_FOUND);
        user_positions.positions[index]
    }

    #[view]
    /// Get guaranteed yield for a tier (in bps)
    public fun get_tier_guaranteed_yield(tier: u8): u64 acquires GuaranteedYieldConfig {
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        config.tier_yields_bps[(tier as u64)]
    }

    #[view]
    /// Get tier duration in seconds
    public fun get_tier_duration(tier: u8): u64 acquires GuaranteedYieldConfig {
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        config.tier_durations[(tier as u64)]
    }

    #[view]
    /// Calculate cashback for a given amount and tier
    public fun calculate_cashback(amount: u64, tier: u8): u64 acquires GuaranteedYieldConfig {
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        let yield_bps = config.tier_yields_bps[(tier as u64)];
        // Use u128 intermediate to prevent overflow for large deposits
        (((amount as u128) * (yield_bps as u128)) / (BPS_DENOMINATOR as u128)) as u64
    }

    #[view]
    /// Get cashback vault balance
    public fun get_cashback_vault_balance(): u64 {
        let cashback_vault_addr = get_cashback_vault_address();
        let token_metadata =
            object::address_to_object<Metadata>(MoneyFiBridge::get_supported_token());
        primary_fungible_store::balance(cashback_vault_addr, token_metadata)
    }

    #[view]
    /// Get protocol statistics
    public fun get_protocol_stats(): (u64, u64, u64, u64) acquires GuaranteedYieldConfig {
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        (
            config.total_locked_principal,
            config.total_aet_held,
            config.total_cashback_paid,
            config.total_yield_to_treasury
        )
    }

    #[view]
    /// Check if a position is unlockable
    public fun is_position_unlockable(
        user: address, position_id: u64
    ): bool acquires UserGuaranteedPositions {
        if (!exists<UserGuaranteedPositions>(user)) {
            return false
        };

        let user_positions = borrow_global<UserGuaranteedPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        if (!found) {
            return false
        };

        let position = vector::borrow(&user_positions.positions, index);
        timestamp::now_seconds() >= position.unlock_at
    }

    #[view]
    /// Get tier configuration (duration_seconds, yield_bps)
    public fun get_tier_config(tier: u8): (u64, u64) acquires GuaranteedYieldConfig {
        assert!(
            tier >= TIER_STARTER && tier <= TIER_GOLD,
            EINVALID_TIER
        );
        let config = borrow_global<GuaranteedYieldConfig>(get_config_address());
        let duration = config.tier_durations[(tier as u64)];
        let yield_bps = config.tier_yields_bps[(tier as u64)];
        (duration, yield_bps)
    }

    #[view]
    /// Get treasury address
    public fun get_treasury(): address acquires GuaranteedYieldConfig {
        borrow_global<GuaranteedYieldConfig>(get_config_address()).treasury
    }

    #[view]
    /// Check if deposits are enabled
    public fun are_deposits_enabled(): bool acquires GuaranteedYieldConfig {
        borrow_global<GuaranteedYieldConfig>(get_config_address()).deposits_enabled
    }

    #[view]
    /// Preview emergency unlock: returns (user_payout, yield_forfeited, cashback_clawback)
    /// user_payout = MAX(0, MIN(principal, current_value) - cashback_paid)
    /// yield_forfeited = amount above principal that stays in pool
    /// cashback_clawback = amount of cashback recovered by protocol
    public fun get_emergency_unlock_preview(
        user: address, position_id: u64
    ): (u64, u64, u64) acquires UserGuaranteedPositions {
        if (!exists<UserGuaranteedPositions>(user)) {
            return (0, 0, 0)
        };

        let user_positions = borrow_global<UserGuaranteedPositions>(user);
        let (found, index) = find_position_index(&user_positions.positions, position_id);
        if (!found) {
            return (0, 0, 0)
        };

        let position = user_positions.positions.borrow(index);
        let share_price = MoneyFiBridge::get_lp_price();

        let current_value = ((position.aet_amount as u128) * share_price / AET_SCALE) as u64;
        let principal = position.principal;
        let cashback_paid = position.cashback_paid;

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
        let forfeited =
            if (current_value > principal) {
                current_value - principal
            } else { 0 };

        (payout, forfeited, cashback_clawback)
    }

    #[view]
    /// Get maximum total locked principal (0 = unlimited)
    public fun get_max_total_locked(): u64 acquires GuaranteedYieldConfig {
        borrow_global<GuaranteedYieldConfig>(get_config_address()).max_total_locked_principal
    }

    #[view]
    /// Get minimum deposit amount
    public fun get_min_deposit(): u64 acquires GuaranteedYieldConfig {
        borrow_global<GuaranteedYieldConfig>(get_config_address()).min_deposit_amount
    }

    // ============================================
    // Internal Functions
    // ============================================

    fun get_config_address(): address {
        account::create_resource_address(&@aptree, SEED)
    }

    fun get_cashback_vault_address(): address {
        account::create_resource_address(&@aptree, CASHBACK_VAULT_SEED)
    }

    fun find_position_index(
        positions: &vector<GuaranteedLockPosition>, position_id: u64
    ): (bool, u64) {
        let len = positions.length();
        let i = 0;

        while (i < len) {
            let position = positions.borrow(i);
            if (position.position_id == position_id) {
                return (true, i)
            };
            i += 1;
        };

        (false, 0)
    }

    fun find_pending_index(
        pending: &vector<PendingUnlock>, position_id: u64
    ): (bool, u64) {
        let len = pending.length();
        let i = 0;

        while (i < len) {
            let p = pending.borrow(i);
            if (p.position.position_id == position_id) {
                return (true, i)
            };
            i += 1;
        };

        (false, 0)
    }

    // ============================================
    // Test Functions
    // ============================================

    #[test_only]
    public fun init_for_testing(admin: &signer) {
        init_module(admin);
    }

    #[test_only]
    public fun get_tier_starter(): u8 {
        TIER_STARTER
    }

    #[test_only]
    public fun get_tier_bronze(): u8 {
        TIER_BRONZE
    }

    #[test_only]
    public fun get_tier_silver(): u8 {
        TIER_SILVER
    }

    #[test_only]
    public fun get_tier_gold(): u8 {
        TIER_GOLD
    }

    #[test_only]
    public fun get_cashback_vault_address_for_testing(): address {
        get_cashback_vault_address()
    }
}
