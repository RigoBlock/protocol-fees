// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Currency} from "v4-core/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ResourceManager} from "../base/ResourceManager.sol";
import {Nonce} from "../base/Nonce.sol";
import {ITokenJar} from "../interfaces/ITokenJar.sol";
import {IReleaser} from "../interfaces/IReleaser.sol";

/// @title ExchangeReleaser
/// @notice A contract that releases assets from the TokenJar in exchange for transferring a
/// threshold amount of a resource token
/// @dev Inherits from ResourceManager for resource transferring functionality and Nonce for replay
/// protection
/// @dev Implements a reverse Dutch auction where the threshold starts high and decays over time
/// using a quadratic decay formula: threshold = INITIAL_THRESHOLD / (1 + (elapsed/TIME_CONSTANT)²)
/// The threshold resets after each successful release, providing MEV protection
/// @custom:security-contact security@rigoblock.com
abstract contract ExchangeReleaser is IReleaser, ResourceManager, Nonce {
  using SafeTransferLib for ERC20;

  /// @notice Maximum number of different assets that can be released in a single call
  uint256 public constant MAX_RELEASE_LENGTH = 20;

  /// @notice The initial threshold at deployment/reset (100M tokens with 18 decimals)
  /// @dev Set impossibly high (>10x total supply) to start the reverse Dutch auction
  uint256 public constant INITIAL_THRESHOLD = 100_000_000e18;

  /// @notice The time constant controlling decay speed (0.1 days = 8640 seconds)
  /// @dev With quadratic decay, threshold reaches ~100 tokens at day 90
  uint256 public constant TIME_CONSTANT = 8640;

  /// @inheritdoc IReleaser
  ITokenJar public immutable TOKEN_JAR;

  /// @notice The timestamp when the threshold was last reset (at deployment or after release)
  uint256 public lastResetTime;

  uint256 private immutable _timeConstantSquared;

  /// @notice Creates a new ExchangeReleaser instance
  /// @param _resource The address of the resource token that must be transferred
  /// @param _threshold The minimum threshold that decay cannot go below
  /// @param _tokenJar The address of the TokenJar contract holding the assets
  /// @param _recipient The address that will receive the resource tokens
  constructor(address _resource, uint256 _threshold, address _tokenJar, address _recipient)
    ResourceManager(_resource, _threshold, msg.sender, _recipient)
  {
    TOKEN_JAR = ITokenJar(payable(_tokenJar));
    lastResetTime = block.timestamp;
    _timeConstantSquared = TIME_CONSTANT ** 2;
  }

  /// @inheritdoc IReleaser
  function release(uint256 _nonce, Currency[] calldata assets, address recipient, uint256 maxResourceAmount)
    external
    handleNonce(_nonce)
    override
    returns (uint256 thresholdPaid)
  {
    require(assets.length <= MAX_RELEASE_LENGTH, TooManyAssets());
    thresholdPaid = currentThreshold();
    require(thresholdPaid <= maxResourceAmount, ThresholdExceedsMax());
    RESOURCE.safeTransferFrom(msg.sender, RESOURCE_RECIPIENT, thresholdPaid);
    TOKEN_JAR.release(assets, recipient);
    emit Released(_nonce, recipient, assets);

    // Reset the decay timer
    lastResetTime = block.timestamp;

    _afterRelease(assets, recipient, thresholdPaid);
  }

  /// @inheritdoc IReleaser
  /// @dev Uses Lorentzian (inverse quadratic) decay, not exponential
  /// @dev Overflow analysis:
  ///      - Numerator: INITIAL_THRESHOLD * TIME_CONSTANT² ≈ 7.46e33 << uint256.max (1.15e77)
  ///      - Denominator: elapsed² overflows only if elapsed > 3.4e38 seconds (~10³¹ years)
  ///      - Solidity 0.8+ reverts on overflow, so worst case is uncallable, not wrong values
  function currentThreshold() public view override returns (uint256) {
    uint256 elapsed = block.timestamp - lastResetTime;
    // Quadratic decay: INITIAL_THRESHOLD / (1 + (elapsed/TIME_CONSTANT)²)
    // To avoid precision loss, compute: INITIAL_THRESHOLD * TIME_CONSTANT² / (TIME_CONSTANT² + elapsed²)
    uint256 decayed = (INITIAL_THRESHOLD * _timeConstantSquared) / (_timeConstantSquared + elapsed ** 2);
    return decayed > threshold ? decayed : threshold;
  }

  /// @notice Internal function to handle any post transfer actions
  /// e.g. bridge calls or notifications
  function _afterRelease(Currency[] calldata assets, address recipient, uint256 thresholdPaid) internal virtual {
    // by default do nothing after release
  }
}
