// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {YieldHook} from "../src/YieldHook.sol";
import {IYieldVault} from "../src/interfaces/IYieldVault.sol";

/// @notice Deploy YieldHook to Unichain Sepolia testnet
/// Usage:
///   forge script script/DeployYieldHook.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC \
///     --broadcast \
///     --private-key $PRIVATE_KEY \
///     -vvvv
contract DeployYieldHook is Script {
    // Unichain Sepolia PoolManager
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    // Standard CREATE2 deployer (same on all EVM chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Hook needs AFTER_SWAP_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG
    uint160 constant HOOK_FLAGS = uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    function run() external {
        // Mine a salt that produces an address with the right hook permission bits
        bytes memory constructorArgs = abi.encode(address(POOL_MANAGER));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(YieldHook).creationCode,
            constructorArgs
        );

        console2.log("Mined hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        vm.startBroadcast();

        // Deploy using CREATE2 with the mined salt
        YieldHook hook = new YieldHook{salt: salt}(IPoolManager(POOL_MANAGER));
        require(address(hook) == hookAddress, "hook address mismatch");

        console2.log("YieldHook deployed at:", address(hook));
        console2.log("Verify hook flags are set correctly:");
        console2.log("  AFTER_SWAP_FLAG:", Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_FLAG));
        console2.log(
            "  AFTER_SWAP_RETURNS_DELTA_FLAG:",
            Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        );

        vm.stopBroadcast();

        // Next steps (run separately after vault addresses are known):
        // hook.setVault(currency0, IYieldVault(AAVE_V3_USDC_VAULT_ADDRESS));
        // hook.setVault(currency1, IYieldVault(AAVE_V3_WETH_VAULT_ADDRESS));
        console2.log("\nNext: call hook.setVault(currency, vaultAddress) for each pool currency.");
    }
}
