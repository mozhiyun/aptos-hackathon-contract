aptos move run --function-id '0x1::resource_account::create_resource_account_and_fund' --args 'string:1aaaaa' 'hex:1b3d43b07665057ebe476de266acf2885db6a4b8953f5b910906f0d3a02f2f8e' 'u64:10000000'

aptos move view --function-id 'default::vault::get_vault_list'