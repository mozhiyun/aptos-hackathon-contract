#!/usr/bin/env bash

aptos move run --function-id 'default::vault::deposit' --type-args 0x061ee487b2de2a51fa4f18827ca771862355c71e74ffd993e94f2e1868284592::eth::ETH --args u64:1000 --profile investor