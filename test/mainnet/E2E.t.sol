// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./Mainnet.t.sol";
contract E2ETimeTest is Base {
    function testPostGenesisSplit40_30_30burn() public {
        vm.warp(block.timestamp + 3 days + 1);
        uint256 p = game.mintPriceHunt(); assertEq(p, 2000 ether);
        uint256 t0 = hunt.balanceOf(tre); uint256 s0 = hunt.balanceOf(address(8)); uint256 sup = hunt.totalSupply();
        vm.prank(alice); game.mint(2);
        assertEq(hunt.balanceOf(tre) - t0, 2 * p * 40 / 100); assertEq(hunt.balanceOf(address(8)) - s0, 2 * p * 30 / 100);
        assertEq(sup - hunt.totalSupply(), 2 * p * 30 / 100);
        uint256 sup2 = hunt.totalSupply(); vm.prank(bob); rf.mint(1, address(0)); assertEq(sup2 - hunt.totalSupply(), p * 30 / 100);
    }
    function testWorkDecayAnd90DayCap() public {
        vm.prank(alice); game.mint(1); uint256 id = hero.nextId() - 1; uint256 t = block.timestamp; uint256 last = type(uint256).max;
        for (uint256 i; i < 5; i++) {
            vm.prank(alice); game.startWork(id, 0, 8); t += 8 hours; vm.warp(t);
            uint256 b0 = hunt.balanceOf(alice); vm.prank(alice); game.claim(id); uint256 got = hunt.balanceOf(alice) - b0;
            assertGt(got, 0); assertLt(got, last, "decay: each shift pays less"); last = got;
            t += 16 hours; vm.warp(t);
        }
        // 1st shift = 1500 V/day * 8/24 * 0.1 = 50 HUNT
        Hero.HeroData memory h = hero.getHero(id); h.workedHours = 2160; vm.prank(address(game)); hero.setHero(id, h);
        vm.prank(alice); vm.expectRevert(GameMainnet.Cap.selector); game.startWork(id, 0, 1);
    }
    function testInsufficientHuntReverts() public {
        address poor = address(0xD00D); vm.prank(alice); game.mint(2); uint256 a = hero.nextId() - 2;
        vm.startPrank(alice); hero.transferFrom(alice, poor, a); hero.transferFrom(alice, poor, a + 1); vm.stopPrank();
        vm.startPrank(poor); hunt.approve(address(game), type(uint256).max);
        vm.expectRevert(); game.upgrade(a); vm.expectRevert(); game.merge(a, a + 1); vm.expectRevert(); game.mint(1);
        vm.stopPrank();
    }
}
