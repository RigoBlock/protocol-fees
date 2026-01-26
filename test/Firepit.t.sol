// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {ProtocolFeesTestBase} from "./utils/ProtocolFeesTestBase.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencyLibrary} from "v4-core/types/Currency.sol";
import {INonce} from "../src/interfaces/base/INonce.sol";
import {IOwned} from "../src/interfaces/base/IOwned.sol";
import {IResourceManager} from "../src/interfaces/base/IResourceManager.sol";
import {IReleaser} from "../src/interfaces/IReleaser.sol";

contract FirepitTest is ProtocolFeesTestBase {
  function setUp() public override {
    super.setUp();

    vm.prank(owner);
    tokenJar.setReleaser(address(firepit));
  }

  function test_release_release_erc20() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), 0);

    vm.startPrank(alice);
    resource.approve(address(firepit), INITIAL_TOKEN_AMOUNT);
    firepit.release(firepit.nonce(), releaseMockToken, alice, type(uint256).max);

    // TokenJar leaves 1 wei
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT - 1);
    assertEq(mockToken.balanceOf(address(tokenJar)), 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), firepit.threshold());
  }

  function test_release_release_native() public {
    assertEq(resource.balanceOf(alice), INITIAL_TOKEN_AMOUNT);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), 0);

    vm.startPrank(alice);
    resource.approve(address(firepit), INITIAL_TOKEN_AMOUNT);
    firepit.release(firepit.nonce(), releaseMockNative, alice, type(uint256).max);

    // TokenJar leaves 1 wei
    assertEq(CurrencyLibrary.ADDRESS_ZERO.balanceOf(address(tokenJar)), 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), firepit.threshold());
  }

  function test_fuzz_revert_release_insufficient_balance(uint256 amount, uint256 seed) public {
    amount = bound(amount, 1, resource.balanceOf(alice));

    // alice spends some of her resources
    vm.prank(alice);
    bool success = resource.transfer(address(0), amount);
    assertTrue(success);

    assertLt(resource.balanceOf(alice), firepit.threshold());

    uint256 nonce = firepit.nonce();

    vm.startPrank(alice);
    resource.approve(address(firepit), type(uint256).max);
    vm.expectRevert(); // reverts on token insufficient allowance
    firepit.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice, type(uint256).max);
  }

  function test_fuzz_revert_release_invalid_nonce(uint256 nonce, uint256 seed) public {
    vm.assume(nonce != firepit.nonce()); // Ensure nonce is not the current nonce

    vm.startPrank(alice);
    resource.approve(address(firepit), type(uint256).max);
    vm.expectRevert(INonce.InvalidNonce.selector);
    firepit.release(nonce, fuzzReleaseAny[seed % fuzzReleaseAny.length], alice, type(uint256).max);
  }

  /// @dev test that two transactions with the same nonce, the second one should revert
  function test_revert_release_frontrun() public {
    uint256 nonce = firepit.nonce();

    vm.startPrank(alice);
    resource.approve(address(firepit), type(uint256).max);

    // First release call
    firepit.release(nonce, releaseMockToken, alice, type(uint256).max);
    // TokenJar leaves 1 wei
    assertEq(mockToken.balanceOf(alice), INITIAL_TOKEN_AMOUNT - 1);
    assertEq(mockToken.balanceOf(address(tokenJar)), 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), INITIAL_TOKEN_AMOUNT);

    // Attempt to frontrun with the same nonce
    vm.expectRevert(INonce.InvalidNonce.selector);
    firepit.release(nonce, releaseMockToken, alice, type(uint256).max);
  }

  /// @dev on a single chain releaser, malicious tokens will hard revert
  function test_revert_release_revertingToken() public {
    uint256 nonce = firepit.nonce();
    vm.startPrank(alice);
    resource.approve(address(firepit), type(uint256).max);

    vm.expectRevert();
    firepit.release(nonce, releaseMockReverting, alice, type(uint256).max);
  }

  function test_fuzz_setThresholdSetter(address caller, address newSetter) public {
    vm.startPrank(caller);
    if (caller != IOwned(address(firepit)).owner()) vm.expectRevert("UNAUTHORIZED");
    firepit.setThresholdSetter(newSetter);
    vm.stopPrank();
  }

  function test_fuzz_revert_setThreshold(address caller, uint256 newThreshold) public {
    vm.startPrank(caller);
    if (caller != firepit.thresholdSetter()) {
      vm.expectRevert(IResourceManager.Unauthorized.selector);
    }
    firepit.setThreshold(newThreshold);
    vm.stopPrank();
  }

  function test_fuzz_newThreshold(uint256 newThreshold) public {
    vm.assume(newThreshold != firepit.threshold());
    // Bound to realistic values - must be >= min threshold for test to make sense
    newThreshold = bound(newThreshold, 1e18, 10_000e18);

    vm.prank(owner);
    firepit.setThreshold(newThreshold);

    // Warp far enough that currentThreshold() returns the minimum threshold
    vm.warp(block.timestamp + 100_000_000);

    deal(address(resource), alice, newThreshold);

    assertEq(resource.balanceOf(alice), newThreshold);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), 0);

    uint256 currentNonce = firepit.nonce();

    vm.startPrank(alice);
    resource.approve(address(firepit), newThreshold);
    firepit.release(currentNonce, releaseMockBoth, alice, type(uint256).max);

    assertEq(firepit.nonce(), currentNonce + 1);
    assertEq(resource.balanceOf(alice), 0);
    assertEq(resource.balanceOf(address(firepit)), 0);
    assertEq(resource.balanceOf(address(0xdead)), firepit.threshold());
  }

  function test_revert_release_tooManyAssets() public {
    Currency[] memory assets = new Currency[](21);
    for (uint256 i = 0; i < 21; i++) {
      assets[i] = Currency.wrap(address(mockToken));
    }

    uint256 nonce = firepit.nonce();

    vm.expectRevert(IReleaser.TooManyAssets.selector);
    firepit.release(nonce, assets, alice, type(uint256).max);
  }
}
