// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/LamplightEscrow.sol";

/// @notice Deploy LamplightEscrow to Arc (mainnet or testnet).
/// @dev DO NOT run this against mainnet from a zero balance — it will fail
///   on gas. Fund the deployer with a small amount of real USDC on Arc
///   first (see STATUS.md: the blocker). Testnet: fund via the Circle
///   faucet at https://faucet.circle.com (Arc Testnet, 10–20 test USDC).
///   Usage:
///     forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
///     forge script script/Deploy.s.sol --rpc-url arc_mainnet --broadcast
///   The deployer key comes from the environment (DEPLOYER_PRIVATE_KEY).
///   NEVER use the Ellis main wallet key (0x307d...) as a deployer key,
///   and never paste any private key into chat, a file, or a repo.
contract Deploy is Script {
    function run() external returns (LamplightEscrow deployed) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        deployed = new LamplightEscrow();
        vm.stopBroadcast();
        console.log("LamplightEscrow deployed at:", address(deployed));
    }
}
