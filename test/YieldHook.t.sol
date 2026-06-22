// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {YieldHook} from "../src/YieldHook.sol";
import {IYieldVault} from "../src/interfaces/IYieldVault.sol";
import {MockYieldVault} from "./mocks/MockYieldVault.sol";
import {MockERC20 as TestMockERC20} from "./mocks/MockERC20.sol";

contract YieldHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ── Hook address with AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG ──
    // AFTER_SWAP_FLAG         = 1 << 6 = 64  = 0x40
    // AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2 = 4   = 0x04
    // Combined bits: 0x44
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    YieldHook hook;
    MockYieldVault vault0;
    MockYieldVault vault1;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy PoolManager and routers
        deployFreshManagerAndRouters();
        // Deploy and mint tokens, sorted as currency0/currency1
        deployMintAndApprove2Currencies();

        // Deploy hook at an address with the correct permission bits using vm.etch
        address hookAddr = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS));
        YieldHook impl = new YieldHook(manager);
        vm.etch(hookAddr, address(impl).code);
        hook = YieldHook(hookAddr);

        // Deploy yield vaults backed by the sorted ERC-20 tokens
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        // Wrap in TestMockERC20-compatible vault — vault needs transferFrom support
        // We use MockYieldVault which calls transferFrom; mint approvals needed
        vault0 = new MockYieldVault(TestMockERC20(address(token0)));
        vault1 = new MockYieldVault(TestMockERC20(address(token1)));

        // Register vaults with the hook
        hook.setVault(currency0, IYieldVault(address(vault0)));
        hook.setVault(currency1, IYieldVault(address(vault1)));

        // Initialize pool with 1:1 price and add liquidity
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add deep liquidity across a very wide tick range so swaps don't move out of range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    // ── Deployment tests ──────────────────────────────────────────────────────

    function test_hookAddress_hasCorrectFlags() public view {
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_FLAG));
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_INITIALIZE_FLAG));
    }

    function test_vaultRegistration() public view {
        assertEq(address(hook.vaults(currency0)), address(vault0));
        assertEq(address(hook.vaults(currency1)), address(vault1));
    }

    function test_setVault_revertsOnAssetMismatch() public {
        // vault0 is backed by token0; trying to register for currency1 should revert
        vm.expectRevert(YieldHook.VaultAssetMismatch.selector);
        hook.setVault(currency1, IYieldVault(address(vault0)));
    }

    // ── Swap fee collection tests ─────────────────────────────────────────────

    function test_swap_collectsYieldFee_zeroForOne() public {
        uint256 swapAmount = 1 ether;

        // token0 → token1 swap (zeroForOne): fee taken from currency1 (output)
        uint256 sharesBefore = hook.poolShares(poolKey.toId(), currency1);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES);

        uint256 sharesAfter = hook.poolShares(poolKey.toId(), currency1);
        assertGt(sharesAfter, sharesBefore, "no shares accrued after swap");
    }

    function test_swap_collectsYieldFee_oneForZero() public {
        uint256 swapAmount = 1 ether;

        // token1 → token0 swap (oneForZero): fee taken from currency0 (output)
        uint256 sharesBefore = hook.poolShares(poolKey.toId(), currency0);

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES);

        uint256 sharesAfter = hook.poolShares(poolKey.toId(), currency0);
        assertGt(sharesAfter, sharesBefore, "no shares accrued after reverse swap");
    }

    function test_swap_feeAmount_matchesBps() public {
        uint256 swapAmount = 10_000 ether;

        // Snapshot vault balance before
        uint256 vaultBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1));

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        BalanceDelta delta = swapRouter.swap(
            poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );

        uint256 vaultBalAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1));
        uint256 deposited = vaultBalAfter - vaultBalBefore;

        // For zeroForOne, delta.amount1() is POSITIVE (swapper receives currency1)
        // The hook reduced the swapper's output by `fee`, so: grossOutput = netOutput + fee
        uint256 netOutput = uint256(uint128(delta.amount1()));
        uint256 grossOutput = netOutput + deposited;
        uint256 expectedFee = (grossOutput * hook.YIELD_FEE_BPS()) / hook.BPS_DENOMINATOR();

        assertApproxEqAbs(deposited, expectedFee, 1, "vault deposit != expected yield fee");
    }

    function test_swap_noFee_whenNoVault() public {
        // Remove vault for currency1
        hook.setVault(currency1, IYieldVault(address(0)));

        uint256 sharesBefore = hook.poolShares(poolKey.toId(), currency1);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES);

        assertEq(hook.poolShares(poolKey.toId(), currency1), sharesBefore, "shares changed without vault");
    }

    // ── pendingYield view ─────────────────────────────────────────────────────

    function test_pendingYield_increasesAfterSwap() public {
        uint256 yieldBefore = hook.pendingYield(poolKey, currency1);

        _doSwap(true, 5 ether);

        uint256 yieldAfter = hook.pendingYield(poolKey, currency1);
        assertGt(yieldAfter, yieldBefore, "pendingYield did not increase");
    }

    function test_pendingYield_reflectsVaultYield() public {
        _doSwap(true, 5 ether);

        uint256 pendingBefore = hook.pendingYield(poolKey, currency1);

        // Vault earns 10% yield externally
        vault1.simulateYield(pendingBefore / 10);

        uint256 pendingAfter = hook.pendingYield(poolKey, currency1);
        assertGt(pendingAfter, pendingBefore, "vault yield not reflected");
    }

    // ── Compound tests ────────────────────────────────────────────────────────

    function test_compound_revertsWithNoAccruedFees() public {
        vm.expectRevert(YieldHook.ZeroCompound.selector);
        hook.compound(poolKey);
    }

    function test_compound_donatesFeesBackToPool() public {
        // Accumulate fees via swaps
        _doSwap(true, 10 ether);
        _doSwap(false, 10 ether);

        uint256 pendingCurrency1 = hook.pendingYield(poolKey, currency1);
        uint256 pendingCurrency0 = hook.pendingYield(poolKey, currency0);

        // Compound: redeem vault shares and donate to pool
        hook.compound(poolKey);

        // Shares should be zeroed
        assertEq(hook.poolShares(poolKey.toId(), currency1), 0, "shares not cleared after compound (currency1)");
        assertEq(hook.poolShares(poolKey.toId(), currency0), 0, "shares not cleared after compound (currency0)");

        // totalYieldDonated should reflect what was donated
        uint256 total = hook.totalYieldDonated(poolKey.toId());
        assertApproxEqAbs(total, pendingCurrency1 + pendingCurrency0, 5, "totalYieldDonated mismatch");
    }

    function test_compound_withVaultYield_donatesMore() public {
        _doSwap(true, 10 ether);

        // Simulate vault earning 20% yield
        uint256 pending = hook.pendingYield(poolKey, currency1);
        vault1.simulateYield(pending / 5);

        uint256 pendingWithYield = hook.pendingYield(poolKey, currency1);

        hook.compound(poolKey);

        uint256 donated = hook.totalYieldDonated(poolKey.toId());
        // Donated should be >= original fees (now includes vault yield)
        assertGe(donated, pending, "donated less than original fees");
        assertApproxEqAbs(donated, pendingWithYield, 5, "donated does not match pendingYield with vault yield");
    }

    function test_compound_isPermissionless() public {
        _doSwap(true, 5 ether);

        // Anyone can call compound
        vm.prank(alice);
        hook.compound(poolKey);

        assertEq(hook.poolShares(poolKey.toId(), currency1), 0);
    }

    function test_compound_canBeCalledRepeatedly() public {
        _doSwap(true, 5 ether);
        hook.compound(poolKey);

        // Second compound should revert with ZeroCompound (no new fees yet)
        vm.expectRevert(YieldHook.ZeroCompound.selector);
        hook.compound(poolKey);

        // After another swap, compound works again
        _doSwap(true, 5 ether);
        hook.compound(poolKey); // should not revert
    }

    // ── Multiple swaps accumulation ───────────────────────────────────────────

    function test_multipleSwaps_accumulateShares() public {
        for (uint256 i = 0; i < 5; i++) {
            _doSwap(true, 0.01 ether);
        }

        uint256 shares = hook.poolShares(poolKey.toId(), currency1);
        assertGt(shares, 0, "no shares after 5 swaps");

        // Pending yield should be 5x a single swap's fee (approximately)
        uint256 pending = hook.pendingYield(poolKey, currency1);
        assertGt(pending, 0, "no pending yield after 5 swaps");
    }

    // ── Per-pool yield fee override ───────────────────────────────────────────

    function test_setPoolYieldFee_overridesGlobal() public {
        // First measure collection with default 10bps
        uint256 vaultBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1));
        _doSwap(true, 1 ether);
        uint256 defaultDeposited = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1)) - vaultBefore;

        // Switch to opposite direction to reset price, then swap again with higher fee
        _doSwap(false, 1 ether);

        // Now set pool fee to 0.20% (double the default)
        hook.setPoolYieldFee(poolKey, 20);
        uint256 vaultBefore2 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1));
        _doSwap(true, 1 ether);
        uint256 highFeeDeposited = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1)) - vaultBefore2;

        // 20bps should collect more than 10bps default
        assertGt(highFeeDeposited, defaultDeposited, "higher fee BPS should collect more");
    }

    function test_setPoolYieldFee_revertsIfAboveMax() public {
        vm.expectRevert(YieldHook.FeeTooHigh.selector);
        hook.setPoolYieldFee(poolKey, 101); // 1.01% > MAX_YIELD_FEE_BPS (1%)
    }

    // ── Getters/edge cases ────────────────────────────────────────────────────

    function test_pendingYield_zeroWithNoShares() public view {
        // Before any swaps, no shares → pending should be 0
        assertEq(hook.pendingYield(poolKey, currency1), 0);
    }

    function test_pendingYield_zeroWithNoVault() public {
        hook.setVault(currency0, IYieldVault(address(0)));
        _doSwap(false, 1 ether);
        assertEq(hook.pendingYield(poolKey, currency0), 0);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _doSwap(bool zeroForOne, uint256 amount) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        return swapRouter.swap(
            poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ZERO_BYTES
        );
    }
}
