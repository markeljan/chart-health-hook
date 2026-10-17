// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {ChartHealthHook} from "../src/ChartHealthHook.sol";
import {ChartHealthPresets} from "../src/ChartHealthPresets.sol";

/// @notice Deploys a ChartHealthHook with a preset or a custom config.
///
///   PRIVATE_KEY=0x... POOL_MANAGER=0x... TRUSTED_ROUTERS=0x...,0x... PRESET=trenches \
///   forge script script/DeployChartHealthHook.s.sol --rpc-url $RPC_URL --broadcast --verify
///
/// PRESET: trenches | diamond | shield | custom (edit `custom()` below)
contract DeployChartHealthHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (ChartHealthHook hook) {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address[] memory routers = vm.envAddress("TRUSTED_ROUTERS", ",");
        ChartHealthHook.Config memory config = preset(vm.envOr("PRESET", string("trenches")));

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(manager, config, routers);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(ChartHealthHook).creationCode, args);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        hook = new ChartHealthHook{salt: salt}(manager, config, routers);
        vm.stopBroadcast();
        require(address(hook) == expected, "hook address mismatch");
        console.log("ChartHealthHook:", address(hook));
    }

    function preset(string memory name) public pure returns (ChartHealthHook.Config memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("trenches")) return ChartHealthPresets.trenches();
        if (h == keccak256("diamond")) return ChartHealthPresets.diamondHands();
        if (h == keccak256("shield")) return ChartHealthPresets.launchShield();
        if (h == keccak256("custom")) return custom();
        revert("unknown PRESET");
    }

    /// @notice Your own setup: tweak anything.
    function custom() public pure returns (ChartHealthHook.Config memory c) {
        c = ChartHealthPresets.trenches();
        c.bottomSellFee = 50_000; // 5%
        c.maxDiscountBps = 5_000; // 50%
    }
}
