// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./Vrf.t.sol";
contract RerequestTimeoutTest is VrfTest {
    event RerequestTimeoutSet(uint256 oldTimeout, uint256 newTimeout);
    function testDefaultIsTenMinutes() public view { assertEq(game.rerequestTimeout(), 10 minutes); }
    function testOwnerSetWithinBounds() public {
        vm.expectEmit(address(game)); emit RerequestTimeoutSet(10 minutes, 2 minutes);
        game.setRerequestTimeout(2 minutes); assertEq(game.rerequestTimeout(), 2 minutes);
        game.setRerequestTimeout(24 hours); assertEq(game.rerequestTimeout(), 24 hours);
    }
    function testNonOwnerReverts() public {
        vm.prank(al); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, al));
        game.setRerequestTimeout(30 minutes);
    }
    function testOutOfBoundsReverts() public {
        vm.expectRevert(GameMainnet.Bad.selector); game.setRerequestTimeout(2 minutes - 1);
        vm.expectRevert(GameMainnet.Bad.selector); game.setRerequestTimeout(24 hours + 1);
    }
    function _pendingMint() internal returns (uint256 id) {
        vm.warp(game.saleStart()); uint256 p = game.mintPriceBnb(); vm.prank(al); game.mintBnb{value: p}(1); id = co.n();
    }
    function testRerequestBlockedBeforeAllowedAfterDefault() public {
        uint256 id = _pendingMint(); uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 minutes - 1); vm.expectRevert(GameMainnet.Bad.selector); game.rerequest(id);
        vm.warp(t0 + 10 minutes); game.rerequest(id); assertEq(co.n(), id + 1);
        co.fulfill(game, co.n(), 42); assertEq(hero.balanceOf(al), 1);
    }
    function testRerequestUsesCustomTimeout() public {
        game.setRerequestTimeout(1 hours); uint256 id = _pendingMint(); uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours - 1); vm.expectRevert(GameMainnet.Bad.selector); game.rerequest(id);
        vm.warp(t0 + 1 hours); game.rerequest(id); assertEq(co.n(), id + 1);
    }
    function testNonOwnerCannotRerequest() public {
        uint256 id = _pendingMint(); vm.warp(block.timestamp + 1 days);
        vm.prank(al); vm.expectRevert(); game.rerequest(id);
    }
}
