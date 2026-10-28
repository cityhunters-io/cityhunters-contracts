// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../../src/HuntToken.sol"; import "../../src/Hero.sol"; import "../../src/MockAgentCity.sol";
import "../../src/mainnet/GameMainnet.sol"; import "../../src/mainnet/BattleMainnet.sol";
import "../../src/mainnet/OfficialAgentMainnet.sol"; import "../../src/mainnet/ReferralMainnet.sol"; import "../../src/mainnet/WhitelistMint.sol";

contract Base is Test {
    HuntToken hunt; Hero hero; GameMainnet game; BattleMainnet bt; OfficialAgentMainnet ag; ReferralMainnet rf; WhitelistMint wl;
    address tre = address(7); address alice = address(0xA11CE); address bob = address(0xB0B); address carol = address(0xC0C);
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setUp() public virtual {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new GameMainnet(address(this), hunt, hero, new MockAgentCity(), tre, address(8), 100 ether);
        hero.setGame(address(game)); game.setGenesisDurationTestnet(0); hunt.approve(address(game), type(uint256).max); game.fundRewards(1_000_000 ether); game.mintOfficial();
        bt = new BattleMainnet(address(this), hunt, hero); hunt.transfer(address(bt), 1_000_000 ether);
        ag = new OfficialAgentMainnet(address(this), hunt, hero, game, bt); hunt.transfer(address(ag), 1_000_000 ether);
        hero.safeTransferFrom(address(this), address(ag), 0);
        rf = new ReferralMainnet(address(this), hunt, hero, game); wl = new WhitelistMint(address(this), game);
        game.setMinter(address(rf), true); game.setMinter(address(wl), true);
        address[3] memory u = [alice, bob, carol];
        for (uint256 i; i < 3; i++) { hunt.transfer(u[i], 1_000_000 ether); vm.startPrank(u[i]); hunt.approve(address(rf), type(uint256).max); hunt.approve(address(game), type(uint256).max); vm.stopPrank(); }
    }
}

contract BattleMainnetTest is Base {
    function _fightLogs(uint256 id, uint8 tier, address who) internal returns (bool w, uint8 r, uint16 hMax, uint16 aMax, uint16[] memory hd, uint16[] memory ad, uint256 pay) {
        vm.recordLogs(); vm.prank(who); w = bt.fight(id, tier);
        Vm.Log[] memory L = vm.getRecordedLogs();
        for (uint256 k; k < L.length; k++) if (L[k].topics[0] == BattleMainnet.Fought.selector)
            (, , r, hMax, aMax, hd, ad, , pay) = abi.decode(L[k].data, (uint8, bool, uint8, uint16, uint16, uint16[], uint16[], bool[], uint256));
    }
    /// regression for v5 bug (HP not initialised -> 0-round auto win)
    function testHpInitialisedAndRoundsPlayed() public {
        bt.setRules(100, 100, 0, 1_000_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        vm.prank(alice); rf.mint(1, address(0)); uint256 id = hero.nextId() - 1; uint256 losses;
        for (uint256 i; i < 20; i++) {
            vm.prevrandao(bytes32(i + 900));
            (bool w, uint8 r, uint16 hMax, uint16 aMax, uint16[] memory hd, uint16[] memory ad,) = _fightLogs(id, 2, alice);
            assertGt(r, 0); assertGt(hMax, 0); assertGt(aMax, 0); assertEq(hd.length, r); assertEq(ad.length, r);
            uint256 dealt; for (uint256 k; k < r; k++) dealt += hd[k];
            if (w) assertGe(dealt, aMax); else { losses++; }
        }
        assertGt(losses, 0);
    }
    function testRandomDropRangeVariesAndEventMatches() public {
        bt.setRules(100, 100, 0, 1_000_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        vm.prank(alice); rf.mint(1, address(0)); uint256 id = hero.nextId() - 1; uint256 lo = type(uint256).max; uint256 hi;
        for (uint256 i; i < 40; i++) {
            vm.prevrandao(bytes32(i + 3)); uint256 b0 = hunt.balanceOf(alice);
            (bool w,,,,,, uint256 pay) = _fightLogs(id, 0, alice);
            assertEq(hunt.balanceOf(alice) - b0, pay);
            if (w) { assertGe(pay, 25 ether); assertLe(pay, 75 ether); if (pay < lo) lo = pay; if (pay > hi) hi = pay; } else assertEq(pay, 0);
        }
        assertGt(hi, lo, "drop must vary");
    }
    function testDailyCapUsesActualAmount() public {
        bt.setRules(100, 100, 0, 100 ether, [uint256(50 ether), 150 ether, 400 ether]);
        vm.prank(alice); rf.mint(1, address(0)); uint256 id = hero.nextId() - 1; uint256 b0 = hunt.balanceOf(alice);
        for (uint256 i; i < 30; i++) { vm.prevrandao(bytes32(i + 50)); vm.prank(alice); bt.fight(id, 0); }
        uint256 got = hunt.balanceOf(alice) - b0; assertEq(got, bt.paidOnDay(block.timestamp / 1 days)); assertEq(got, 100 ether);
    }
    function testNormalLimits() public {
        vm.prank(alice); rf.mint(1, address(0)); uint256 id = hero.nextId() - 1; uint256 t = 1_800_000_000;
        for (uint256 i; i < 3; i++) { vm.prevrandao(bytes32(i + 1)); vm.prank(alice); bt.fight(id, 0); t += 11 minutes; vm.warp(t); }
        vm.prank(alice); vm.expectRevert(BattleMainnet.Cap.selector); bt.fight(id, 0);
    }
    function testOfficialNormalSimAnd2x() public {
        assertEq(bt.OFFICIAL_MULT(), 2);
        Hero.HeroData memory h = hero.getHero(0); bool sawMiss; bool sawLoss; uint256 wins;
        h.level = 1; h.rarity = 0; h.attrs = [uint8(30), 30, 30, 30, 30]; // weak stats: official flag must give no edge
        Hero.HeroData memory n = h; n.isOfficial = false;
        for (uint256 i; i < 200; i++) {
            (bool w, uint8 r) = bt.simulate(h, 2, i); (bool w2, uint8 r2) = bt.simulate(n, 2, i);
            assertEq(w, w2); assertEq(r, r2); if (!w) sawLoss = true; else wins++;
        }
        assertTrue(sawLoss, "official can lose");
        bt.setRules(100, 100, 0, 1_000_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        for (uint256 i; i < 10; i++) {
            vm.prevrandao(bytes32(i + 5)); uint256 t0 = hunt.balanceOf(tre);
            vm.recordLogs(); bool w = ag.fight(2); Vm.Log[] memory L = vm.getRecordedLogs();
            for (uint256 k; k < L.length; k++) if (L[k].topics[0] == BattleMainnet.Fought.selector) {
                (, , uint8 r, , , uint16[] memory hd, , , ) = abi.decode(L[k].data, (uint8, bool, uint8, uint16, uint16, uint16[], uint16[], bool[], uint256));
                for (uint256 j; j < r; j++) if (hd[j] == 0) sawMiss = true;
            }
            uint256 got = hunt.balanceOf(tre) - t0;
            if (w) { assertGe(got, 400 ether); assertLe(got, 1200 ether); } else assertEq(got, 0);
        }
        assertTrue(sawMiss, "official must be able to miss");
    }
    function testOfficialTenFightsPerDay() public {
        assertEq(bt.OFFICIAL_FIGHTS_PER_DAY(), 10); assertEq(bt.fightsPerHeroPerDay(), 3);
        uint256 t = 1_800_000_000;
        for (uint256 i; i < 10; i++) { ag.fight(0); t += 11 minutes; vm.warp(t); }
        vm.expectRevert(BattleMainnet.Cap.selector); ag.fight(0);
    }
    function testWork2x() public {
        ag.work(0, 10); vm.warp(1_800_000_000 + 11 hours);
        uint256 t0 = hunt.balanceOf(tre); (uint256 base, uint256 bonus) = ag.claimWork();
        assertGt(base, 0); assertEq(bonus, base); assertEq(hunt.balanceOf(tre) - t0, base * 2);
    }
}

contract WhitelistTest is Base {
    function testBatchAddClaimOnce() public {
        assertEq(wl.added(), 0);
        address[] memory a = new address[](2); a[0] = alice; a[1] = bob; wl.addBatch(a); wl.addBatch(a);
        assertEq(wl.added(), 2);
        vm.prank(alice); uint256 id = wl.claim(); assertEq(hero.ownerOf(id), alice);
        vm.prank(alice); vm.expectRevert(WhitelistMint.NotListed.selector); wl.claim();
        vm.prank(carol); vm.expectRevert(WhitelistMint.NotListed.selector); wl.claim();
        vm.prank(alice); vm.expectRevert(); hero.transferFrom(alice, bob, id); // 7-day lock
        wl.addBatch(a); assertEq(wl.added(), 2); // claimed address not re-added
    }
    function testCap200AndRemove() public {
        address[] memory a = new address[](200); for (uint256 i; i < 200; i++) a[i] = address(uint160(2000 + i));
        wl.addBatch(a); assertEq(wl.remaining(), 0);
        address[] memory x = new address[](1); x[0] = alice;
        vm.expectRevert(WhitelistMint.Cap.selector); wl.addBatch(x);
        wl.remove(a[0]); wl.addBatch(x); assertEq(wl.added(), 200);
    }
    function testOnlyOwnerAndOnlyMinter() public {
        address[] memory x = new address[](1); x[0] = alice;
        vm.prank(bob); vm.expectRevert(); wl.addBatch(x);
        vm.prank(bob); vm.expectRevert(GameMainnet.NotOwner.selector); game.mintFree(bob, 4);
    }
}

contract ReferralMainnetTest is Base {
    /// pity (30 mints -> guaranteed Epic) must accrue to the real player, not the Referral contract
    function testPityPerPlayerViaReferral() public {
        uint256 t = 1_800_000_000; uint256 sinceEpic; uint256 maxGap;
        for (uint256 i; i < 90; i++) {
            if (i % 10 == 0 && i > 0) { t += 1 days; vm.warp(t); }
            vm.prevrandao(bytes32(i + 77));
            vm.prank(alice); uint256 id = rf.mint(1, address(0));
            assertEq(hero.ownerOf(id), alice);
            assertEq(game.pityCounter(address(rf)), 0, "pity must not accrue to Referral");
            if (hero.getHero(id).rarity >= 2) { sinceEpic = 0; } else { sinceEpic++; }
            assertEq(game.pityCounter(alice), sinceEpic, "pity tracked per player");
            if (sinceEpic > maxGap) maxGap = sinceEpic;
        }
        assertLt(maxGap, 30, "pity guarantees Epic within 30 mints");
        assertEq(hero.balanceOf(address(rf)), 0);
    }
    function testMintForOnlyMinter() public {
        vm.prank(bob); vm.expectRevert(GameMainnet.NotOwner.selector); game.mintFor(bob, 1);
    }
    function testIneligibleReferrerEarnsNothingAndNoBinding() public {
        vm.prank(bob); rf.mint(2, alice); // alice never paid
        assertEq(rf.credits(alice), 0); assertEq(rf.referrerOf(bob), address(0));
    }
    function testTwoPaidHeroesOneCredit() public {
        vm.prank(alice); rf.mint(1, address(0)); assertTrue(rf.eligible(alice));
        vm.prank(bob); rf.mint(1, alice); assertEq(rf.credits(alice), 0); assertEq(rf.points(alice), 1);
        vm.warp(block.timestamp + 1 days); vm.prank(bob); rf.mint(1, address(0)); // bound referrer still credited
        assertEq(rf.credits(alice), 1); assertEq(rf.points(alice), 0);
        vm.prank(alice); uint256 id = rf.redeem(); assertEq(hero.ownerOf(id), alice);
        vm.prank(alice); vm.expectRevert(ReferralMainnet.NoCredit.selector); rf.redeem();
        vm.prank(alice); vm.expectRevert(); hero.transferFrom(alice, carol, id); // free hero locked 7d
    }
    function testBindingIsPermanentAndNoSelfOrMutual() public {
        vm.prank(alice); rf.mint(1, address(0)); vm.prank(carol); rf.mint(1, address(0));
        vm.prank(bob); rf.mint(2, alice); vm.prank(bob); rf.mint(2, carol); // still bound to alice
        assertEq(rf.referrerOf(bob), alice); assertEq(rf.credits(alice), 2); assertEq(rf.credits(carol), 0);
        vm.prank(alice); vm.expectRevert(ReferralMainnet.Bad.selector); rf.mint(1, alice);
        vm.prank(alice); rf.mint(1, bob); assertEq(rf.referrerOf(alice), address(0)); // mutual blocked
    }
    function testDailyCreditCap() public {
        vm.prank(alice); rf.mint(1, address(0));
        for (uint256 i; i < 8; i++) { address w = address(uint160(5000 + i)); hunt.transfer(w, 10_000 ether);
            vm.startPrank(w); hunt.approve(address(rf), type(uint256).max); rf.mint(2, alice); vm.stopPrank(); }
        assertEq(rf.credits(alice), 5); assertEq(rf.creditsOnDay(alice, block.timestamp / 1 days), 5);
    }
    function testWalletCapViaReferralAndDirect() public {
        for (uint256 i; i < 4; i++) { vm.prank(bob); game.mint(2); }
        assertEq(game.walletDailyCap(), 10);
        vm.prank(bob); game.mint(1); vm.prank(bob); vm.expectRevert(GameMainnet.Cap.selector); rf.mint(2, address(0));
        vm.prank(bob); rf.mint(1, address(0));
        vm.prank(bob); vm.expectRevert(GameMainnet.Cap.selector); game.mint(1);
    }
    function testNoOfficialSpecialWork() public view { Hero.HeroData memory h = hero.getHero(0); assertEq(h.attrs[0], 100); }
}
