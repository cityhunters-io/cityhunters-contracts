// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/HuntToken.sol"; import "../src/Hero.sol"; import "../src/Game.sol"; import "../src/MockAgentCity.sol";

contract GameTest is Test {
    HuntToken hunt; Hero hero; Game game; MockAgentCity city;
    address owner = address(this); address treasury = address(0x7); address pool = address(0x8);
    address alice = address(0xA11CE); address bob = address(0xB0B);

    uint256 T = 1_800_000_000;
    function _skip(uint256 d) internal { T += d; vm.warp(T); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(owner); hero = new Hero(owner); city = new MockAgentCity();
        game = new Game(owner, hunt, hero, city, treasury, pool, 100 ether); // 1 USD = 100 HUNT
        hero.setGame(address(game));
        hunt.approve(address(game), type(uint256).max);
        game.fundRewards(10_000_000 ether);
        hunt.transfer(alice, 10_000_000 ether); hunt.transfer(bob, 1_000_000 ether);
        vm.prank(alice); hunt.approve(address(game), 10_000_000 ether);
    }

    function _mintAlice(uint256 q) internal { vm.prank(alice); game.mint(q); }

    function testSupplyFixed() public view { assertEq(hunt.totalSupply(), 1_000_000_000 ether); }

    function testGenesisPrice100PctTreasury() public {
        _mintAlice(2);
        assertEq(hero.balanceOf(alice), 2);
        assertEq(hunt.balanceOf(treasury), 2000 ether);
    }
    function testPostGenesisSplitAndBurn() public {
        _skip(3 days + 1);
        uint256 s = hunt.totalSupply(); _mintAlice(1);
        assertEq(hunt.balanceOf(treasury), 800 ether); assertEq(hunt.balanceOf(pool), 600 ether);
        assertEq(s - hunt.totalSupply(), 600 ether);
    }
    function testCaps() public {
        vm.prank(alice); vm.expectRevert(Game.Bad.selector); game.mint(3);
        _mintAlice(2);
        vm.prank(alice); vm.expectRevert(Game.Cap.selector); game.mint(1);
        _skip(1 days); _mintAlice(1);
    }
    function testAttrRanges() public {
        for (uint256 d; d < 20; d++) { _skip(1 days); vm.prevrandao(bytes32(d)); _mintAlice(2); }
        for (uint256 id = 1; id <= 40; id++) {
            Hero.HeroData memory h = hero.getHero(id);
            (uint8 m,) = game.mainSub(h.class_);
            assertLe(h.class_, 5); assertLe(h.rarity, 3);
            if (h.rarity == 0) { assertGe(h.attrs[m], 61); assertLe(h.attrs[m], 79); }
            if (h.rarity == 3) assertGe(h.attrs[m], 97);
        }
    }
    function testOfficialOnce() public {
        game.mintOfficial();
        Hero.HeroData memory h = hero.getHero(0);
        assertTrue(h.isOfficial); assertEq(h.attrs[2], 100); assertEq(hero.ownerOf(0), owner);
        vm.expectRevert(Hero.OfficialDone.selector); game.mintOfficial();
        vm.prank(alice); vm.expectRevert(); game.mintOfficial();
    }
    function testWorkClaimAndLock() public {
        _mintAlice(1);
        vm.prank(alice); game.startWork(1, 0, 8);
        vm.prank(alice); vm.expectRevert(Hero.Locked.selector); hero.transferFrom(alice, bob, 1);
        vm.prank(alice); vm.expectRevert(Game.Busy.selector); game.claim(1);
        _skip(8 hours);
        uint256 b = hunt.balanceOf(alice);
        vm.prank(alice); game.claim(1);
        assertEq(hunt.balanceOf(alice) - b, 50 ether); // 1500 V *8/24 = 500 V * 0.1
        vm.prank(alice); hero.transferFrom(alice, bob, 1);
    }
    function testDecay() public {
        game.mintOfficial(); _mintAlice(1);
        // force 720 worked hours (30 days) -> half
        Hero.HeroData memory h = hero.getHero(1); h.workedHours = 720;
        vm.prank(address(game)); hero.setHero(1, h);
        vm.prank(alice); game.startWork(1, 0, 8); _skip(8 hours);
        uint256 b = hunt.balanceOf(alice); vm.prank(alice); game.claim(1);
        assertEq(hunt.balanceOf(alice) - b, 25 ether);
        // official: no decay, output to treasury; street job 1500 -> high commission 2200+15*300=6700
        game.startWork(0, 5, 24); _skip(24 hours);
        uint256 t = hunt.balanceOf(treasury); game.claim(0);
        assertEq(hunt.balanceOf(treasury) - t, 670 ether);
    }
    function testWorkCap90Days() public {
        _mintAlice(1);
        Hero.HeroData memory h = hero.getHero(1); h.workedHours = 2160;
        vm.prank(address(game)); hero.setHero(1, h);
        vm.prank(alice); vm.expectRevert(Game.Cap.selector); game.startWork(1, 0, 1);
    }
    function testEnergy() public {
        _mintAlice(1);
        vm.prank(alice); vm.expectRevert(Game.Cap.selector); game.startWork(1, 0, 9);
        vm.prank(alice); game.startWork(1, 0, 8); _skip(8 hours);
        vm.prank(alice); game.claim(1);
        assertEq(game.currentEnergy(hero.getHero(1)), 4); // 8h regen = 4
        uint256 s = hunt.totalSupply();
        vm.prank(alice); game.refillEnergy(1, 4);
        assertEq(s - hunt.totalSupply(), 24 ether); // 4*60V*0.1 burned
    }
    function testUpgrade() public {
        _mintAlice(1);
        Hero.HeroData memory h0 = hero.getHero(1); (uint8 m,) = game.mainSub(h0.class_);
        uint256 t = hunt.balanceOf(treasury);
        vm.prank(alice); game.upgrade(1);
        Hero.HeroData memory h = hero.getHero(1);
        assertEq(h.level, 2); assertEq(h.attrs[m], h0.attrs[m] + 1);
        assertEq(hunt.balanceOf(treasury) - t, 100 ether); // 500 HUNT, 20%
    }
    function testDailyEmissionCap() public {
        game.setCaps(300, 2, 10 ether, 50_000_000 ether);
        _mintAlice(1);
        vm.prank(alice); game.startWork(1, 0, 8); _skip(8 hours);
        uint256 b = hunt.balanceOf(alice); vm.prank(alice); game.claim(1);
        assertEq(hunt.balanceOf(alice) - b, 10 ether);
    }
    function testMerge() public {
        // mint until two same-class same-rarity
        uint256 a; uint256 bb;
        for (uint256 d; d < 30 && bb == 0; d++) {
            _skip(1 days); vm.prevrandao(bytes32(d)); _mintAlice(2);
            uint256 last = hero.nextId() - 1;
            for (uint256 i = 1; i < last && bb == 0; i++) for (uint256 j = i + 1; j <= last && bb == 0; j++) {
                if (hero.ownerOf(i) != alice || hero.ownerOf(j) != alice) continue;
                Hero.HeroData memory x = hero.getHero(i); Hero.HeroData memory y = hero.getHero(j);
                if (x.class_ == y.class_ && x.rarity == y.rarity && x.rarity < 3) { a = i; bb = j; }
            }
        }
        assertGt(bb, 0);
        uint8 r0 = hero.getHero(a).rarity;
        vm.prank(alice); game.merge(a, bb);
        vm.expectRevert(); hero.ownerOf(a);
        Hero.HeroData memory n = hero.getHero(hero.nextId() - 1);
        assertTrue(n.rarity == r0 || n.rarity == r0 + 1); assertEq(n.workedHours, 0);
    }
    function testGenesisFree() public {
        uint256 card = city.mint(bob);
        vm.prank(alice); vm.expectRevert(Game.NotOwner.selector); game.claimGenesisFree(card, 1);
        for (uint256 i; i < 4; i++) { vm.prank(bob); game.claimGenesisFree(card, 5); }
        vm.prank(bob); vm.expectRevert(Game.Cap.selector); game.claimGenesisFree(card, 1);
        assertEq(hero.balanceOf(bob), 20);
        vm.prank(bob); city.transferFrom(bob, alice, card);
        vm.prank(alice); vm.expectRevert(Game.Cap.selector); game.claimGenesisFree(card, 1);
    }
    function testGenesisDefaultsLockAndWindow() public {
        assertEq(game.genesisLock(), 7 days);
        assertEq(game.genesisClaimEnd(), game.launchTime() + 14 days);
        uint256 card = city.mint(bob);
        vm.prank(bob); game.claimGenesisFree(card, 1);
        uint256 id = hero.nextId() - 1;
        assertEq(hero.getHero(id).tradeLockUntil, block.timestamp + 7 days);
        vm.prank(bob); vm.expectRevert(); hero.transferFrom(bob, alice, id);
        vm.warp(block.timestamp + 7 days);
        vm.prank(bob); hero.transferFrom(bob, alice, id);
        assertEq(hero.ownerOf(id), alice);
        vm.warp(game.launchTime() + 14 days + 1);
        vm.prank(bob); vm.expectRevert(Game.Bad.selector); game.claimGenesisFree(card, 1);
    }
    function testAgentFree() public {
        bytes32 id1 = keccak256("agent-1"); bytes32 id2 = keccak256("agent-2");
        bytes32 l1 = keccak256(bytes.concat(keccak256(abi.encode(alice, id1))));
        bytes32 l2 = keccak256(bytes.concat(keccak256(abi.encode(bob, id2))));
        bytes32 root = l1 < l2 ? keccak256(abi.encode(l1, l2)) : keccak256(abi.encode(l2, l1));
        game.openAgentClaim(root);
        bytes32[] memory p = new bytes32[](1); p[0] = l2;
        vm.prank(alice); game.claimAgentFree(id1, p);
        vm.prank(alice); vm.expectRevert(Game.Cap.selector); game.claimAgentFree(id1, p);
        uint256 id = hero.nextId() - 1;
        vm.prank(alice); vm.expectRevert(Hero.Locked.selector); hero.transferFrom(alice, bob, id);
        _skip(7 days + 1);
        vm.prank(alice); hero.transferFrom(alice, bob, id);
        p[0] = l1; _skip(8 days);
        vm.prank(bob); vm.expectRevert(Game.Bad.selector); game.claimAgentFree(id2, p);
    }
    function testPoolCapAndPause() public {
        vm.expectRevert(Game.Cap.selector); game.fundRewards(45_000_000 ether);
        game.pause(); vm.prank(alice); vm.expectRevert(); game.mint(1);
        vm.prank(alice); vm.expectRevert(); game.pause();
    }
}
