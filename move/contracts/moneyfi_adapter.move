module aptree::moneyfi_adapter {

    use std::option;
    use std::signer::address_of;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::event::emit;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{MintRef, BurnRef, TransferRef, Metadata};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use moneyfi::vault;
    use moneyfi::wallet_account;
    #[test_only]
    use aptos_std::debug;

    const SEED: vector<u8> = b"MoneyFiBridgeController";
    const RESERVE: vector<u8> = b"MoneyFiBridgeReserve";
    const BRIDGE_TOKEN_NAME: vector<u8> = b"APTree Earn Token";
    const BRIDGE_TOKEN_SYMBOL: vector<u8> = b"AET";
    const BRIDGE_WITHDRAWAL_TOKEN_NAME: vector<u8> = b"APTree Earn Withdrawal Token";
    const BRIDGE_WITHDRAWAL_TOKEN_SYMBOL: vector<u8> = b"AEWT";
    const BRIDGE_TOKEN_ICON: vector<u8> = b""; // TODO: setup bridge token icon in git
    const AET_SCALE: u128 = 1_000_000_000;

    // Errors
    const ECLAIMS_DO_NOT_EXIST: u64 = 101;
    const ECLAIMS_ARE_LESS: u64 = 102;
    const ELPMINT_FAILED: u64 = 103;
    const ELP_WITHDRAWL_FAILED: u64 = 104;
    const ELP_AMOUNT_INSUFFICIENT: u64 = 105;
    const ESLIPPAGE_TOO_HIGH: u64 = 106;
    const ELP_AMOUNT_DOES_NOT_EXIST: u64 = 107;
    const EINSUFFICIENT_AMOUNTS_TO_WITHDRAW: u64 = 108;

    struct BridgeState has key, store {
        controller: address,
        controller_capability: SignerCapability,
        reserve: address,
        reserve_capability: SignerCapability
    }

    struct ReserveState has key, store {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
        token_address: address
    }

    struct BridgeWithdrawalTokenState has key, store {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef,
        token_address: address
    }

    #[event]
    struct Deposit has drop, store {
        user: address,
        amount: u64,
        token: address,
        share_price: u128,
        timestamp: u64
    }

    #[event]
    struct RequestWithdrawal has drop, store {
        user: address,
        amount: u64,
        share_tokens_burnt: u64,
        share_price: u128,
        token: address,
        timestamp: u64
    }

    #[event]
    struct Withdraw has drop, store {
        user: address,
        amount: u64,
        token: address,
        timestamp: u64
    }

    fun init_module(admin: &signer) {

        let (controller_signer, controller_cap) =
            account::create_resource_account(admin, SEED);
        let (reserve_signer, reserve_cap) =
            account::create_resource_account(admin, RESERVE);

        let bridge_state = BridgeState {
            controller: address_of(&controller_signer),
            controller_capability: controller_cap,
            reserve: address_of(&reserve_signer),
            reserve_capability: reserve_cap
        };

        let constructor_ref =
            object::create_named_object(&reserve_signer, BRIDGE_TOKEN_NAME);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            string::utf8(BRIDGE_TOKEN_NAME),
            string::utf8(BRIDGE_TOKEN_SYMBOL),
            6,
            string::utf8(BRIDGE_TOKEN_ICON),
            string::utf8(b"https://aptree.io")
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);
        let token_address = object::address_from_constructor_ref(&constructor_ref);

        let wconstructor_ref =
            object::create_named_object(&reserve_signer, BRIDGE_WITHDRAWAL_TOKEN_NAME);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &wconstructor_ref,
            option::none(),
            string::utf8(BRIDGE_WITHDRAWAL_TOKEN_NAME),
            string::utf8(BRIDGE_WITHDRAWAL_TOKEN_SYMBOL),
            6,
            string::utf8(BRIDGE_TOKEN_ICON),
            string::utf8(b"https://aptree.io")
        );

        let wmint_ref = fungible_asset::generate_mint_ref(&wconstructor_ref);
        let wburn_ref = fungible_asset::generate_burn_ref(&wconstructor_ref);
        let wtransfer_ref = fungible_asset::generate_transfer_ref(&wconstructor_ref);
        let wtoken_address = object::address_from_constructor_ref(&wconstructor_ref);

        move_to(
            &reserve_signer,
            ReserveState { burn_ref, mint_ref, transfer_ref, token_address }
        );

        move_to(
            &reserve_signer,
            BridgeWithdrawalTokenState {
                burn_ref: wburn_ref,
                mint_ref: wmint_ref,
                transfer_ref: wtransfer_ref,
                token_address: wtoken_address
            }
        );

        move_to(&controller_signer, bridge_state)
    }

    fun deposit_fungible(
        user: &signer, token: Object<Metadata>, amount: u64
    ) acquires BridgeState, ReserveState {
        let share_price = get_share_price(token);
        assert!(share_price > 0, ELPMINT_FAILED);
        let lp_amount = (((amount as u128) * AET_SCALE) / share_price) as u64;

        let controller_address = account::create_resource_address(&@aptree, SEED);
        let reserve_address = account::create_resource_address(&@aptree, RESERVE);

        let bridge_state = borrow_global<BridgeState>(controller_address);
        let reserve_state = borrow_global<ReserveState>(reserve_address);

        let asset = get_metadata(reserve_address);
        let to_wallet =
            primary_fungible_store::ensure_primary_store_exists(address_of(user), asset);
        // issue lp tokens
        let fa = fungible_asset::mint(&reserve_state.mint_ref, lp_amount);
        fungible_asset::deposit_with_ref(&reserve_state.transfer_ref, to_wallet, fa);

        // transfer funds to reserve
        primary_fungible_store::transfer<Metadata>(user, token, reserve_address, amount);
        let reserve_signer =
            account::create_signer_with_capability(&bridge_state.reserve_capability);
        // deposit from reserve to vault
        vault::deposit(&reserve_signer, token, amount);

        emit(
            Deposit {
                amount,
                user: address_of(user),
                share_price,
                token: @moneyfi_bridge_asset,
                timestamp: timestamp::now_microseconds()
            }
        )
    }

    // amount is the actual token amount the user wants to withdraw
    fun request_withdrawal(
        user: &signer,
        token: Object<Metadata>,
        amount: u64,
        min_share_price: u128
    ) acquires BridgeState, ReserveState, BridgeWithdrawalTokenState {
        let controller_address = account::create_resource_address(&@aptree, SEED);
        let reserve_address = account::create_resource_address(&@aptree, RESERVE);
        let share_price = get_share_price(token);
        assert!(share_price > 0, ELP_WITHDRAWL_FAILED);
        assert!(share_price >= min_share_price, ESLIPPAGE_TOO_HIGH);

        let reserve_state = borrow_global<ReserveState>(reserve_address);
        let withdrawal_state = borrow_global<BridgeWithdrawalTokenState>(reserve_address);

        let bridge_state = borrow_global<BridgeState>(controller_address);

        let reserve_signer =
            account::create_signer_with_capability(&bridge_state.reserve_capability);

        // first confirm user has enough lp tokens to withdraw that amount of share tokens
        let metadata = get_metadata(reserve_address);
        let balance = primary_fungible_store::balance(address_of(user), metadata);
        let share_token_amount = (((amount as u128) * AET_SCALE) / share_price) as u64;
        assert!(balance >= share_token_amount, ELP_AMOUNT_INSUFFICIENT);

        // burn share tokens and mint withdrawal tokens for the withdrawal amount
        let share_token_metadata = get_metadata(reserve_address);
        let from_wallet =
            primary_fungible_store::primary_store(
                address_of(user), share_token_metadata
            );
        fungible_asset::burn_from(
            &reserve_state.burn_ref, from_wallet, share_token_amount
        );

        // mint withdraw_tokens
        let withdrawal_metadata = get_withdrawal_metadata(reserve_address);
        let to_wallet =
            primary_fungible_store::ensure_primary_store_exists(
                address_of(user), withdrawal_metadata
            );
        let minted = fungible_asset::mint(&withdrawal_state.mint_ref, amount);
        fungible_asset::deposit_with_ref(
            &withdrawal_state.transfer_ref, to_wallet, minted
        );

        // request withdrawal
        vault::request_withdraw(&reserve_signer, token, amount);

        emit(
            RequestWithdrawal {
                token: @moneyfi_bridge_asset,
                share_price,
                user: address_of(user),
                amount,
                share_tokens_burnt: share_token_amount,
                timestamp: timestamp::now_microseconds()
            }
        )

    }

    fun withdraw_fungible(
        user: &signer, token: Object<Metadata>, amount: u64
    ) acquires BridgeState, BridgeWithdrawalTokenState {

        let controller_address = account::create_resource_address(&@aptree, SEED);
        let reserve_address = account::create_resource_address(&@aptree, RESERVE);

        let bridge_state = borrow_global<BridgeState>(controller_address);
        let withdrawal_state = borrow_global<BridgeWithdrawalTokenState>(reserve_address);

        let reserve_signer =
            account::create_signer_with_capability(&bridge_state.reserve_capability);

        // burn withdrawal tokens
        let asset = get_withdrawal_metadata(reserve_address);
        let from_wallet = primary_fungible_store::primary_store(address_of(user), asset);
        fungible_asset::burn_from(&withdrawal_state.burn_ref, from_wallet, amount);

        // this will withdraw all pending requesteed amounts that's available
        vault::withdraw_requested_amount(&reserve_signer, token);

        primary_fungible_store::transfer<Metadata>(
            &reserve_signer,
            token,
            address_of(user),
            amount
        );

        emit(
            Withdraw {
                amount,
                user: address_of(user),
                token: @moneyfi_bridge_asset,
                timestamp: timestamp::now_microseconds()
            }
        )

    }

    #[view]
    public fun get_supported_token(): address {
        @moneyfi_bridge_asset
    }

    // interface functions
    public entry fun deposit(user: &signer, amount: u64) acquires BridgeState, ReserveState {
        let token_metadata = object::address_to_object<Metadata>(get_supported_token());
        deposit_fungible(user, token_metadata, amount)
    }

    public entry fun request(
        user: &signer, amount: u64, min_share_price: u128
    ) acquires BridgeWithdrawalTokenState, ReserveState, BridgeState {
        let token_metadata = object::address_to_object<Metadata>(get_supported_token());
        request_withdrawal(user, token_metadata, amount, min_share_price)
    }

    public entry fun withdraw(
        user: &signer, amount: u64
    ) acquires BridgeWithdrawalTokenState, BridgeState {
        let token_metadata = object::address_to_object<Metadata>(get_supported_token());
        withdraw_fungible(user, token_metadata, amount)
    }

    fun get_metadata(reserve_address: address): Object<Metadata> {
        let asset_address =
            object::create_object_address(&reserve_address, BRIDGE_TOKEN_NAME);
        object::address_to_object<Metadata>(asset_address)
    }

    fun get_withdrawal_metadata(reserve_address: address): Object<Metadata> {
        let asset_address =
            object::create_object_address(
                &reserve_address, BRIDGE_WITHDRAWAL_TOKEN_NAME
            );
        object::address_to_object<Metadata>(asset_address)
    }

    fun get_share_price(asset: Object<Metadata>): u128 {
        let reserve_address = account::create_resource_address(&@aptree, RESERVE);
        let wallet_id = wallet_account::get_wallet_id_by_address(reserve_address);

        let total_value = (vault::estimate_total_fund_value(reserve_address, asset) as u128);
        let metadata = get_metadata(reserve_address);

        let current_supply = *fungible_asset::supply(metadata).borrow();

        if (current_supply == 0) return AET_SCALE;

        let (requested_amount, _available_amount, _is_successful) =
            wallet_account::get_withdrawal_state(wallet_id, asset);
        let withdrawed_amount = (requested_amount as u128);

        assert!(total_value >= withdrawed_amount, EINSUFFICIENT_AMOUNTS_TO_WITHDRAW);

        let remaining_amount = total_value - withdrawed_amount;

        let price = (remaining_amount * AET_SCALE) / current_supply;

        price

    }

    #[view]
    public fun get_lp_price(): u128 {
        let token_metadata = object::address_to_object<Metadata>(get_supported_token());
        get_share_price(token_metadata)
    }

    #[view]
    public fun get_pool_estimated_value(): u64 {
        let token_metadata = object::address_to_object<Metadata>(get_supported_token());
        let reserve_address = account::create_resource_address(&@aptree, RESERVE);
        vault::estimate_total_fund_value(reserve_address, token_metadata)
    }

    // Testing

    #[test_only]
    fun create_test_asset(admin: &signer): (
        MintRef, BurnRef, TransferRef, address, Object<Metadata>
    ) {
        let name = string::utf8(b"Test United States Dollar");
        let symbol = string::utf8(b"TUSD");
        let icon = string::utf8(b"");

        let constructor_ref =
            object::create_named_object(admin, b"Test United States Dollar");

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            name,
            symbol,
            6,
            icon,
            string::utf8(b"https://tusd.aptree.io")
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);
        let token_address = object::address_from_constructor_ref(&constructor_ref);
        let metadata = object::object_from_constructor_ref<Metadata>(&constructor_ref);

        (mint_ref, burn_ref, transfer_ref, token_address, metadata)
    }

    #[test_only]
    fun mint_test_asset(
        to: &signer,
        metadata: &Object<Metadata>,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        amount: u64
    ) {
        let to_wallet =
            primary_fungible_store::ensure_primary_store_exists(
                address_of(to), *metadata
            );
        let minted = fungible_asset::mint(&mint_ref, amount);
        fungible_asset::deposit_with_ref(&transfer_ref, to_wallet, minted);
    }

    // init scripts and stuff
    #[test(aptos_framework = @0x1, admin = @aptree, user = @0x0943)]
    fun test_init(
        aptos_framework: &signer, admin: &signer, user: &signer
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        init_module(admin);

        let reserve_address = account::create_resource_address(&@aptree, RESERVE);
        let controller_address = account::create_resource_address(&@aptree, SEED);

        assert!(exists<BridgeState>(controller_address), 1);
        assert!(exists<ReserveState>(reserve_address), 2);
        assert!(exists<BridgeWithdrawalTokenState>(reserve_address), 3);

        let lp_token = get_metadata(reserve_address);
        let withdrawal_token = get_withdrawal_metadata(reserve_address);

        let vault_address = vault::get_vault_address();

        debug::print(&vault_address);
        debug::print(&lp_token);
        debug::print(&withdrawal_token);

        let lp_supply = *fungible_asset::supply(lp_token).borrow();
        let withdrawal_supply = *fungible_asset::supply(withdrawal_token).borrow();

        assert!(lp_supply == 0, 4);
        assert!(withdrawal_supply == 0, 5);
    }

    #[test(aptos_framework = @0x1, admin = @aptree, user = @0x0943)]
    #[expected_failure(abort_code = 0)]
    fun test_deposit_only(
        aptos_framework: &signer, admin: &signer, user: &signer
    ) acquires BridgeState, ReserveState {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        init_module(admin);

        let (mint_ref, burn_ref, transfer_ref, token_address, token_metadata) =
            create_test_asset(admin);
        mint_test_asset(
            user,
            &token_metadata,
            mint_ref,
            transfer_ref,
            10_000_000_000_00
        );

        deposit_fungible(user, token_metadata, 10000)
    }

    // unable to test the rest cause it's gonna abort at deposit
}
