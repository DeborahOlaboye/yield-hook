# YieldHook — Uniswap V4 Yield-Bearing Liquidity Hook

A Uniswap V4 hook that earns external yield on top of standard LP swap fees.

## How It Works

Every swap through a YieldHook-enabled pool triggers a small **yield fee** (default: 0.10%) taken from the swap output. These tokens are deposited into a **yield-bearing vault** (ERC-4626 compatible — e.g., Aave, Morpho).

Anyone can call `compound(poolKey)` at any time to harvest the accumulated vault yield and donate it back to the pool's in-range LPs. LPs earn:

1. **Standard swap fees** (e.g., 0.30% from the pool fee tier)
2. **Yield from the external vault** (e.g., 5–15% APY from Aave)

```
Swap → afterSwap hook → take 0.10% fee → deposit to Aave
                                            ↓
                     compound() → redeem from Aave → donate to LPs
```

## Hook Flags

| Flag | Purpose |
|---|---|
| `AFTER_SWAP_FLAG` | Intercept every swap |
| `AFTER_SWAP_RETURNS_DELTA_FLAG` | Pull fee tokens from swapper output via return delta |

## Architecture

```
src/
  YieldHook.sol          — Main hook contract
  interfaces/
    IYieldVault.sol      — ERC-4626-compatible vault interface

test/
  YieldHook.t.sol        — 17 comprehensive tests
  mocks/
    MockERC20.sol        — Test ERC-20
    MockYieldVault.sol   — Mock ERC-4626 vault with simulateYield()
  utils/
    HookMiner.sol        — CREATE2 salt mining for hook deployment

script/
  DeployYieldHook.s.sol  — Deployment script (Unichain Sepolia)
```

## Setup

```bash
forge build
forge test
```

## Testing

```bash
forge test -vv
```

17 tests pass covering:
- Hook address encodes correct permission flags
- Yield fee collected on every swap (both directions)
- Fee amount matches 0.10% BPS configuration
- `pendingYield()` view reflects vault share value + simulated yield
- `compound()` donates fees + vault yield back to pool LPs
- Permissionless compound callable by anyone
- Repeated compound works after new fee accumulation

## Testnet Deployment (Unichain Sepolia)

```bash
export PRIVATE_KEY=<your_key>
export UNICHAIN_SEPOLIA_RPC=<rpc_url>

forge script script/DeployYieldHook.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

After deployment, register yield vaults:
```solidity
hook.setVault(currency0, IYieldVault(AAVE_V3_VAULT_ADDRESS));
hook.setVault(currency1, IYieldVault(AAVE_V3_VAULT_ADDRESS));
```

## Key Addresses

| Network | Contract | Address |
|---|---|---|
| Unichain Sepolia | PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| All chains | CREATE2 Deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

## Capstone Submission — Atrium Academy Uniswap V4 Hooks Course

**Uniqueness**: Composable yield layer using `afterSwapReturnDelta` — LPs earn external APY with zero UX change.

**Impact**: Directly addresses LP capital efficiency. Idle capital earns yield; every swap contributes.

**Functionality**: 17 passing tests, CREATE2 testnet deployment script.
