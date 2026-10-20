// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDropToken} from "../interfaces/IDropToken.sol";

/// @title DropTokenReference
/// @notice Reference implementation of the Drop token, used by the vault's tests and as the brief for
///         IMD's swarm, which writes the production token. Behaviour, per the v2 spec:
///         - Fixed supply minted once to the deployer (IMD's factory). No owner, mint, pause or blacklist.
///         - 6% tax on tokens moving out of the pool manager (buys) and into it (sells).
///           Buys: the buyer receives 94%; 6% goes to the vault.
///           Sells: the pool manager receives exactly the amount sent; the seller pays a further 6% on top,
///           so V4's settle accounting stays exact.
///         - Exempt from tax: any transfer from or to the factory (its launch payout and its launcher-fee take),
///           and any transfer to or from the vault.
///         - Hold clock: any outgoing transfer resets it to now; incoming tokens count as zero hours held
///           and blend in weighted by balance.
///         - Balance and hold-clock checkpoints by timestamp (block.number is unreliable on Arbitrum chains).
///         - A list of wallets that reached MIN_BALANCE; the vault removes those now below it between drops.
///         - For the first 15 minutes, a single transfer out of the pool manager (not a whole transaction) can't
///           exceed BUY_CAP. [A6-4]
///         - The claim contract is detected as the address the factory pays exactly 10% of supply to, in the launch
///           second only (block.timestamp == LAUNCH_TIME, which can span several Robinhood blocks; in practice the
///           factory's creation transaction). isExcluded never changes after the launch second, and past
///           checkpoints never change. [A8-7, R9-9]
///         - Listed wallets that fall below MIN_BALANCE are removed between drops by the vault (compact).
///         - Known limit: trades netted inside the PoolManager (ERC-6909 claims) move no tokens and can't be taxed.
contract DropTokenReference is IDropToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000e18;

    uint256 public constant TAX_BPS = 600;
    uint256 public constant LAUNCH_WINDOW = 15 minutes;
    uint256 public constant BUY_CAP = 5_000_000e18;
    uint256 public constant override MIN_BALANCE = 10_000e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable POOL_MANAGER;
    address public immutable override VAULT;
    address public immutable override FACTORY;
    uint256 public immutable override LAUNCH_TIME;
    address[5] public teamWallets;
    address public claimContract;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public holdStart;

    struct Checkpoint {
        uint48 time;
        uint48 holdStart;
        uint160 balance;
    }

    mapping(address => Checkpoint[]) private _checkpoints;
    mapping(address => bool) public listed;
    address[] private _listed;
    uint256 public compactCursor;
    uint256 public constant HOLD_HORIZON = 72 hours;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TaxCollected(uint256 tokens, bool isBuy);

    error InsufficientBalance();
    error InsufficientAllowance();
    error BuyCapExceeded();
    error NotVault();

    constructor(string memory name_, string memory symbol_, address poolManager, address vault, address[5] memory team) {
        name = name_;
        symbol = symbol_;
        POOL_MANAGER = poolManager;
        VAULT = vault;
        FACTORY = msg.sender;
        LAUNCH_TIME = block.timestamp;
        teamWallets = team;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    // ------------------------------------------------------------------ ERC-20

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            // a taxed sell debits the owner amount + 6%, so the allowance must cover that too [A1-23]
            uint256 debit = amount;
            if (to == POOL_MANAGER && from != FACTORY && from != VAULT) debit += amount * TAX_BPS / 10_000;
            if (a < debit) revert InsufficientAllowance();
            allowance[from][msg.sender] = a - debit;
        }
        _transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------ transfers and tax

    function _transfer(address from, address to, uint256 amount) internal {
        // Detect IMD's claim contract during the launch payout: the factory's transfer of exactly the swarm's
        // 10% to an address that isn't the pool manager or the vault. [A1-12] [A8-7] Only in the launch second
        // (block.timestamp == LAUNCH_TIME), so isExcluded can never change after it: the vault binds later and its
        // drops rely on that. [R9-9] That second can span several Robinhood blocks (ArbOS gives them one timestamp),
        // and only the factory's own transfers count. On IMD's flow the 10% payout is the first transfer after the
        // mint, in the factory's creation transaction, so claimContract is set before any other factory transfer.
        // A flow that paid it in a later second would never be detected; bindToken's extraExcluded covers that.
        if (
            from == FACTORY && claimContract == address(0) && to != POOL_MANAGER && to != VAULT
                && amount == totalSupply / 10 && block.timestamp == LAUNCH_TIME
        ) claimContract = to;

        // Claims out of the claim contract are ordinary transfers and get no exemption. [A1-11]
        // [A5-10] IMD's launcher-fee take (PoolManager -> FACTORY) is exempt too, so the factory's own fee is never
        // taxed and never hits BUY_CAP. [A6-13] The token can't tell that take from anyone else's swap output taken to
        // FACTORY, which is therefore untaxed and uncapped too, but stranded: the factory's per-recipient fee accounting
        // has no sweep, and FACTORY is excluded. The production token's exemption must stay this narrow
        bool exempt = from == FACTORY || from == VAULT || to == VAULT || to == FACTORY;
        uint256 tax;
        if (!exempt && from == POOL_MANAGER) {
            if (block.timestamp < LAUNCH_TIME + LAUNCH_WINDOW && amount > BUY_CAP) revert BuyCapExceeded();
            tax = amount * TAX_BPS / 10_000; // buy: taken out of what the buyer receives
            _move(from, VAULT, tax);
            _move(from, to, amount - tax);
            emit TaxCollected(tax, true);
            return;
        }
        if (!exempt && to == POOL_MANAGER) {
            tax = amount * TAX_BPS / 10_000; // sell: charged on top of the amount the pool receives
            if (balanceOf[from] < amount + tax) revert InsufficientBalance();
            _move(from, VAULT, tax);
            emit TaxCollected(tax, false);
        }
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 fb = balanceOf[from];
        if (fb < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fb - amount;
        }
        holdStart[from] = block.timestamp; // any outgoing transfer resets the clock
        uint256 tb = balanceOf[to];
        uint256 hs = holdStart[to];
        // clamp to the multiplier horizon first, so age beyond 72 hours can't be banked [A1-5]
        if (block.timestamp > HOLD_HORIZON && hs < block.timestamp - HOLD_HORIZON) hs = block.timestamp - HOLD_HORIZON;
        holdStart[to] = tb == 0 ? block.timestamp : (tb * hs + amount * block.timestamp) / (tb + amount); // incoming counts as zero age
        balanceOf[to] = tb + amount;
        // the pool manager and vault are never read as holders, so skip their checkpoints [A1-24]
        if (from != POOL_MANAGER && from != VAULT) _checkpoint(from);
        if (to != POOL_MANAGER && to != VAULT) _checkpoint(to);
        if (!listed[to] && balanceOf[to] >= MIN_BALANCE && !isExcluded(to)) {
            listed[to] = true;
            _listed.push(to);
            emit Listed(to, _listed.length - 1); // [A4-L] lets verifiers rebuild any drop's list
        }
        emit Transfer(from, to, amount);
    }

    function _checkpoint(address a) internal {
        Checkpoint[] storage cps = _checkpoints[a];
        Checkpoint memory cp = Checkpoint(uint48(block.timestamp), uint48(holdStart[a]), uint160(balanceOf[a]));
        uint256 n = cps.length;
        if (n > 0 && cps[n - 1].time == cp.time) cps[n - 1] = cp;
        else cps.push(cp);
    }

    // ------------------------------------------------------------------ IDropToken views

    function _at(address a, uint256 t) internal view returns (Checkpoint memory cp) {
        Checkpoint[] storage cps = _checkpoints[a];
        uint256 lo = 0;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].time <= t) lo = mid + 1;
            else hi = mid;
        }
        if (lo > 0) cp = cps[lo - 1];
    }

    function balanceAt(address account, uint256 timestamp) external view returns (uint256) {
        return _at(account, timestamp).balance;
    }

    function holdStartAt(address account, uint256 timestamp) external view returns (uint256) {
        return _at(account, timestamp).holdStart;
    }

    function listedCount() external view returns (uint256) {
        return _listed.length;
    }

    function listedAt(uint256 index) external view returns (address) {
        return _listed[index];
    }

    /// @notice Removes listed wallets now below MIN_BALANCE, checking up to `maxSteps` entries from a rolling
    ///         cursor. Only the vault can call it, and only between drops. [A1-7]
    function compact(uint256 maxSteps) external {
        if (msg.sender != VAULT) revert NotVault();
        uint256 i = compactCursor;
        for (uint256 s = 0; s < maxSteps; s++) {
            uint256 len = _listed.length;
            if (i >= len) {
                i = 0;
                break;
            }
            address a = _listed[i];
            // below the minimum now AND at the end of the previous second, so a wallet eligible at a snapshot
            // taken this second is never removed [A2-3]
            if (balanceOf[a] < MIN_BALANCE && _at(a, block.timestamp - 1).balance < MIN_BALANCE) {
                emit Delisted(a, i, _listed[len - 1]); // [A4-L]
                _listed[i] = _listed[len - 1];
                _listed.pop();
                listed[a] = false;
            } else {
                i++;
            }
        }
        compactCursor = i;
    }

    function isExcluded(address a) public view returns (bool) {
        if (a == POOL_MANAGER || a == VAULT || a == FACTORY || a == claimContract || a == DEAD || a == address(0)) {
            return true;
        }
        for (uint256 i = 0; i < 5; i++) {
            if (a == teamWallets[i]) return true;
        }
        return false;
    }
}
