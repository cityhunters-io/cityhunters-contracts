// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../src/HuntToken.sol"; import "../src/Hero.sol"; import "../src/Game.sol"; import "../src/MockAgentCity.sol"; import "../src/Battle.sol"; import "../src/OfficialAgent.sol";

contract BattleTest is Test {
    HuntToken hunt; Hero hero; Game game; Battle bt; address alice = address(0xA11CE); address bob = address(0xB0B);
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new Game(address(this), hunt, hero, new MockAgentCity(), address(7), address(8), 100 ether);
        hero.setGame(address(game)); bt = new Battle(address(this), hunt, hero);
        hunt.transfer(address(bt), 100_000 ether); hunt.transfer(alice, 1_000_000 ether);
        vm.startPrank(alice); hunt.approve(address(game), type(uint256).max); game.mint(2); vm.stopPrank();
    }
    function _id() internal view returns (uint256) { return hero.nextId() - 1; }
    function testFightPaysOnWinAndLimits() public {
        uint256 t = 1_800_000_000; uint256 id = _id(); uint256 wins; uint256 b0 = hunt.balanceOf(alice);
        for (uint256 i; i < 3; i++) { vm.prevrandao(bytes32(i + 1)); vm.prank(alice); if (bt.fight(id, 0)) wins++; t += 11 minutes; vm.warp(t); }
        assertEq(hunt.balanceOf(alice) - b0, wins * 50 ether);
        vm.prank(alice); vm.expectRevert(Battle.Cap.selector); bt.fight(id, 0);
    }
    function testSimRunsRoundsNormalHeroCanLose() public {
        bt.setRules(100, 100, 0, 1_000_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        uint256 id = _id(); uint256 losses;
        for (uint256 i; i < 10; i++) {
            vm.prevrandao(bytes32(i + 900)); vm.recordLogs(); vm.prank(alice); if (!bt.fight(id, 2)) losses++;
            Vm.Log[] memory L = vm.getRecordedLogs();
            for (uint256 k; k < L.length; k++) if (L[k].topics[0] == Battle.Fought.selector) {
                (, , uint8 r, , , uint16[] memory hd, , , ) = abi.decode(L[k].data, (uint8, bool, uint8, uint16, uint16, uint16[], uint16[], bool[], uint256));
                assertGt(r, 0); assertEq(hd.length, r);
            }
        }
        assertGt(losses, 0);
    }
    function testCooldownOwnerTier() public {
        uint256 id = _id(); vm.prank(alice); bt.fight(id, 1);
        vm.prank(alice); vm.expectRevert(Battle.Busy.selector); bt.fight(id, 1);
        vm.prank(bob); vm.expectRevert(Battle.NotOwner.selector); bt.fight(id, 1);
        vm.warp(1_800_000_000 + 11 minutes); vm.prank(alice); vm.expectRevert(Battle.Bad.selector); bt.fight(id, 3);
    }
    function testDailyCap() public {
        bt.setRules(100, 100, 0, 60 ether, [uint256(50 ether), 150 ether, 400 ether]);
        uint256 id = _id(); uint256 b0 = hunt.balanceOf(alice);
        for (uint256 i; i < 20; i++) { vm.prevrandao(bytes32(i + 9)); vm.prank(alice); bt.fight(id, 0); }
        assertLe(hunt.balanceOf(alice) - b0, 60 ether);
    }
}

contract OfficialTest is Test {
    HuntToken hunt; Hero hero; Game game; Battle bt; OfficialAgent ag; address tre = address(7);
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new Game(address(this), hunt, hero, new MockAgentCity(), tre, address(8), 100 ether);
        hero.setGame(address(game)); hunt.approve(address(game), type(uint256).max); game.fundRewards(1_000_000 ether); game.mintOfficial();
        bt = new Battle(address(this), hunt, hero); hunt.transfer(address(bt), 1_000_000 ether);
        ag = new OfficialAgent(address(this), hunt, hero, game, bt); hunt.transfer(address(ag), 5_000_000 ether);
        hero.safeTransferFrom(address(this), address(ag), 0);
    }
    function testWork200x() public {
        ag.work(0, 10); vm.warp(1_800_000_000 + 11 hours);
        uint256 t0 = hunt.balanceOf(tre); (uint256 base, uint256 bonus) = ag.claimWork();
        assertGt(base, 0); assertEq(bonus, base * 199); assertEq(hunt.balanceOf(tre) - t0, base * 200);
    }
    function testBattle200x() public {
        uint256 t0 = hunt.balanceOf(tre); bool w = ag.fight(0);
        assertEq(hunt.balanceOf(tre) - t0, w ? 50 ether * 200 : 0);
    }
    function testOfficial10PerDay() public {
        uint256 t = 1_800_000_000;
        for (uint256 i; i < 10; i++) { vm.prevrandao(bytes32(i + 1)); ag.fight(0); t += 11 minutes; vm.warp(t); }
        vm.expectRevert(Battle.Cap.selector); ag.fight(0);
    }
    event Fought(address indexed player, uint256 indexed heroId, uint8 tier, bool win, uint8 rounds, uint16 heroMaxHp, uint16 alienMaxHp, uint16[] heroDmg, uint16[] alienDmg, bool[] heroCrit, uint256 reward);
    function testOfficialNeverMisses() public {
        uint256 t = 1_800_000_000;
        for (uint256 i; i < 10; i++) {
            vm.prevrandao(bytes32(i + 77)); vm.recordLogs(); assertTrue(ag.fight(2));
            Vm.Log[] memory L = vm.getRecordedLogs();
            for (uint256 k; k < L.length; k++) if (L[k].topics[0] == Fought.selector) {
                (, , , , , uint16[] memory hd, , , ) = abi.decode(L[k].data, (uint8, bool, uint8, uint16, uint16, uint16[], uint16[], bool[], uint256));
                for (uint256 r; r < hd.length; r++) assertGt(hd[r], 0);
            }
            t += 11 minutes; vm.warp(t);
        }
    }
    function testOfficialAlwaysWinsEvenWeak() public {
        bt.setOfficial(200, 1_000_000 ether, 1, 10); uint256 t = 1_800_000_000;
        for (uint256 i; i < 10; i++) { vm.prevrandao(bytes32(i + 5)); assertTrue(ag.fight(2)); t += 11 minutes; vm.warp(t); }
    }
    function testOfficial999NoOverflow() public {
        for (uint8 i; i < 3; i++) { vm.prevrandao(bytes32(uint256(i + 1))); bt.setRules(100, 100, 0, 20_000 ether, [uint256(50 ether), 150 ether, 400 ether]); assertTrue(ag.fight(2)); }
    }
}
