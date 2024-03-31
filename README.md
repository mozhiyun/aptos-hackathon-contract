# aptos-hackathon-contract

## Dependence
Aptos CLI

## How to use

1. Initialize your aptos account on testnet, make sure to choose "testnet"
```shell
$ aptos init
```
you will get a ".aptos" folder in your current folder.
```shell
config.yaml
profiles:
  default:
    private_key: "0x0000000000000000000000000000000000000000000000000000000000000000"
    public_key: "0x0000000000000000000000000000000000000000000000000000000000000000"
    account: 1b3d43b07665057ebe476de266acf2885db6a4b8953f5b910906f0d3a02f2f8e   # your_original_account
    rest_url: "https://fullnode.testnet.aptoslabs.com"
    faucet_url: "https://faucet.testnet.aptoslabs.com"
```
2. Get test APT
```shell
$ aptos account  fund-with-faucet --account your_original_account --amount 100000000
```
3. Create your resource account
```shell
$ aptos move run --function-id '0x1::resource_account::create_resource_account_and_fund' --args 'string:any string you want' 'hex:your_original_account' 'u64:10000000'
```
4. Get your resource account 
```shell
$ aptos account list --account your_original_account
```

Or find it on explorer: https://explorer.testnet.aptos.dev/account/your_original_account

```txt
TYPE:
0x1::resource_account::Container
DATA:
{
  "store": {
    "data": [
      {
        "key": "0x929ac1ea533d04f7d98c234722b40c229c3adb1838b27590d2237261c8d52b68",
        "value": {
          "account": "0x929ac1ea533d04f7d98c234722b40c229c3adb1838b27590d2237261c8d52b68"  # your_resource_account
        }
      }
    ]
  }
}
```
5. Replace your_original_account with your_resource_account in config.yaml


6. Edit Move.toml file

  ```shell
[package]
name = "cbindex"
version = "1.0.0"
authors = []
[addresses]
cbindex = "71e609393d30dfacaf477c9a9cd7824ae14b5f8d2a20c0b1917325d41e4a4aac" //repalce this with your_resource_account 
origin = "1b3d43b07665057ebe476de266acf2885db6a4b8953f5b910906f0d3a02f2f8e" // repalce this with your_original_account which you created the resource account
admin = "1b3d43b07665057ebe476de266acf2885db6a4b8953f5b910906f0d3a02f2f8e" // need to create an admin account, and replace this.
zero = "0000000000000000000000000000000000000000000000000000000000000000"
pyth = "0x7e783b349d3e89cf5931af376ebeadbfab855b3fa239b7ada8f5a92fbea6b387"
deployer = "0xb31e712b26fd295357355f6845e77c888298636609e93bc9b05f0f604049f434"
wormhole = "0x5bc11445584a763c1fa7ed39081f1b920954da14e04b32440cba863d03e19625"
``` 
7. Compile code
```shell
$ aptos move compile
```
8. Publish package
```shell
$ aptos move publish
```