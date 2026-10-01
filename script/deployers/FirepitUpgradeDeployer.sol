// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Firepit} from "../../src/releasers/Firepit.sol";

/// @title FirepitUpgradeDeployer
/// @notice Deployer for migrating the Firepit to a new resource token.
/// @dev Mirrors RigoBlockDeployer: deployed via CREATE2 from a script (routed through the
///      canonical create2 factory), so it has no constructor args and lands at the same
///      address on every chain. It is the Firepit's initial owner, which allows it to
///      wire up permissions before transferring ownership to governance.
///      One-shot per deployment, like RigoBlockDeployer.
contract FirepitUpgradeDeployer {
    /// @dev Continues RigoBlockDeployer's salt sequence: 1 = TokenJar, 2 = original Firepit
    bytes32 public constant SALT_FIREPIT_V2 = bytes32(uint256(3));

    address public firepit;

    /// @notice Deploy and configure a Firepit pointing at a new resource token
    /// @param resource The resource token address on this chain
    /// @param minThreshold The minimum threshold for decay
    /// @param tokenJar The existing TokenJar the Firepit will release from
    /// @param owner The final owner (governance), also set as thresholdSetter
    function deployFirepit(address resource, uint256 minThreshold, address tokenJar, address owner) external {
        require(firepit == address(0), "Already deployed");

        Firepit pit = new Firepit{salt: SALT_FIREPIT_V2}(resource, minThreshold, tokenJar);
        firepit = address(pit);

        pit.setThresholdSetter(owner);
        pit.transferOwnership(owner);
    }
}
