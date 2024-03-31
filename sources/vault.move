module cbindex::vault {
    use std::signer;
    use std::string;
    use std::vector;
    use std::option;
    use std::smart_table;
    use aptos_std::type_info;

    use aptos_framework::coin;
    use aptos_framework::event;
    use aptos_framework::aptos_coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::resource_account;

    use cbindex::shares_fa_coin;
    use cbindex::math::pow;

    use liquidswap::curves::Uncorrelated;
    use liquidswap::router_v2;

    use pyth::pyth;
    use pyth::price_identifier;
    use pyth::i64;
    use pyth::price::{Self,Price};

    const ZERO_ACCOUNT: address = @zero;
    const DEFAULT_ADMIN: address = @admin;
    const RESOURCE_ACCOUNT: address = @cbindex;
    const ORIGIN: address = @origin;
    const MAX_VAULT_NAME_LENGTH: u64 = 32;
    const MAX_VAULT_LOGO_URL_LENGTH: u64 = 256; 

     // List of errors
    const ERROR_ONLY_ADMIN: u64 = 0;
    const ERROR_ALREADY_INITIALIZED: u64 = 1;
    const ERROR_NOT_CREATOR: u64 = 2;
    const ERROR_EMPTY_NAME: u64 = 3;
    const ERROR_EMPTY_SYMBOL: u64 = 4;
    const ERROR_NAME_TOO_LONG: u64 = 5;
    const ERROR_SYMBOL_TOO_LONG: u64 = 6;
    const ERROR_VAULT_NOT_INITIALIZED: u64 = 7;
    const ERROR_SENDER_INSUFFICIENT_BALANCE: u64 = 8;
    const ERROR_ASSET_NOT_SUPPORTED: u64 = 9;
    const ERROR_OVERFLOW: u64 = 10;
    const ERROR_TOO_SMALL_AMOUNT: u64 = 11;
    const ERROR_COIN_BALANCE_NOT_ENOUGH: u64 = 12;

    /// Max `u128` value.
    const MAX_U128: u128 = 340282366920938463463374607431768211455;

    /// These are testnet addresses https://docs.pyth.network/documentation/pythnet-price-feeds/aptos#addresses
    const APTOS_USD_PRICE_FEED_IDENTIFIER : vector<u8> = x"44a93dddd8effa54ea51076c4e851b6cbbfd938e82eb90197de38fe8876bb66e";
    const BTC_USD_PRICE_FEED_IDENTIFIER : vector<u8> = x"f9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b";
    const ETH_USD_PRICE_FEED_IDENTIFIER : vector<u8> = x"ca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a6";
    const USDC_USD_PRICE_FEED_IDENTIFIER : vector<u8> = x"41f3625971ca2ed2263e78573fe5ce23e13d2558ed3f2e47ab0f84fb9e7ae722";

    const AUM_NAV_DECIMALS: u8 = 8;
    const SHARES_TOKEN_DECIMALS: u8 = 8;
    const NAV_DEFAULT: u128 = 1;   // default nav value 1 usd
    const WITHDRAW_SHARES_PERCENTAGE_DIVISOR: u64 = 10000;

    struct AssetInfo has copy, drop, store {
        /// The asset's symbol
        symbol: string::String,
        /// The asset's name
        name: string::String,
        /// The asset's decimals
        decimals: u8,
        /// The asset's type name
        type_name: string::String,
        /// The asset's vault balance
        vault_balance: u64,
        /// The asset's pyth identity
        pyth_identity: vector<u8>,
    }

    struct VaultMetadata has store, drop {
        /// The creator of the vault
        creator: address,
        /// The vault's created time
        created_time: u64,
        /// The vault's address
        vault_address: address,
        /// The vault's name
        name: string::String,
        /// The vault's symbol
        symbol: vector<u8>,
        /// The vault's assets
        assets: vector<AssetInfo>,
        /// The holders of the vault(just for test)
        holders: vector<VaultHolder>,
        /// The vault's resource account signer
        signer_cap: account::SignerCapability,
    }

    struct VaultMetadataResp has drop {
        /// The creator of the vault
        creator: address,
        /// The vault's created time
        created_time: u64,
        /// The vault's address
        vault_address: address,
        /// The vault's name
        name: string::String,
        /// The vault's symbol
        symbol: string::String,
        /// The vault's holders
        holders: vector<VaultHolder>,
    }

    struct VaultHolder has copy, store, drop {
        /// The holder's address
        holder: address,
        /// The holder's last deposit time
        last_deposit_time: u64,
    }

    struct VaultInfo has key {
        signer_cap: account::SignerCapability,
        fee_to: address,
        admin: address,
        /// The vault's supported assets
        supported_assets: vector<AssetInfo>,
        /// The vault's supported protocol
        supported_protocols: option::Option<vector<address>>,
        /// The vault's metadata map
        vault_metadata_map: smart_table::SmartTable<vector<u8>, VaultMetadata>,
    }

    #[event]
    struct VaultCreated has drop, store {
        creator: address,
        created_time: u64,
        vault_address: address,
        vault_symbol: string::String,
        name: string::String,
    }

    #[event]
    struct Deposit has drop, store {
        depositor: address,
        created_time: u64,
        vault_symbol: string::String,
        coin_type: string::String,
        amount: u64,
        amount_decimal: u8,
        minted_shares: u64,
        minted_shares_decimal: u8,
        eq_usd: u128,
        eq_usd_decimal: u8,
    }

    #[event]
    struct Withdraw has drop, store {
        withdrawer: address,
        created_time: u64,
        vault_symbol: string::String,
        coin_types: vector<string::String>,
        amounts: vector<u64>,
        decimalss: vector<u8>,
        eq_usds: vector<u128>,
        burned_shares: u64,
        burned_shares_decimal: u8,
        eq_usd: u128,
        eq_usd_decimal: u8,
    }

    #[event]
    struct Swap has drop, store {
        swapper: address,
        created_time: u64,
        vault_symbol: string::String,
        from_coin_type: string::String,
        to_coin_type: string::String,
        from_amount: u64,
        to_amount: u64,
    }

    
    fun init_module(sender: &signer) {
        let signer_cap = resource_account::retrieve_resource_account_cap(sender, ORIGIN);
        let resource_signer = account::create_signer_with_capability(&signer_cap);
        let supported_assets = vector::empty<AssetInfo>();
        vector::push_back(&mut supported_assets, AssetInfo {
            symbol: string::utf8(b"ETH"),
            name: string::utf8(b"ethereum"),
            decimals: 8,
            type_name: string::utf8(b"0xb4d7b2466d211c1f4629e8340bb1a9e75e7f8fb38cc145c54c5c9f9d5017a318::coins_extended::ETH"),
            vault_balance: 0,
            pyth_identity: ETH_USD_PRICE_FEED_IDENTIFIER,
        });
        vector::push_back(&mut supported_assets, AssetInfo {
            symbol: string::utf8(b"BTC"),
            name: string::utf8(b"bitcoin"),
            decimals: 8,
            type_name: string::utf8(b"0x43417434fd869edee76cca2a4d2301e528a1551b1d719b75c350c3c97d15b8b9::coins::BTC"),
            vault_balance: 0,
            pyth_identity: BTC_USD_PRICE_FEED_IDENTIFIER,
        });
        vector::push_back(&mut supported_assets, AssetInfo {
            symbol: string::utf8(b"APT"),
            name: string::utf8(b"Aptos Coin"),
            decimals: 8,
            type_name: string::utf8(b"0x1::aptos_coin::AptosCoin"),
            vault_balance: 0,
            pyth_identity: APTOS_USD_PRICE_FEED_IDENTIFIER,
        });
        vector::push_back(&mut supported_assets, AssetInfo {
            symbol: string::utf8(b"USDC"),
            name: string::utf8(b"usdc"),
            decimals: 6,
            type_name: string::utf8(b"0xb4d7b2466d211c1f4629e8340bb1a9e75e7f8fb38cc145c54c5c9f9d5017a318::coins_extended::USDC"),
            vault_balance: 0,
            pyth_identity: USDC_USD_PRICE_FEED_IDENTIFIER,
        });
        move_to(&resource_signer, VaultInfo {
            signer_cap,
            fee_to: ZERO_ACCOUNT,
            admin: DEFAULT_ADMIN,
            supported_assets,
            supported_protocols: option::none<vector<address>>(),
            vault_metadata_map: smart_table::new(),
        });
    }

    #[view]
    public fun get_vault_supported_assets(): vector<AssetInfo> acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        vault_info.supported_assets
    }

    #[view]
    public fun get_vault_list(): vector<VaultMetadataResp> acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        let vault_list = vector::empty<VaultMetadataResp>();
        smart_table::for_each_ref<vector<u8>, VaultMetadata>(&vault_info.vault_metadata_map, |_key, value| {
            let vaule: &VaultMetadata = value;
            vector::push_back(&mut vault_list, VaultMetadataResp {
                creator: vaule.creator,
                created_time: vaule.created_time,
                vault_address: vaule.vault_address,
                symbol: string::utf8(vaule.symbol),
                name: vaule.name,
                holders: vaule.holders,
            });
            ()
        });
        vault_list
    }
    
    #[view]
    public fun get_vault_assets(symbol: string::String): vector<AssetInfo> acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        let vault_metadata = smart_table::borrow<vector<u8>, VaultMetadata>(&vault_info.vault_metadata_map, *string::bytes(&symbol));
        vault_metadata.assets
    }

    #[view]
    public fun get_vault_info(symbol: string::String): VaultMetadataResp acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        let vault_metadata = smart_table::borrow<vector<u8>, VaultMetadata>(&vault_info.vault_metadata_map, *string::bytes(&symbol));
        VaultMetadataResp {
            creator: vault_metadata.creator,
            created_time: vault_metadata.created_time,
            vault_address: vault_metadata.vault_address,
            symbol: string::utf8(vault_metadata.symbol),
            name: vault_metadata.name,
            holders: vault_metadata.holders,
        }
    }

    #[view]
    public fun get_amount_out<X,Y>(
        x_in: u64,
    ) :u64{
        router_v2::get_amount_out<X,Y,Uncorrelated>(x_in)
    }

    // only admin
    public entry fun add_supported_asset<X>(
        sender: &signer,
        pyth_identity: vector<u8>,
    ) acquires VaultInfo{
        let sender_address = signer::address_of(sender);
        let vault_info = borrow_global_mut<VaultInfo>(RESOURCE_ACCOUNT);
        assert!(sender_address == vault_info.admin, ERROR_ONLY_ADMIN);
        let type_name = type_info::type_name<X>();
        let (exist, _) = vector::find<AssetInfo>(&vault_info.supported_assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == type_name
        });
        if (!exist) {
            let asset_info = AssetInfo {
                symbol: coin::symbol<X>(),
                name: coin::name<X>(),
                decimals: coin::decimals<X>(),
                type_name: type_name,
                vault_balance: 0,
                pyth_identity,
            };
            vector::push_back(&mut vault_info.supported_assets, asset_info);
        }
    }

    /// create a new vault(symbol is unique)
    public entry fun create_vault(
        sender: &signer,
        name: string::String,
        symbol: string::String,
    ) acquires VaultInfo {
        assert!(!is_vault_created(symbol), ERROR_ALREADY_INITIALIZED);
        assert!(string::length(&name) != 0, ERROR_EMPTY_NAME);
        assert!(string::length(&symbol) != 0, ERROR_EMPTY_SYMBOL);
        assert!(string::length(&name) <= MAX_VAULT_NAME_LENGTH, ERROR_NAME_TOO_LONG);
        assert!(string::length(&symbol) <= MAX_VAULT_LOGO_URL_LENGTH, ERROR_SYMBOL_TOO_LONG);
        let sender_address = signer::address_of(sender);
        let vault_info = borrow_global_mut<VaultInfo>(RESOURCE_ACCOUNT);
        let resource_signer = account::create_signer_with_capability(&vault_info.signer_cap);
        shares_fa_coin::init_shares_fa_coin_with_symbol(
            &resource_signer,
            name,
            *string::bytes(&symbol),
            SHARES_TOKEN_DECIMALS,
            string::utf8(b""),
            string::utf8(b""),
        );
        let (vault_signer, signer_cap) = account::create_resource_account(&resource_signer, *string::bytes(&symbol));
        let vault_metadata = VaultMetadata {
            creator: sender_address,
            created_time: timestamp::now_seconds(),
            vault_address: signer::address_of(&vault_signer),
            name,
            symbol: *string::bytes(&symbol),
            assets: vector::empty(),
            holders: vector::empty(),
            signer_cap,
        };
        smart_table::add(&mut vault_info.vault_metadata_map, *string::bytes(&symbol), vault_metadata);
        event::emit(VaultCreated {
            creator: sender_address,
            created_time: timestamp::now_seconds(),
            vault_address: signer::address_of(&vault_signer),
            vault_symbol: symbol,
            name,
        });
    }
    
    /// Deposit assets to the vault
    public entry fun deposit<X>(
        sender: &signer,
        symbol: string::String,
        amount: u64,
        vaas: vector<vector<u8>>,
    ) acquires VaultInfo {
        assert!(is_vault_created(symbol), ERROR_VAULT_NOT_INITIALIZED);
        // check aseet type
        let asset_type_name = type_info::type_name<X>();
        let vault_info = borrow_global_mut<VaultInfo>(RESOURCE_ACCOUNT);
        let resource_signer = account::create_signer_with_capability(&vault_info.signer_cap);
        let (exist, index) = vector::find<AssetInfo>(&vault_info.supported_assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == asset_type_name
        });
        assert!(exist, ERROR_ASSET_NOT_SUPPORTED);
        let asset_info = vector::borrow<AssetInfo>(&vault_info.supported_assets, index);
        let vault_metadata = smart_table::borrow_mut<vector<u8>, VaultMetadata>(&mut vault_info.vault_metadata_map, *string::bytes(&symbol));
        let vault_signer = account::create_signer_with_capability(&vault_metadata.signer_cap);
        let vault_address = signer::address_of(&vault_signer);
        let sender_address = signer::address_of(sender);
        let sender_balance = coin::balance<X>(sender_address);
        assert!(sender_balance >= amount, ERROR_SENDER_INSUFFICIENT_BALANCE);
        if (!coin::is_account_registered<X>(vault_address)) {
            coin::register<X>(&vault_signer);
            // first deposit this asset
            let ledger_asset_info = AssetInfo {
                symbol: asset_info.symbol,
                name: asset_info.name,
                decimals: asset_info.decimals,
                type_name: asset_info.type_name,
                vault_balance: 0,
                pyth_identity: asset_info.pyth_identity,
            };
            vector::push_back(&mut vault_metadata.assets, ledger_asset_info);
        };
        coin::transfer<X>(sender, vault_address, amount);
        let (_, ledger_index) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == asset_type_name
        });
        let ledger_asset_info_current = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, ledger_index);
        ledger_asset_info_current.vault_balance = ledger_asset_info_current.vault_balance + amount;
        // to do caculate the mint shares amount.
        let (prices, x_price) = update_and_fetch_price<X>(sender,vault_metadata, &vault_info.supported_assets, vaas);
        let (mint_shares_amount, eq_usd) = calc_mint_shares_amount<X>(amount, asset_info.decimals, &prices, &x_price, vault_metadata);
        assert!(mint_shares_amount > 0, ERROR_TOO_SMALL_AMOUNT);
        // mint shares token to sender
        shares_fa_coin::mint(&resource_signer, *string::bytes(&symbol), sender_address, mint_shares_amount);
        // update holder
        add_vault_holder_or_not(sender_address, vault_metadata);
        // emit deposit event
        event::emit(Deposit {
            depositor: sender_address,
            created_time: timestamp::now_seconds(),
            vault_symbol: symbol,
            coin_type: asset_type_name,
            amount,
            amount_decimal: asset_info.decimals,
            minted_shares: mint_shares_amount,
            minted_shares_decimal: SHARES_TOKEN_DECIMALS,
            eq_usd: eq_usd,
            eq_usd_decimal: AUM_NAV_DECIMALS,
        });
    }

    /// Withdraw assets from the vault
    public entry fun withdraw<X,Y,Z>(
        sender: &signer,
        symbol: string::String,
        shares_percentage: u64,
        vaas: vector<vector<u8>>,
    ) acquires VaultInfo {
        assert!(is_vault_created(symbol), ERROR_VAULT_NOT_INITIALIZED);
        is_coin_supported(&type_info::type_name<X>());
        is_coin_supported(&type_info::type_name<Y>());
        is_coin_supported(&type_info::type_name<Z>());
        let vault_info = borrow_global_mut<VaultInfo>(RESOURCE_ACCOUNT);
        let vault_metadata = smart_table::borrow_mut<vector<u8>, VaultMetadata>(&mut vault_info.vault_metadata_map, *string::bytes(&symbol));
        let sender_address = signer::address_of(sender);
        let prices = update_and_fetch_price_without_generic(sender, vault_metadata, vaas);
        let (withdraw_amount_xyz, decimals_xyz, eq_usd_xyz, burned_shares, eq_usd) = calc_withdraw_amounts<X,Y,Z>(sender_address, shares_percentage, &prices, vault_metadata);
        assert!(burned_shares > 0, ERROR_TOO_SMALL_AMOUNT);
        // burn shares token from sender
        let resource_signer = account::create_signer_with_capability(&vault_info.signer_cap);
        shares_fa_coin::burn(&resource_signer, *string::bytes(&symbol), sender_address, burned_shares);
        // transfer assets to sender
        let vault_signer = account::create_signer_with_capability(&vault_metadata.signer_cap);
        let event_coin_types = vector::empty<string::String>();
        if (vector::length<u64>(&withdraw_amount_xyz) == 1) {
            if (!coin::is_account_registered<X>(sender_address)) {
                coin::register<X>(sender);
            };
            coin::transfer<X>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 0));
            vector::push_back(&mut event_coin_types, type_info::type_name<X>());
            // update metadata asset balance
            let (_, index_x) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<X>()
            });
            let asset_info_x = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_x);
            asset_info_x.vault_balance = asset_info_x.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 0);
        } else if (vector::length<u64>(&withdraw_amount_xyz) == 2) {
            if (!coin::is_account_registered<X>(sender_address)) {
                coin::register<X>(sender);
            };
            if (!coin::is_account_registered<Y>(sender_address)) {
                coin::register<Y>(sender);
            };
            coin::transfer<X>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 0));
            coin::transfer<Y>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 1));
            vector::push_back(&mut event_coin_types, type_info::type_name<X>());
            vector::push_back(&mut event_coin_types, type_info::type_name<Y>());
            // update metadata asset balance
            let (_, index_x) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<X>()
            });
            let asset_info_x = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_x);
            asset_info_x.vault_balance = asset_info_x.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 0);
            let (_, index_y) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<Y>()
            });
            let asset_info_y = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_y);
            asset_info_y.vault_balance = asset_info_y.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 1);
        } else if (vector::length<u64>(&withdraw_amount_xyz) == 3) {
            if (!coin::is_account_registered<X>(sender_address)) {
                coin::register<X>(sender);
            };
            if (!coin::is_account_registered<Y>(sender_address)) {
                coin::register<Y>(sender);
            };
            if (!coin::is_account_registered<Z>(sender_address)) {
                coin::register<Z>(sender);
            };
            coin::transfer<X>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 0));
            coin::transfer<Y>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 1));
            coin::transfer<Z>(&vault_signer, sender_address, *vector::borrow<u64>(&withdraw_amount_xyz, 2));
            vector::push_back(&mut event_coin_types, type_info::type_name<X>());
            vector::push_back(&mut event_coin_types, type_info::type_name<Y>());
            vector::push_back(&mut event_coin_types, type_info::type_name<Z>());
            // update metadata asset balance
            let (_, index_x) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<X>()
            });
            let asset_info_x = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_x);
            asset_info_x.vault_balance = asset_info_x.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 0);
            let (_, index_y) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<Y>()
            });
            let asset_info_y = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_y);
            asset_info_y.vault_balance = asset_info_y.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 1);
            let (_, index_z) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<Z>()
            });
            let asset_info_z = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, index_z);
            asset_info_z.vault_balance = asset_info_z.vault_balance - *vector::borrow<u64>(&withdraw_amount_xyz, 2);
        };
        // remove holder or not
        if (shares_percentage == WITHDRAW_SHARES_PERCENTAGE_DIVISOR) {
            remove_vault_holder_or_not(sender_address, vault_metadata);
        };
        // emit withdraw event
        event::emit(Withdraw {
            withdrawer: sender_address,
            created_time: timestamp::now_seconds(),
            vault_symbol: symbol,
            coin_types: event_coin_types,
            amounts: withdraw_amount_xyz,
            decimalss: decimals_xyz,
            eq_usds: eq_usd_xyz,
            burned_shares,
            burned_shares_decimal: SHARES_TOKEN_DECIMALS,
            eq_usd,
            eq_usd_decimal: AUM_NAV_DECIMALS,
        });
    }
    /// swap assets in the vault(X-> token0, Y-> token1)
    public entry fun swap_exact_input<X,Y>(
        sender: &signer,
        symbol: string::String,
        x_in: u64,
        y_min_out: u64,
    ) acquires VaultInfo{
        is_coin_supported(&type_info::type_name<X>());
        is_coin_supported(&type_info::type_name<Y>());
        let vault_info = borrow_global_mut<VaultInfo>(RESOURCE_ACCOUNT);
        let vault_metadata = smart_table::borrow_mut<vector<u8>, VaultMetadata>(&mut vault_info.vault_metadata_map, *string::bytes(&symbol));
        is_creator(sender, vault_metadata);
        let vault_signer = account::create_signer_with_capability(&vault_metadata.signer_cap);
        let vault_address = signer::address_of(&vault_signer);
        // check the balance of the vault before swap
        let x_balance_before = coin::balance<X>(vault_address);
        let y_balance_before :u64 = 0;
        if (coin::is_account_registered<Y>(vault_address)) {
            y_balance_before = coin::balance<Y>(vault_address);
        }else {
            coin::register<Y>(&vault_signer);
        };
        // call swap to swap token
        let coin_y = router_v2::swap_exact_coin_for_coin<X,Y,Uncorrelated>(
            coin::withdraw<X>(&vault_signer, x_in),
            y_min_out
        );
        coin::deposit(vault_address, coin_y);
        // check the balance of the vault after swap
        let x_balance_after = coin::balance<X>(vault_address);
        let y_balance_after = coin::balance<Y>(vault_address);
        // update metadata
        let (_, x_index) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == type_info::type_name<X>()
        });
        let x_asset_info = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, x_index);
        x_asset_info.vault_balance = x_balance_after;
        let (y_exist, y_index) = vector::find<AssetInfo>(&mut vault_metadata.assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == type_info::type_name<Y>()
        });
        if (!y_exist) {
            let (_, s_index) = vector::find<AssetInfo>(&vault_info.supported_assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<Y>()
            });
            let asset_info = vector::borrow<AssetInfo>(&vault_info.supported_assets, s_index);
            let ledger_asset_info = AssetInfo {
                symbol: asset_info.symbol,
                name: asset_info.name,
                decimals: asset_info.decimals,
                type_name: asset_info.type_name,
                vault_balance: y_balance_after,
                pyth_identity: asset_info.pyth_identity,
            };
            vector::push_back(&mut vault_metadata.assets, ledger_asset_info);
        }else {
            let y_asset_info = vector::borrow_mut<AssetInfo>(&mut vault_metadata.assets, y_index);
            y_asset_info.vault_balance = y_balance_after;
        };
        // emit swap event
        event::emit(Swap {
            swapper: signer::address_of(sender),
            created_time: timestamp::now_seconds(),
            vault_symbol: symbol,
            from_coin_type: type_info::type_name<X>(),
            to_coin_type: type_info::type_name<Y>(),
            from_amount: x_balance_before - x_balance_after,
            to_amount: y_balance_after - y_balance_before,
        });
    }

    /// check the vault is created
    fun is_vault_created(symbol: string::String): bool acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        smart_table::contains(&vault_info.vault_metadata_map, *string::bytes(&symbol))
    }

    /// check the token is supported by the vault
    fun is_coin_supported(coin_type: &string::String) acquires VaultInfo{
        let vault_info = borrow_global<VaultInfo>(RESOURCE_ACCOUNT);
        let (exist, _) = vector::find<AssetInfo>(&vault_info.supported_assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == *coin_type
        });
        assert!(exist, ERROR_ASSET_NOT_SUPPORTED);
    }

    /// check the sender if the creator of the vault
    fun is_creator(sender: &signer, vault_metadata: &VaultMetadata) {
        let sender_address = signer::address_of(sender);
        assert!(vault_metadata.creator == sender_address, ERROR_NOT_CREATOR);
    }

    /// add vault holder of the vault(just for test)
    fun add_vault_holder_or_not(holder: address, vault_metadata: &mut VaultMetadata){
        let (exist, index) = vector::find<VaultHolder>(&vault_metadata.holders, |holder_temp| {
            let holder_temp : &VaultHolder = holder_temp;
            holder_temp.holder == holder
        });
        if (!exist) {
            let vault_holder = VaultHolder {
                holder,
                last_deposit_time: timestamp::now_seconds(),
            };
            vector::push_back(&mut vault_metadata.holders, vault_holder);
        }else {
            let vault_holder = vector::borrow_mut<VaultHolder>(&mut vault_metadata.holders, index);
            vault_holder.last_deposit_time = timestamp::now_seconds();
        }
    }

    /// remove vault holder of the vault(just for test)
    fun remove_vault_holder_or_not(holder: address, vault_metadata: &mut VaultMetadata){
        let (_, index) = vector::find<VaultHolder>(&vault_metadata.holders, |holder_temp| {
            let holder_temp : &VaultHolder = holder_temp;
            holder_temp.holder == holder
        });
        vector::remove(&mut vault_metadata.holders, index);
    }

    /// Update the price feed with the provided vaas
    fun update_and_fetch_price<X>(
        receiver: &signer,
        vault_metadata: &VaultMetadata,
        supported_assets: &vector<AssetInfo>,
        vaas: vector<vector<u8>>
     ): (vector<Price>, Price) {
        let coins = coin::withdraw<aptos_coin::AptosCoin>(receiver, pyth::get_update_fee(&vaas)); // Get coins to pay for the update
        pyth::update_price_feeds(vaas, coins); // Update price feed with the provided vaas
        let prices = vector::empty<Price>();
        for (i in 0..vector::length<AssetInfo>(&vault_metadata.assets)) {
            let asset_info = vector::borrow<AssetInfo>(&vault_metadata.assets, i);
            let price_temp = pyth::get_price(price_identifier::from_byte_vec(asset_info.pyth_identity));
            vector::push_back(&mut prices, price_temp);
        };
        let (_, s_index) = vector::find<AssetInfo>(supported_assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == type_info::type_name<X>()
        });
        let asset_info = vector::borrow<AssetInfo>(supported_assets, s_index);
        let x_price = pyth::get_price(price_identifier::from_byte_vec(asset_info.pyth_identity));
        (prices, x_price)
    }

    /// Update the price feed with the provided vaas
    fun update_and_fetch_price_without_generic(
        receiver: &signer,
        vault_metadata: &VaultMetadata,
        vaas: vector<vector<u8>>
     ): vector<Price> {
        let coins = coin::withdraw<aptos_coin::AptosCoin>(receiver, pyth::get_update_fee(&vaas)); // Get coins to pay for the update
        pyth::update_price_feeds(vaas, coins); // Update price feed with the provided vaas
        let prices = vector::empty<Price>();
        for (i in 0..vector::length<AssetInfo>(&vault_metadata.assets)) {
            let asset_info = vector::borrow<AssetInfo>(&vault_metadata.assets, i);
            let price_temp = pyth::get_price(price_identifier::from_byte_vec(asset_info.pyth_identity));
            vector::push_back(&mut prices, price_temp);
        };
        prices
    }

    /// calculate the mint shares amount
    fun calc_mint_shares_amount<X>(
        amount: u64,
        decimals: u8,
        prices: &vector<Price>,
        x_price: &Price,
        vault_metadata: &VaultMetadata,
    ): (u64, u128) {
        let price_positive = i64::get_magnitude_if_positive(&price::get_price(x_price)); // This will fail if the price is negative
        let expo_magnitude = i64::get_magnitude_if_negative(&price::get_expo(x_price)); // This will fail if the exponent is positive
        let eq_usd = (price_positive as u128) * (amount as u128) * pow(10, AUM_NAV_DECIMALS) / pow(10, ((expo_magnitude as u8) + decimals));
        let nav = calc_nav(prices, vault_metadata);
        let minted_shares = eq_usd * pow(10, SHARES_TOKEN_DECIMALS) / nav;
        ((minted_shares as u64), eq_usd)
    }

    /// calculate the aum of the vault
    fun calc_aum(
        prices: &vector<Price>,
        vault_metadata: &VaultMetadata,
    ): u128 {
        let aum: u128 = 0;
        for (i in 0..vector::length<AssetInfo>(&vault_metadata.assets)) {
            let asset_info = vector::borrow<AssetInfo>(&vault_metadata.assets, i);
            let price = vector::borrow<Price>(prices, i);
            let price_positive = i64::get_magnitude_if_positive(&price::get_price(price)); // This will fail if the price is negative
            let expo_magnitude = i64::get_magnitude_if_negative(&price::get_expo(price)); // This will fail if the exponent is positive
            if( MAX_U128 / pow(10, AUM_NAV_DECIMALS) / (asset_info.vault_balance as u128) > (price_positive as u128)){
                aum = aum + ( (price_positive as u128) * (asset_info.vault_balance as u128) * pow(10, AUM_NAV_DECIMALS) / pow(10, ((expo_magnitude as u8) + (asset_info.decimals as u8))));
            }else {
                assert!(false, ERROR_OVERFLOW)
            }
        };
        aum
    }

    /// calculate the nav of the vault
    fun calc_nav(
        prices: &vector<Price>,
        vault_metadata: &VaultMetadata,
    ): u128 {
        let aum = calc_aum(prices, vault_metadata);
        let shares_supply = shares_fa_coin::supply(vault_metadata.symbol);
        if (option::is_none(&shares_supply)) {
            NAV_DEFAULT * pow(10, AUM_NAV_DECIMALS)
        }else {
            let shares_supply = option::get_with_default(&shares_supply, 0);
            if (shares_supply == 0) {
                NAV_DEFAULT * pow(10, AUM_NAV_DECIMALS)
            }else {
                aum * pow(10, SHARES_TOKEN_DECIMALS) / shares_supply
            }
        }
    }

    /// calculate the withdraw amounts
    /// return the withdraw amounts, decimals, eq_usds, shares_amount, eq_usd
    fun calc_withdraw_amounts<X,Y,Z>(
        sender_address: address,
        shares_percentage: u64,
        prices: &vector<Price>,
        vault_metadata: &VaultMetadata,
    ): (vector<u64>, vector<u8>, vector<u128>, u64, u128) {
        let shares_amount = shares_fa_coin::balance(vault_metadata.symbol, sender_address) * shares_percentage / WITHDRAW_SHARES_PERCENTAGE_DIVISOR;
        let nav = calc_nav(prices, vault_metadata);
        let eq_usd = (shares_amount as u128) * nav / pow(10, SHARES_TOKEN_DECIMALS);
        let amount_xyz = vector::empty<u64>();
        let decimals_xyz = vector::empty<u8>();
        let eq_usd_xyz = vector::empty<u128>();
        let (_, index_x) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
            let asset : &AssetInfo = asset;
            asset.type_name == type_info::type_name<X>()
        });
        let asset_info_x = vector::borrow<AssetInfo>(&vault_metadata.assets, index_x);
        let price_x = vector::borrow<Price>(prices, index_x);
        let price_positive_x = i64::get_magnitude_if_positive(&price::get_price(price_x)); // This will fail if the price is negative
        let expo_magnitude_x = i64::get_magnitude_if_negative(&price::get_expo(price_x)); // This will fail if the exponent is positive
        let eq_usd_x = (price_positive_x as u128) * (asset_info_x.vault_balance as u128) * pow(10, AUM_NAV_DECIMALS) / pow(10, ((expo_magnitude_x as u8) + (asset_info_x.decimals as u8)));
        if (eq_usd_x >= eq_usd) {
            vector::push_back(&mut eq_usd_xyz, eq_usd);
            vector::push_back(&mut decimals_xyz, asset_info_x.decimals);
            vector::push_back(&mut amount_xyz, (((asset_info_x.vault_balance as u128) * eq_usd / eq_usd_x) as u64));
            (amount_xyz, decimals_xyz, eq_usd_xyz, shares_amount, eq_usd)
        } else {
            vector::push_back(&mut eq_usd_xyz, eq_usd_x);
            vector::push_back(&mut decimals_xyz, asset_info_x.decimals);
            vector::push_back(&mut amount_xyz, asset_info_x.vault_balance);
            let (_, index_y) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                let asset : &AssetInfo = asset;
                asset.type_name == type_info::type_name<Y>()
            });
            let asset_info_y = vector::borrow<AssetInfo>(&vault_metadata.assets, index_y);
            let price_y = vector::borrow<Price>(prices, index_y);
            let price_positive_y = i64::get_magnitude_if_positive(&price::get_price(price_y)); // This will fail if the price is negative
            let expo_magnitude_y = i64::get_magnitude_if_negative(&price::get_expo(price_y)); // This will fail if the exponent is positive
            let eq_usd_y = (price_positive_y as u128) * (asset_info_y.vault_balance as u128) * pow(10, AUM_NAV_DECIMALS) / pow(10, ((expo_magnitude_y as u8) + (asset_info_y.decimals as u8)));
            if (eq_usd_y >= (eq_usd - eq_usd_x)) {
                vector::push_back(&mut eq_usd_xyz, eq_usd - eq_usd_x);
                vector::push_back(&mut decimals_xyz, asset_info_y.decimals);
                vector::push_back(&mut amount_xyz, (((asset_info_y.vault_balance as u128) * (eq_usd - eq_usd_x) / eq_usd_y) as u64));
                (amount_xyz, decimals_xyz, eq_usd_xyz, shares_amount, eq_usd)
            } else {
                vector::push_back(&mut eq_usd_xyz, eq_usd_y);
                vector::push_back(&mut decimals_xyz, asset_info_y.decimals);
                vector::push_back(&mut amount_xyz, asset_info_y.vault_balance);
                let (_, index_z) = vector::find<AssetInfo>(&vault_metadata.assets, |asset| {
                    let asset : &AssetInfo = asset;
                    asset.type_name == type_info::type_name<Z>()
                });
                let asset_info_z = vector::borrow<AssetInfo>(&vault_metadata.assets, index_z);
                let price_z = vector::borrow<Price>(prices, index_z);
                let price_positive_z = i64::get_magnitude_if_positive(&price::get_price(price_z)); // This will fail if the price is negative
                let expo_magnitude_z = i64::get_magnitude_if_negative(&price::get_expo(price_z)); // This will fail if the exponent is positive
                let eq_usd_z = (price_positive_z as u128) * (asset_info_z.vault_balance as u128) * pow(10, AUM_NAV_DECIMALS) / pow(10, ((expo_magnitude_z as u8) + (asset_info_z.decimals as u8)));
                assert!(eq_usd_z >= (eq_usd - eq_usd_x - eq_usd_y), ERROR_COIN_BALANCE_NOT_ENOUGH);
                vector::push_back(&mut eq_usd_xyz, (eq_usd - eq_usd_x - eq_usd_y));
                vector::push_back(&mut decimals_xyz, asset_info_z.decimals);
                vector::push_back(&mut amount_xyz, (((asset_info_z.vault_balance as u128) * (eq_usd - eq_usd_x - eq_usd_y) / eq_usd_z) as u64));
                (amount_xyz, decimals_xyz, eq_usd_xyz, shares_amount, eq_usd)
            }
        }
    }
}