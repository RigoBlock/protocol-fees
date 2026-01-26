// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {RigoBlockDeployer} from "./deployers/RigoBlockDeployer.sol";

contract DeployRigoblock is Script, Config {
    /// @dev Salt for deploying RigoBlockDeployer via CREATE2
    /// Same salt on all chains → same deployer address → same TokenJar address
    bytes32 private constant SALT_DEPLOYER = bytes32(uint256(0x524947)); // "RIG"

    address private constant OWNER = 0x002BA2351532a741043d874Bd0b12aAb21abc289;
    uint256 private constant MIN_THRESHOLD = 50e18;

    function setUp() public {}

    function run() public {
        // Load config
        _loadConfig("./deployments.toml", true);

        console2.log("Deploying to chain:", block.chainid);

        // Get GRG address from config for current chain
        address grg = config.get("grg").toAddress();
        console2.log("GRG token:", grg);

        vm.startBroadcast();

        // 1. Deploy RigoBlockDeployer via CREATE2 (no constructor args → same address everywhere)
        RigoBlockDeployer deployer = new RigoBlockDeployer{salt: SALT_DEPLOYER}();
        console2.log("Deployer at:", address(deployer));

        // 2. Call deployContracts with chain-specific params
        deployer.deployContracts(grg, MIN_THRESHOLD, OWNER);

        console2.log("TOKEN_JAR at:", deployer.tokenJar());
        console2.log("FIREPIT at:", deployer.firepit());

        vm.stopBroadcast();

        // Save deployment addresses back to config
        config.set("deployer", address(deployer));
        config.set("token_jar", deployer.tokenJar());
        config.set("firepit", deployer.firepit());

        console2.log("Deployment complete! Addresses saved to deployments.toml");
    }
}
