module aptree::bridge {
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptree::moneyfi_adapter;

    const SEED: vector<u8> = b"APTreeEarn";

    const EUNSUPPORTED_PROVIDER: u64 = 001;
    const EOPERATION_NOT_PERMITTED: u64 = 002;

    struct State has key {
        signer_cap: SignerCapability
    }

    fun init_module(admin: &signer) {
        let (resource_signer, signer_cap) = account::create_resource_account(
            admin, SEED
        );

        move_to(&resource_signer, State { signer_cap })
    }

    public entry fun deposit(
        user: &signer, amount: u64, provider: u64 // provider support can come in later
    ) {
        // TODO: may add support for other providers
        moneyfi_adapter::deposit(user, amount);
        // great place to have fees
    }

    public entry fun request(user: &signer, amount: u64, min_amount: u128) {
        // this is probably a moneyfi only thing
        moneyfi_adapter::request(user, amount, min_amount)
    }

    public entry fun withdraw(
        user: &signer,
        amount: u64,
        provider: u64 // can come in later will default to moneyfi for now
        // TODO: with other providers may need to specify a min_amount
    ) {
        moneyfi_adapter::withdraw(user, amount)
    }

    public entry fun request_and_withdraw(
        user: &signer,
        amount: u64,
        min_share_price: u128
    ) {
        moneyfi_adapter::request(user, amount, min_share_price);
        moneyfi_adapter::withdraw(user, amount)
    }
}
