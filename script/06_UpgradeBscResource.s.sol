// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {FirepitUpgradeDeployer} from "./deployers/FirepitUpgradeDeployer.sol";
import {ITokenJar} from "../src/interfaces/ITokenJar.sol";

/// @notice Upgrades the GRG resource on BSC from the legacy Multichain-bridged token
/// @dev RESOURCE is immutable in the Firepit, so the migration requires deploying a new
///      Firepit pointing at the new GRG token, via a one-shot FirepitUpgradeDeployer that
///      is the Firepit's initial owner (script-level CREATE2 would make the canonical
///      create2 factory the owner instead, bricking it). TokenJar ownership belongs to
///      governance, so switching the releaser is a separate governance action (calldata
///      is printed below).
contract UpgradeBscResource is Script, Config {
    /// @dev Same scheme as RigoBlockDeployer's "RIG" salt; "RIG2". No constructor args,
    ///      so the deployer lands at the same address on every chain.
    bytes32 private constant SALT_UPGRADE_DEPLOYER = bytes32(uint256(0x52494732));

    uint256 private constant BSC_CHAIN_ID = 56;

    /// @dev The migrated GRG token on BSC
    address private constant NEW_GRG = 0x1616c66A78b5802e290247b714D8B22b440Dc343;

    address private constant OWNER = 0x002BA2351532a741043d874Bd0b12aAb21abc289;
    uint256 private constant MIN_THRESHOLD = 50e18;

    function setUp() public {}

    function run() public {
        require(block.chainid == BSC_CHAIN_ID, "Only BSC");

        _loadConfig("./deployments.toml", true);

        address tokenJar = config.get("token_jar").toAddress();
        require(tokenJar != address(0), "TokenJar not configured");

        console2.log("TokenJar at:", tokenJar);
        console2.log("New GRG:", NEW_GRG);

        vm.startBroadcast();

        FirepitUpgradeDeployer upgrader = new FirepitUpgradeDeployer{salt: SALT_UPGRADE_DEPLOYER}();
        upgrader.deployFirepit(NEW_GRG, MIN_THRESHOLD, tokenJar, OWNER);

        vm.stopBroadcast();

        address firepit = upgrader.firepit();
        console2.log("FirepitUpgradeDeployer at:", address(upgrader));
        console2.log("New Firepit at:", firepit);

        // TokenJar.setReleaser is onlyOwner and ownership belongs to governance
        console2.log("Governance must call TokenJar.setReleaser(newFirepit) with calldata:");
        console2.logBytes(abi.encodeCall(ITokenJar.setReleaser, (firepit)));

        config.set("grg", NEW_GRG);
        config.set("firepit", firepit);

        console2.log("deployments.toml updated");
    }
}
