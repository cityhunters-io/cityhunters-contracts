// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/HuntToken.sol"; import "../src/Hero.sol"; import "../src/Game.sol"; import "../src/MockAgentCity.sol"; import "../src/Referral.sol";
contract ReferralTest is Test {
    HuntToken hunt; Hero hero; Game game; Referral rf; address alice = address(0xA11CE); address bob = address(0xB0B);
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new Game(address(this), hunt, hero, new MockAgentCity(), address(7), address(8), 100 ether);
        hero.setGame(address(game)); game.setCaps(300, 300, 1_000_000 ether, 50_000_000 ether);
        rf = new Referral(address(this), hunt, hero, game); hunt.transfer(address(rf), 100_000 ether);
        hunt.transfer(bob, 100_000 ether); vm.prank(bob); hunt.approve(address(rf), type(uint256).max);
    }
    function testReferredMintAndRedeem() public {
        uint256 p = game.mintPriceHunt(); uint256 b0 = hunt.balanceOf(bob);
        vm.prank(bob); uint256 id = rf.mint(2, alice);
        assertEq(hero.ownerOf(id), bob); assertEq(hero.ownerOf(id + 1), bob); assertEq(b0 - hunt.balanceOf(bob), 2 * p);
        assertEq(rf.credits(alice), 1);
        uint256 pool = hunt.balanceOf(address(rf));
        vm.prank(alice); uint256 fid = rf.redeem();
        assertEq(hero.ownerOf(fid), alice); assertEq(rf.credits(alice), 0); assertEq(pool - hunt.balanceOf(address(rf)), p);
        vm.prank(alice); vm.expectRevert(Referral.NoCredit.selector); rf.redeem();
    }
    function testNoSelfRefAndCap() public {
        vm.prank(bob); vm.expectRevert(Referral.Bad.selector); rf.mint(1, bob);
        for (uint256 i; i < 5; i++) { vm.prank(bob); rf.mint(2, address(0)); }
        vm.prank(bob); vm.expectRevert(Referral.Cap.selector); rf.mint(1, address(0));
        assertEq(rf.credits(address(0)), 0);
    }
}
