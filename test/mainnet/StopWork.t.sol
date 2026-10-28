// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./Mainnet.t.sol";
contract StopWorkTest is Base {
    uint256 id; uint256 T;
    function setUp() public override { super.setUp(); vm.prank(alice); game.mint(1); id = hero.nextId() - 1; T = block.timestamp; }
    function _start(uint8 hrs) internal { vm.prank(alice); game.startWork(id, 0, hrs); }
    function _stop() internal returns (uint256 got) { uint256 b = hunt.balanceOf(alice); vm.prank(alice); game.stopWork(id); got = hunt.balanceOf(alice) - b; }
    function testStopAtZeroHours() public {
        _start(8); assertEq(hero.getHero(id).energy, 0);
        vm.warp(T + 20 minutes); assertEq(_stop(), 0);
        Hero.HeroData memory h = hero.getHero(id);
        assertEq(h.energy, 7, "refund 8 - ceil(20m)=7"); assertEq(h.workedHours, 0); assertEq(h.busyUntil, T + 20 minutes);
        (, uint8 hrs, ) = game.shifts(id); assertEq(hrs, 0);
    }
    function testStopExactlyAtStartRefundsAll() public { _start(8); assertEq(_stop(), 0); assertEq(hero.getHero(id).energy, 8); }
    function testMidShiftPartialPay() public {
        _start(8); vm.warp(T + 3 hours + 30 minutes);
        (uint256 v, uint256 ph, uint256 rf) = game.stopPreview(id); assertEq(ph, 3); assertEq(rf, 4);
        uint256 got = _stop();
        assertEq(got, 1500 ether * 3 / 24 / 10, "3 full hours, same formula as claim"); assertEq(got, v * game.cWei() / 1e18);
        Hero.HeroData memory h = hero.getHero(id); assertEq(h.workedHours, 3);
        assertEq(h.energy, 4 + 1, "4 unstarted hours refunded + 1 natural regen (2h/pt) during 3.5h");
    }
    function testStopThenFightUpgradeTransferImmediately() public {
        _start(8); vm.warp(T + 1 hours); _stop();
        vm.prank(alice); bt.fight(id, 0);
        vm.warp(block.timestamp + 11 minutes); vm.prank(alice); game.upgrade(id);
        vm.prank(alice); game.startWork(id, 0, 1);
        vm.warp(block.timestamp + 1 hours); vm.prank(alice); game.claim(id);
        vm.prank(alice); hero.transferFrom(alice, bob, id); assertEq(hero.ownerOf(id), bob);
    }
    function testStartStopFarmingNeverBeatsNormal() public {
        // reference: one 8h shift finished normally, on a fresh hero
        vm.prank(bob); game.mint(1); uint256 ref = hero.nextId() - 1;
        vm.prank(bob); game.startWork(ref, 0, 8); vm.warp(T + 8 hours);
        uint256 b0 = hunt.balanceOf(bob); vm.prank(bob); game.claim(ref); uint256 normal = hunt.balanceOf(bob) - b0;
        // farmer: same 8 hours of wall time split into many start/stop cycles (59 min each pays 0, 1h59 pays 1h)
        vm.warp(T); uint256 farmed; uint256 t = T;
        for (uint256 i; i < 16 && t < T + 8 hours; i++) {
            uint8 e = game.currentEnergy(hero.getHero(id)); if (e < 2) { t += 2 hours; vm.warp(t); continue; }
            _start(e); t += (i % 2 == 0) ? 59 minutes : 1 hours + 59 minutes; vm.warp(t); farmed += _stop();
        }
        assertLe(farmed, normal, "start/stop can never exceed finishing");
        assertLe(hero.getHero(id).workedHours, 8);
    }
    function testPerHourPayEqualsClaim() public {
        _start(2); vm.warp(T + 2 hours - 1); uint256 a = _stop(); // only 1 full hour
        assertEq(a, 1500 ether / 24 / 10);
    }
    function testOfficialToTreasury2x() public {
        ag.work(0, 5); vm.warp(1_800_000_000 + 2 hours + 10 minutes);
        uint256 t0 = hunt.balanceOf(tre); (uint256 base, uint256 bonus) = ag.stopWork();
        assertGt(base, 0); assertEq(bonus, base); assertEq(hunt.balanceOf(tre) - t0, 2 * base);
        assertEq(hero.getHero(0).workedHours, 2);
    }
    function testNonOwnerReverts() public { _start(4); vm.prank(bob); vm.expectRevert(GameMainnet.NotOwner.selector); game.stopWork(id); }
    function testNoActiveShiftReverts() public {
        vm.prank(alice); vm.expectRevert(GameMainnet.Bad.selector); game.stopWork(id);
        _start(1); vm.warp(T + 1 hours); vm.prank(alice); vm.expectRevert(GameMainnet.Bad.selector); game.stopWork(id); // finished -> use claim
        vm.prank(alice); game.claim(id);
    }
    function testPausedReverts() public { _start(4); game.pause(); vm.prank(alice); vm.expectRevert(); game.stopWork(id); }
    function test90DayCap() public {
        Hero.HeroData memory h = hero.getHero(id); h.workedHours = 2158; vm.prank(address(game)); hero.setHero(id, h);
        _start(8); vm.warp(T + 5 hours + 1);
        (, uint256 ph, ) = game.stopPreview(id); assertEq(ph, 2);
        _stop(); assertEq(hero.getHero(id).workedHours, 2160);
        vm.prank(alice); vm.expectRevert(GameMainnet.Cap.selector); game.startWork(id, 0, 1);
    }
}
