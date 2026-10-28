// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../../src/HuntToken.sol"; import "../../src/Hero.sol"; import "../../src/MockAgentCity.sol";
import "../../src/mainnet/GameMainnet.sol"; import "../../src/mainnet/BattleMainnet.sol";
contract MockCoord { uint256 public n; function requestRandomWords(VRFRequest calldata) external returns (uint256) { return ++n; }
    function fulfill(GameMainnet g, uint256 id, uint256 w) external { uint256[] memory a = new uint256[](1); a[0] = w; g.rawFulfillRandomWords(id, a); } }
contract MF { function decimals() external pure returns (uint8) { return 8; } function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (1, 600e8, block.timestamp, block.timestamp, 1); } }
contract VrfTest is Test {
    HuntToken hunt; Hero hero; GameMainnet game; MockCoord co; BattleMainnet bt; address al = address(0xA11CE); address bo = address(0xB0B);
    function setUp() public {
        vm.warp(1_800_000_000);
        hunt = new HuntToken(address(this)); hero = new Hero(address(this));
        game = new GameMainnet(address(this), hunt, hero, new MockAgentCity(), address(0x7777), address(8), 100 ether);
        hero.setGame(address(game)); co = new MockCoord(); game.setVrf(IVRFCoordinatorV2Plus(address(co)), bytes32(0), 1, 3, 900_000);
        game.setPriceFeed(AggregatorV3Interface(address(new MF())), 1 hours);
        game.setSaleStart(block.timestamp + 1 days);
        bt = new BattleMainnet(address(this), hunt, hero); hunt.transfer(address(bt), 100_000 ether);
        hunt.transfer(al, 1_000_000 ether); vm.prank(al); hunt.approve(address(game), type(uint256).max); vm.deal(al, 10 ether);
    }
    function testSaleGateAndGenesis3Days() public {
        uint256 p = game.mintPriceBnb(); vm.prank(al); vm.expectRevert(GameMainnet.NotStarted.selector); game.mintBnb{value: p}(1);
        assertEq(game.genesisEnd(), game.saleStart() + 3 days);
        vm.warp(game.saleStart()); vm.prank(al); game.mintBnb{value: p}(1); assertEq(hero.balanceOf(al), 0, "pending");
        co.fulfill(game, 1, 123); assertEq(hero.balanceOf(al), 1);
        vm.expectRevert(); vm.prank(al); game.rawFulfillRandomWords(1, new uint256[](1));
    }
    function _mint2() internal { vm.warp(game.saleStart()); uint256 p = game.mintPriceBnb(); vm.prank(al); game.mintBnb{value: p * 2}(2); co.fulfill(game, co.n(), 7); }
    function testMergeLockedUntilFulfill() public {
        // find a same class/rarity pair
        uint256 w = 1; uint256 a; uint256 b;
        for (uint256 k; k < 60 && a == 0; k++) { vm.warp(game.genesisEnd() + k * 1 days); vm.prank(al); game.mint(2); co.fulfill(game, co.n(), w++);
            uint256 n = hero.nextId(); Hero.HeroData memory x = hero.getHero(n - 2); Hero.HeroData memory y = hero.getHero(n - 1);
            if (x.class_ == y.class_ && x.rarity == y.rarity && x.rarity < 3) { a = n - 2; b = n - 1; } }
        require(a != 0, "no pair"); vm.warp(game.genesisEnd() + 1);
        vm.prank(al); game.merge(a, b); assertEq(hero.getHero(a).busyUntil, type(uint64).max);
        vm.prank(al); vm.expectRevert(Hero.Locked.selector); hero.transferFrom(al, bo, a);
        uint256 nid = hero.nextId(); co.fulfill(game, co.n(), 99); assertEq(hero.ownerOf(nid), al);
        vm.expectRevert(); hero.ownerOf(a);
    }
    function testTransferKeepsWalletLimits() public {
        _mint2(); uint256 id = 1; bt.setRules(3, 2, 0, 20_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        vm.warp(block.timestamp + 1); vm.startPrank(al); bt.fight(id, 2); bt.fight(2, 1); vm.expectRevert(BattleMainnet.Cap.selector); bt.fight(id, 1);
        hero.transferFrom(al, bo, id); vm.stopPrank();
        assertEq(bt.walletFightsOnDay(al, bt.today()), 2); assertEq(bt.heroFightsOnDay(id, bt.today()), 1, "hero counter follows token");
        vm.prank(bo); bt.fight(id, 1); vm.prank(bo); bt.fight(id, 1); vm.prank(bo); vm.expectRevert(BattleMainnet.Cap.selector); bt.fight(id, 1); // hero cap 3/day survives transfer
        assertEq(game.walletMintedOnDay(al, game.today()), 2); assertEq(game.walletMintedOnDay(bo, game.today()), 0);
    }
}
