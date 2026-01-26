// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {TokenJar} from "../../src/TokenJar.sol";
import {Firepit} from "../../src/releasers/Firepit.sol";

/// @title RigoBlockDeployer
/// @notice Minimal deployer for deterministic TokenJar + Firepit addresses
/// @dev Deploy this contract via CREATE2 at the same address on all chains,
///      then call deployContracts() with chain-specific params.
///      - TokenJar address is deterministic (no constructor args)
///      - Firepit address varies per chain (constructor args differ)
contract RigoBlockDeployer {
    bytes32 public constant SALT_TOKEN_JAR = bytes32(uint256(1));
    bytes32 public constant SALT_FIREPIT = bytes32(uint256(2));

    address public tokenJar;
    address public firepit;

    /// @notice Deploy and configure TokenJar + Firepit
    /// @param resource The GRG token address on this chain
    /// @param minThreshold The minimum threshold for decay
    /// @param owner The final owner (governance)
    function deployContracts(address resource, uint256 minThreshold, address owner) external {
        require(tokenJar == address(0), "Already deployed");

        // 1. Deploy TokenJar (no constructor args → same address everywhere)
        TokenJar jar = new TokenJar{salt: SALT_TOKEN_JAR}();
        tokenJar = address(jar);

        // 2. Deploy Firepit (constructor args vary → different address per chain)
        Firepit pit = new Firepit{salt: SALT_FIREPIT}(resource, minThreshold, address(jar));
        firepit = address(pit);

        // 3. Configure TokenJar
        jar.setReleaser(address(pit));
        jar.transferOwnership(owner);

        // 4. Configure Firepit
        pit.setThresholdSetter(owner);
        pit.transferOwnership(owner);
    }
}
