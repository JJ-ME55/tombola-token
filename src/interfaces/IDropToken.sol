// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What DropVault needs from the token. IMD's swarm writes the production token;
///         it must expose exactly this, with the behaviour described in DropTokenReference.
/// @dev Known limit: Uniswap v4 lets traders hold and net balances inside the PoolManager (ERC-6909 claims,
///      netting within one unlock). Such trades move no ERC-20 tokens, so no token can tax them. The vault's
///      defences don't rely on the tax as a cost to attackers. [A1-3]
///      Hold clock: before incoming tokens are blended in, the receiver's clock is clamped to at most
///      72 hours old, so age beyond the full multiplier can't be banked. [A1-5]
interface IDropToken {
    /// @notice A wallet was appended to the list at `index`. [A4-L]
    event Listed(address indexed account, uint256 index);
    /// @notice `account` was removed from `index` by compact, and `moved` (the former last entry) now sits there.
    ///         Replaying Listed and Delisted events up to a drop's DropStarted log rebuilds that drop's list. [A4-L]
    event Delisted(address indexed account, uint256 index, address moved);

    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice When trading opened (the deploy timestamp). Every drop time counts from it.
    function LAUNCH_TIME() external view returns (uint256);
    /// @notice The vault address written into the token.
    function VAULT() external view returns (address);
    /// @notice Minimum balance for a wallet to be listed and eligible.
    function MIN_BALANCE() external view returns (uint256);

    /// @notice Balance of `account` at the end of second `timestamp`. Once that second has passed, the answer never
    ///         changes (the same holds for holdStartAt): a drop's weights are summed and later recomputed. [A8-7]
    function balanceAt(address account, uint256 timestamp) external view returns (uint256);
    /// @notice Hold-clock start of `account` at the end of second `timestamp`.
    function holdStartAt(address account, uint256 timestamp) external view returns (uint256);

    /// @notice Wallets that have reached MIN_BALANCE. The list only grows during a drop; between drops the vault
    ///         calls compact to remove wallets now below the minimum.
    function listedCount() external view returns (uint256);
    function listedAt(uint256 index) external view returns (address);

    /// @notice Addresses that can never win: pool manager, vault, factory, claim contract, team wallets, dead.
    ///         The answer for any address never changes after the launch second (block.timestamp == LAUNCH_TIME, in
    ///         practice the factory's creation transaction; the claim contract is detected only then). The vault
    ///         reads it live while summing a drop and again when picking the winner. [A8-7, R9-9]
    function isExcluded(address account) external view returns (bool);

    /// @notice Removes listed wallets that are below MIN_BALANCE now AND were below it at the end of the previous
    ///         second, up to `maxSteps` checks. Callable only by the vault, which calls it only while no drop is in
    ///         progress, so a drop's frozen list never moves and a wallet eligible at a snapshot taken this second
    ///         is never removed. [A2-3]
    function compact(uint256 maxSteps) external;

    /// @notice IMD's swarm claim contract, detected as the factory's transfer of exactly 10% of supply in the launch
    ///         second (block.timestamp == LAUNCH_TIME, which can span several Robinhood blocks; in practice the
    ///         factory's creation transaction, where IMD pays it first after the mint); 0 for good if it wasn't
    ///         detected then (the vault excludes the factory's distributor itself). [A3-4, A8-7, R9-9]
    function claimContract() external view returns (address);

    /// @notice The address that deployed the token and received its whole supply: IMD's ProjectFactory. Bind requires
    ///         it to be the factory the vault was deployed with, and reads the launch's records from it. [A5-1, A6-4]
    function FACTORY() external view returns (address);
}
