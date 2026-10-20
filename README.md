# Tombola token

The Tombola token for IMD's launchpad. `src/TombolaToken.sol` wraps the reference `DropTokenReference`, unchanged, with Tombola's fixed addresses on robinhood:

| Role | Address |
| --- | --- |
| Uniswap v4 PoolManager | 0x8366a39CC670B4001A1121B8F6A443A643e40951 |
| DropVault | 0x331100A344F01C729f15165BA74AA54e3207566d |
| Team token wallets (2%, 2%, 1%, 1%) | 0x758e786d94F8B3999abCbC502aDc0C3C47D3d011, 0xc48cC3f07b0285C84de83f24e531C1FEB97aCB12, 0xC26Ff486727167D6AC525E417F712dCdADe86eB5, 0x02b4bd9cc103fD502B2F3f601E29E6Ae2039AC85 |
| Team fee wallet | 0xbdD2e507de380b000409Fdba732df5e30888E7A0 |

Launch it exactly as written. No file under `src/` may change: every rule in DropTokenReference is a requirement the vault relies on, and the vault's bind script refuses a deployed token whose code differs from this repository's build.
