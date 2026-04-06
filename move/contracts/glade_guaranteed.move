module aptree::glade_guaranteed {

    use aptree::GuaranteedYieldLocking::deposit_guaranteed as deposit;
    use aptree::GuaranteedYieldLocking::withdraw_guaranteed as unlock;
    use aptree::GuaranteedYieldLocking::withdraw_emergency_guaranteed as emergency_unlock;
    use aptree::swap_helpers::swap;

    /// Amount is too low i.e ZERO
    const EAMOUNT_TOO_LOW: u64 = 1001;

    public entry fun deposit_guaranteed<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
        user: &signer,
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
        arg20: address,
        tier: u8,
        min_aet_received: u64
    ) {
        let result = swap<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
            user,
            arg1,
            to_wallet_address,
            arg3,
            arg4,
            arg5,
            arg6,
            arg7,
            arg8,
            withdraw_case, // 1 and 2 means withdraw FA, 3 and 4 means withdraw coin
            arg10,
            fa_addresses, // these are the addresses of FA tokens. Dummy FA addresses are used for coin swaps
            arg12,
            arg13,
            arg14,
            arg15,
            arg16,
            from_token_amounts, // deduct sum of this vector from the user's wallet
            arg18,
            arg19,
            arg20
        );

        let extracted_amount = result.extract();

        assert!(extracted_amount > 0, EAMOUNT_TOO_LOW);

        deposit(user, extracted_amount, tier, min_aet_received);
    }

    public entry fun unlock_guaranteed<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
        user: &signer,
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
        arg20: address,
        position_id: u64
    ) {
        unlock(user, position_id);

        swap<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
            user,
            arg1,
            to_wallet_address,
            arg3,
            arg4,
            arg5,
            arg6,
            arg7,
            arg8,
            withdraw_case, // 1 and 2 means withdraw FA, 3 and 4 means withdraw coin
            arg10,
            fa_addresses, // these are the addresses of FA tokens. Dummy FA addresses are used for coin swaps
            arg12,
            arg13,
            arg14,
            arg15,
            arg16,
            from_token_amounts, // deduct sum of this vector from the user's wallet
            arg18,
            arg19,
            arg20
        );

    }

    public entry fun emergency_unlock_guaranteed<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
        user: &signer,
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
        arg20: address,
        position_id: u64
    ) {
        emergency_unlock(user, position_id);

        swap<fromTokenAddress, T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17, T18, T19, T20, T21, T22, T23, T24, T25, T26, T27, T28, T29, T30, toTokenAddress>(
            user,
            arg1,
            to_wallet_address,
            arg3,
            arg4,
            arg5,
            arg6,
            arg7,
            arg8,
            withdraw_case, // 1 and 2 means withdraw FA, 3 and 4 means withdraw coin
            arg10,
            fa_addresses, // these are the addresses of FA tokens. Dummy FA addresses are used for coin swaps
            arg12,
            arg13,
            arg14,
            arg15,
            arg16,
            from_token_amounts, // deduct sum of this vector from the user's wallet
            arg18,
            arg19,
            arg20
        );

    }
}
