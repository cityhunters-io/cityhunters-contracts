// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../../src/HuntToken.sol"; import "../../src/Hero.sol"; import "../../src/MockAgentCity.sol";
import "../../src/mainnet/GameMainnet.sol"; import "../../src/mainnet/ReferralMainnet.sol"; import "../../src/mainnet/GenesisDraw.sol";
contract MockFeed { int256 public a = 600e8; uint256 public upd; uint8 public decimals = 8;
    function set(int256 x, uint256 u) external { a = x; upd = u; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, a, upd, upd, 1); } }
contract Rejecter { receive() external payable { revert(); } function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; } }
contract GenesisBnbTest is Test {
    HuntToken hunt; Hero hero; GameMainnet game; ReferralMainnet rf; GenesisDraw gd; MockFeed feed;
    address tre = address(0x7777); address alice = address(0xA11CE); address bob = address(0xB0B);
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new GameMainnet(address(this), hunt, hero, new MockAgentCity(), tre, address(8), 100 ether);
        hero.setGame(address(game)); rf = new ReferralMainnet(address(this), hunt, hero, game); game.setMinter(address(rf), true);
        gd = new GenesisDraw(address(this), hunt, IGameG(address(game))); game.setGenesisDraw(gd); gd.setReferral(address(rf));
        feed = new MockFeed(); feed.set(600e8, block.timestamp); game.setPriceFeed(AggregatorV3Interface(address(feed)), 1 hours);
        hunt.approve(address(game), type(uint256).max); game.fundRewards(1_000_000 ether);
        vm.deal(alice, 100 ether); vm.deal(bob, 100 ether); P = game.mintPriceBnb();
        hunt.transfer(alice, 100_000 ether); vm.prank(alice); hunt.approve(address(game), type(uint256).max);
    }
    function _u(uint256 i) internal returns (address u) { u = address(uint160(0x20000 + i)); vm.deal(u, 10 ether); }
    uint256 P; function _p() internal view returns (uint256) { return P; }
    function testPriceIs10UsdInBnb() public view { uint256 n = 10e36; uint256 d = 600e18; assertEq(game.mintPriceBnb(), (n + d - 1) / d); assertApproxEqAbs(_p(), uint256(1 ether) / 60, 1); }
    function testBnbMintSplitAndRefund() public {
        uint256 c = _p() * 2; uint256 a0 = alice.balance;
        vm.prank(alice); game.mintBnb{value: c * 102 / 100}(2);
        assertEq(a0 - alice.balance, c, "excess refunded");
        assertEq(address(gd).balance, c * 15 / 100); assertEq(tre.balance, c - c * 15 / 100);
        assertEq(hero.balanceOf(alice), 2); assertEq(gd.paidMints(alice), 2);
    }
    function testUnderpaidReverts() public { uint256 c = _p(); vm.prank(alice); vm.expectRevert(GameMainnet.Underpaid.selector); game.mintBnb{value: c - 1}(1); }
    function testHuntPathDisabledInGenesisAndBnbAfter() public {
        vm.prank(alice); vm.expectRevert(GameMainnet.Bad.selector); game.mint(1);
        vm.warp(game.genesisEnd()); feed.set(600e8, block.timestamp);
        uint256 p20 = game.mintPriceBnb(); assertEq(p20, (uint256(20e36) + 600e18 - 1) / 600e18, "20 USD after genesis"); assertApproxEqAbs(p20, 2 * P, 1);
        uint256 t0 = tre.balance; uint256 d0 = address(gd).balance; vm.prank(alice); game.mintBnb{value: p20}(1);
        assertEq(tre.balance - t0, p20, "no draw share after genesis"); assertEq(address(gd).balance, d0);
        uint256 s0 = hunt.totalSupply(); vm.prank(alice); game.mint(1); assertEq(s0 - hunt.totalSupply(), 2000 ether * 30 / 100);
        vm.prank(alice); vm.expectRevert(GameMainnet.Underpaid.selector); rf.mint{value: 1}(1, address(0));
    }
    function testStaleAndBadOracleRevert() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(alice); vm.expectRevert(GameMainnet.Stale.selector); game.mintBnb{value: 1 ether}(1);
        feed.set(0, block.timestamp); vm.expectRevert(GameMainnet.Stale.selector); game.mintPriceBnb();
        feed.set(-5, block.timestamp); vm.expectRevert(GameMainnet.Stale.selector); game.mintPriceBnb();
        feed.set(600e8, block.timestamp); assertGt(_p(), 0);
    }
    function testReferralBnbMintRefundToPlayerAndCredits() public {
        vm.prank(alice); rf.mint{value: _p()}(1, address(0));
        uint256 c = _p() * 2; uint256 b0 = bob.balance;
        vm.prank(bob); rf.mint{value: c + 0.01 ether}(2, alice);
        assertEq(b0 - bob.balance, c, "refund to player"); assertEq(address(rf).balance, 0);
        assertEq(rf.credits(alice), 1); assertEq(gd.paidMints(bob), 2); assertEq(gd.referrals(alice), 1);
        assertEq(hero.balanceOf(bob), 2); assertEq(game.pityCounter(address(rf)), 0);
        vm.prank(alice); rf.redeem(); assertEq(hero.balanceOf(alice), 2);
    }
    function testWalletCap10SharedBnb() public {
        for (uint256 i; i < 4; i++) { vm.prank(alice); game.mintBnb{value: _p() * 2}(2); }
        vm.prank(alice); rf.mint{value: _p()}(1, address(0)); vm.prank(alice); game.mintBnb{value: _p()}(1);
        vm.prank(alice); vm.expectRevert(GameMainnet.Cap.selector); game.mintBnb{value: _p()}(1);
        vm.prank(alice); vm.expectRevert(GameMainnet.Cap.selector); rf.mint{value: _p()}(1, address(0));
    }
    function testPityPerPlayerBnb() public {
        address u = _u(1); uint256 t = block.timestamp; uint256 since;
        for (uint256 i; i < 40; i++) {
            if (i % 10 == 0 && i > 0) { t += 1 days; vm.warp(t); }
            if (t >= game.genesisEnd()) break;
            feed.set(600e8, block.timestamp); vm.prevrandao(bytes32(i + 9)); uint256 id = hero.nextId();
            vm.prank(u); rf.mint{value: _p()}(1, address(0));
            if (hero.getHero(id).rarity >= 2) since = 0; else since++;
            assertEq(game.pityCounter(u), since); assertEq(game.pityCounter(address(rf)), 0);
        }
    }
    function _mint10(address u) internal { for (uint256 i; i < 5; i++) { vm.prank(u); game.mintBnb{value: _p() * 2}(2); } }
    function _draw() internal { feed.set(600e8, block.timestamp); gd.commit(); vm.roll(block.number + 6); gd.reveal(); }
    function testEligibilityTenReferralsDistinct() public {
        vm.prank(alice); rf.mint{value: _p()}(1, address(0));
        for (uint256 i; i < 9; i++) { address u = _u(i); vm.prank(u); rf.mint{value: _p()}(1, alice); vm.prank(u); rf.mint{value: _p()}(1, alice); }
        assertEq(gd.referrals(alice), 9); assertFalse(gd.isEligible(alice));
        address w = _u(50); vm.prank(w); rf.mint{value: _p()}(1, alice); assertTrue(gd.isEligible(alice));
    }
    function testDrawPaysBnbThreeDistinct() public {
        address[5] memory us; for (uint256 i; i < 5; i++) { us[i] = _u(i); _mint10(us[i]); }
        uint256[5] memory b; for (uint256 i; i < 5; i++) b[i] = us[i].balance;
        vm.expectRevert(GenesisDraw.Early.selector); gd.commit();
        vm.warp(game.genesisEnd()); uint256 total = gd.escrow(); assertEq(total, address(gd).balance); assertGt(total, 0);
        vm.prank(bob); gd.commit(); vm.expectRevert(GenesisDraw.Wait.selector); gd.reveal(); vm.roll(block.number + 6); vm.prank(bob); gd.reveal();
        address[] memory w = gd.winnerList(); assertEq(w.length, 3); assertTrue(w[0] != w[1] && w[1] != w[2] && w[0] != w[2]);
        uint256 got; for (uint256 i; i < 5; i++) got += us[i].balance - b[i];
        assertEq(got, total); assertEq(address(gd).balance, 0);
    }
    function testFewerThanThreeAndNoneToTreasury() public {
        vm.prank(alice); game.mintBnb{value: _p()}(1);
        vm.warp(game.genesisEnd()); uint256 e = gd.escrow(); uint256 t0 = tre.balance; _draw();
        assertEq(tre.balance - t0, e); assertEq(gd.winnerList().length, 0);
    }
    function testRejectingWinnerCanPull() public {
        Rejecter x = new Rejecter(); vm.deal(address(x), 10 ether);
        for (uint256 i; i < 5; i++) { vm.prank(address(x)); vm.expectRevert(); game.mintBnb{value: _p() * 2 + 1}(2); } // refund to rejecter fails -> revert
        for (uint256 i; i < 5; i++) { vm.prank(address(x)); game.mintBnb{value: _p() * 2}(2); } // exact pay, no refund
        assertTrue(gd.isEligible(address(x)));
        vm.warp(game.genesisEnd()); uint256 e = gd.escrow(); _draw();
        assertEq(gd.owed(address(x)), e); assertEq(gd.escrow(), 0);
    }
}
