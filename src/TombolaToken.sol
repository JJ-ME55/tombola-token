// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DropTokenReference} from "./reference/DropTokenReference.sol";

/// @title Tombola (TOMBOLA)
/// @notice The Tombola token: the reference DropTokenReference, unchanged, with Tombola's addresses fixed in code.
///         No constructor arguments. IMD's factory deploys it and receives the whole supply.
///         Chain: robinhood (4663).
contract TombolaToken is DropTokenReference {
    constructor()
        DropTokenReference(
            "Tombola",
            "TOMBOLA",
            0x8366a39CC670B4001A1121B8F6A443A643e40951, // Uniswap v4 PoolManager
            0x331100A344F01C729f15165BA74AA54e3207566d, // DropVault
            [
                0x758e786d94F8B3999abCbC502aDc0C3C47D3d011, // team token wallet, 2%
                0xc48cC3f07b0285C84de83f24e531C1FEB97aCB12, // team token wallet, 2%
                0xC26Ff486727167D6AC525E417F712dCdADe86eB5, // team token wallet, 1%
                0x02b4bd9cc103fD502B2F3f601E29E6Ae2039AC85, // team token wallet, 1%
                0xbdD2e507de380b000409Fdba732df5e30888E7A0 // team fee wallet, 0.4% of the tax in ETH
            ]
        )
    {}
}
