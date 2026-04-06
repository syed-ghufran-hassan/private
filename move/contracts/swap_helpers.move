module aptree::swap_helpers {
    use aptos_framework::account as aptos_account;
    use aptos_framework::coin;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use std::fungible_asset::{Self, Metadata};
    use std::primary_fungible_store;
    use std::object;

    // Importing panora swap module
    use 0x1c3206329806286fd2223647c9f9b130e66baeb6d7224a18c1f642ffe48f3b4c::panora_swap;

    const E_DISPATCHABLE_FUNCTION_ERROR: u64 = 1;

    // Main function for executing panora swap operations (Note - don't change order of the arguments/type arguments)
    // fromTokenAddress and toTokenAddress are token types so only compatible with coins. In case of FA, 0x1::string::String is sent
    // Use T23, T24, T25 for your type arguments, if required as per your contract
    public fun swap<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
        arg0: &signer,
        arg1: 0x1::option::Option<signer>,
        to_wallet_address: address,
        arg3: u64,
        arg4: u8,
        arg5: vector<u8>,
        arg6: vector<vector<vector<u8>>>,
        arg7: vector<vector<vector<u64>>>,
        arg8: vector<vector<vector<bool>>>,
        withdraw_case: vector<vector<u8>>, // 1 and 2 means withdraw FA, 3 and 4 means withdraw coin
        arg10: vector<vector<vector<address>>>,
        fa_addresses: vector<vector<address>>, // these are the addresses of FA tokens. Dummy FA addresses are used for coin swaps
        arg12: vector<vector<address>>,
        arg13: 0x1::option::Option<vector<vector<vector<vector<vector<u8>>>>>>,
        arg14: vector<vector<vector<u64>>>,
        arg15: 0x1::option::Option<vector<vector<vector<u8>>>>,
        arg16: address,
        from_token_amounts: vector<u64>, // deduct sum of this vector from the user's wallet
        arg18: u64,
        arg19: u64,
        arg20: address
        // Additional arguments can be appended here, if required for your contract
    ): Option<u64> {
        // Calculate total input amount to be passed in the router function
        let total_from_token_amount = 0;
        from_token_amounts.for_each(|e| {
            total_from_token_amount += e;
        });

        // Determine asset type (Coin / FA) and extract the respective token according to the function payload
        let (from_token_coin, from_token_fa) =
            if (withdraw_case[0][0] == 1 || withdraw_case[0][0] == 2) {
                let obj = object::address_to_object<Metadata>(fa_addresses[0][0]);
                (
                    option::none(),
                    option::some(
                        primary_fungible_store_withdraw_helper(
                            arg0, obj, total_from_token_amount
                        )
                    )
                )
                // To exclude fungible asset withdrawals, comment out the above return statement and uncomment the below return statement
                // (option::none() , option::none())
            } else {
                (
                    option::some(
                        coin::withdraw<fromTokenAddress>(arg0, total_from_token_amount)
                    ),
                    option::none()
                )
                // To exclude coin withdrawals, comment out the above return statement and uncomment the below return statement
                // (option::none() , option::none())
            };

        // Call the router function from the panora_swap module
        let (coin_m_left, fa_m_left, coin_m_out, fa_m_out) =
            panora_swap::router<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
                signer::address_of(arg0) /* this address will receive any residual amounts post swap execution*/,
                from_token_coin,
                from_token_fa,
                arg3,
                arg4,
                arg5,
                arg6,
                arg7,
                arg8,
                withdraw_case,
                arg10,
                fa_addresses,
                arg12,
                arg13,
                arg14,
                arg15,
                arg16,
                from_token_amounts,
                arg18,
                arg19,
                arg20
            );

        // this function handles coin/fa options created above. In case of exact in swap, the options are destroyed and in case of exact out swap, the remaining from token is sent to the signer of this transaction
        check_and_deposit_fa_opt(arg0, fa_m_left);
        check_and_deposit_coin_opt<fromTokenAddress>(arg0, coin_m_left);

        let total_to_amount: u64 = 0;

        if (fa_m_out.is_some()) {
            let fa = fa_m_out.extract();
            let value = fungible_asset::amount(&fa);
            total_to_amount += value;
            primary_fungible_store_deposit_helper(to_wallet_address, fa);
        };
        fa_m_out.destroy_none();

        if (coin_m_out.is_some()) {
            let coin = coin_m_out.extract();
            let coin_fa = coin::coin_to_fungible_asset<toTokenAddress>(coin);
            let value = fungible_asset::amount(&coin_fa);
            total_to_amount += value;
            primary_fungible_store_deposit_helper(to_wallet_address, coin_fa);
        };
        coin_m_out.destroy_none();

        option::some(total_to_amount)
    }

    // Helper function to deposit FA to the given signer
    fun check_and_deposit_fa_opt(
        sender: &signer, coin_opt: Option<0x1::fungible_asset::FungibleAsset>
    ) {
        if (option::is_some(&coin_opt)) {
            let fa = option::extract(&mut coin_opt);
            let sender_addr = signer::address_of(sender);

            primary_fungible_store_deposit_helper(sender_addr, fa);

        };
        option::destroy_none(coin_opt);
    }

    // Helper function to deposit FA to the given address
    fun check_and_deposit_fa_to_address_opt(
        receiver: address, coin_opt: Option<0x1::fungible_asset::FungibleAsset>
    ) {
        if (option::is_some(&coin_opt)) {
            let fa = option::extract(&mut coin_opt);

            primary_fungible_store_deposit_helper(receiver, fa);

        };
        option::destroy_none(coin_opt);
    }

    // Helper function to deposit coins to the given signer
    fun check_and_deposit_coin_opt<X>(
        sender: &signer, coin_opt: Option<coin::Coin<X>>
    ) {
        if (coin_opt.is_some()) {
            let coin = option::extract(&mut coin_opt);

            let sender_addr = signer::address_of(sender);
            if (!coin::is_account_registered<X>(sender_addr)) {
                coin::register<X>(sender);
            };
            coin::deposit(sender_addr, coin);
        };
        option::destroy_none(coin_opt);
    }

    // Helper function to deposit coins to the given address
    fun check_and_deposit_coin_to_address_opt<X>(
        receiver: address, coin_opt: Option<coin::Coin<X>>
    ) {

        if (option::is_some(&coin_opt)) {
            let coin = option::extract(&mut coin_opt);

            coin::deposit<X>(receiver, coin);
        };
        option::destroy_none(coin_opt);

    }

    // Helper function to deposit FA to primary fungible store of the given FA
    fun primary_fungible_store_deposit_helper(
        receiver: address, fa: fungible_asset::FungibleAsset
    ) {
        let v = fungible_asset::amount(&fa);
        let metadata = fungible_asset::asset_metadata(&fa);
        let before = primary_fungible_store::balance(receiver, metadata);

        primary_fungible_store::deposit(receiver, fa);

        let after = primary_fungible_store::balance(receiver, metadata);

        assert!(
            after - before == v,
            E_DISPATCHABLE_FUNCTION_ERROR
        );
    }

    // Helper function to withdraw FA from primary fungible store of the given FA
    fun primary_fungible_store_withdraw_helper<T0: key>(
        arg0: &signer, arg1: 0x1::object::Object<T0>, arg2: u64
    ): 0x1::fungible_asset::FungibleAsset {
        let v0 = 0x1::primary_fungible_store::withdraw(arg0, arg1, arg2);
        assert!(0x1::fungible_asset::amount(&v0) == arg2, E_DISPATCHABLE_FUNCTION_ERROR);
        v0
    }
}
