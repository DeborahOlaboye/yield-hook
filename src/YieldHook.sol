// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IYieldVault} from "./interfaces/IYieldVault.sol";

/// @title YieldHook
/// @notice A Uniswap V4 hook that captures a configurable yield fee on every swap,
///         deposits those tokens into a yield-bearing vault (ERC-4626 compatible),
///         and lets anyone call compound() to harvest vault yield and donate it back
///         to the pool's in-range LPs — earning swap fees AND external yield.
///
/// Hook flags required (encoded in address via CREATE2):
///   AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG
contract YieldHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ── Constants ────────────────────────────────────────────────────────────

    /// @dev 0.10% yield fee taken from each swap's output
    uint256 public constant YIELD_FEE_BPS = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ── Storage ──────────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager;

    /// @notice Yield vault registered for each currency (address(0) = no vault)
    mapping(Currency => IYieldVault) public vaults;

    /// @notice Vault shares held by this hook, per pool per currency
    mapping(PoolId => mapping(Currency => uint256)) public poolShares;

    /// @notice Cumulative yield donated back to each pool (for analytics / demo)
    mapping(PoolId => uint256) public totalYieldDonated;

    // ── Events ───────────────────────────────────────────────────────────────

    event VaultSet(Currency indexed currency, address vault);
    event YieldFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event YieldCompounded(PoolId indexed poolId, Currency indexed currency, uint256 yieldAmount);

    // ── Errors ───────────────────────────────────────────────────────────────

    error NotPoolManager();
    error VaultAssetMismatch();
    error ZeroCompound();

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    /// @notice Register a yield vault for a currency. Pass address(0) to disable.
    /// @param currency The token currency to register a vault for
    /// @param vault    ERC-4626-compatible vault whose underlying asset matches `currency`
    function setVault(Currency currency, IYieldVault vault) external {
        if (address(vault) != address(0)) {
            if (vault.asset() != Currency.unwrap(currency)) revert VaultAssetMismatch();
        }
        vaults[currency] = vault;
        emit VaultSet(currency, address(vault));
    }

    // ── IHooks ───────────────────────────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return _getPermissions();
    }

    function _getPermissions() internal pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice After a swap, take a small yield fee from the swap output and deposit it into the vault.
    /// @dev    Uses AFTER_SWAP_RETURNS_DELTA_FLAG so the hook can intercept tokens directly.
    ///         The returned int128 reduces the swapper's received output by the fee amount.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        // Determine output currency and its delta (output delta is negative = swapper receives)
        (Currency outputCurrency, int128 outputDelta) = params.zeroForOne
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // outputDelta is positive when the swapper receives tokens (pool owes swapper)
        if (outputDelta <= 0) return (IHooks.afterSwap.selector, 0);

        IYieldVault vault = vaults[outputCurrency];
        if (address(vault) == address(0)) return (IHooks.afterSwap.selector, 0);

        uint256 absOutput = uint256(uint128(outputDelta));
        uint256 fee = (absOutput * YIELD_FEE_BPS) / BPS_DENOMINATOR;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Pull `fee` tokens from the PoolManager to this hook
        poolManager.take(outputCurrency, address(this), fee);

        // Approve vault and deposit
        address token = Currency.unwrap(outputCurrency);
        IERC20Minimal(token).approve(address(vault), fee);
        uint256 shares = vault.deposit(fee, address(this));

        PoolId poolId = key.toId();
        poolShares[poolId][outputCurrency] += shares;

        emit YieldFeeCollected(poolId, outputCurrency, fee);

        // Return positive value: the swapper's output is reduced by `fee`
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // ── Compound ─────────────────────────────────────────────────────────────

    struct CompoundData {
        PoolKey key;
        bool processToken0;
        bool processToken1;
    }

    /// @notice Harvest accumulated vault yield and donate it back to the pool LPs.
    ///         Permissionless — anyone can call to trigger compounding.
    /// @param key The pool to compound yield for
    function compound(PoolKey calldata key) external {
        PoolId poolId = key.toId();

        bool hasToken0 = poolShares[poolId][key.currency0] > 0 && address(vaults[key.currency0]) != address(0);
        bool hasToken1 = poolShares[poolId][key.currency1] > 0 && address(vaults[key.currency1]) != address(0);

        if (!hasToken0 && !hasToken1) revert ZeroCompound();

        // Redeem shares BEFORE entering unlock (vault interactions are external)
        uint256 amount0;
        uint256 amount1;

        if (hasToken0) {
            uint256 shares0 = poolShares[poolId][key.currency0];
            poolShares[poolId][key.currency0] = 0;
            amount0 = vaults[key.currency0].redeem(shares0, address(this), address(this));
        }

        if (hasToken1) {
            uint256 shares1 = poolShares[poolId][key.currency1];
            poolShares[poolId][key.currency1] = 0;
            amount1 = vaults[key.currency1].redeem(shares1, address(this), address(this));
        }

        // Enter the unlock to donate redeemed tokens back to pool LPs
        poolManager.unlock(abi.encode(key, amount0, amount1));

        if (amount0 > 0) emit YieldCompounded(poolId, key.currency0, amount0);
        if (amount1 > 0) emit YieldCompounded(poolId, key.currency1, amount1);
        totalYieldDonated[poolId] += amount0 + amount1;
    }

    /// @notice IUnlockCallback — called by PoolManager after compound() triggers unlock
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));

        // Settle token0 into PoolManager then donate
        if (amount0 > 0) {
            _settleToken(key.currency0, amount0);
        }
        if (amount1 > 0) {
            _settleToken(key.currency1, amount1);
        }

        // Donate all settled tokens to in-range LPs
        poolManager.donate(key, amount0, amount1, "");

        // Pay off the donate debt by settling (tokens already synced above)
        // The donate creates a positive delta (we owe the PM), already settled above
        return "";
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    function _settleToken(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        poolManager.sync(currency);
        IERC20Minimal(token).transfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Current redeemable value of accumulated vault shares for a pool/currency
    function pendingYield(PoolKey calldata key, Currency currency) external view returns (uint256) {
        IYieldVault vault = vaults[currency];
        if (address(vault) == address(0)) return 0;
        return vault.convertToAssets(poolShares[key.toId()][currency]);
    }
}
