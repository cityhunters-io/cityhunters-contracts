// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "../src/HuntToken.sol"; import "../src/Hero.sol"; import "../src/Game.sol"; import "../src/MockAgentCity.sol";
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY"); address me = vm.addr(pk);
        address USER_WALLET = 0x145479F86ff50d9Ea3DA856f81Fa22B7F53665ad; // treasury + season pool (testnet & intended mainnet)
        require(block.chainid == 97 || block.chainid == 31337, "testnet/local only");
        vm.startBroadcast(pk);
        HuntToken hunt = new HuntToken(me); Hero hero = new Hero(me); MockAgentCity city = new MockAgentCity();
        Game game = new Game(me, hunt, hero, city, USER_WALLET, USER_WALLET, 100 ether); // placeholder: 1 USD = 100 HUNT
        hero.setGame(address(game));
        game.mintOfficial();
        hunt.approve(address(game), 10_000_000 ether); game.fundRewards(10_000_000 ether);
        city.mint(me);
        vm.stopBroadcast();
        console.log("HUNT", address(hunt)); console.log("Hero", address(hero));
        console.log("MockAgentCity", address(city)); console.log("Game", address(game));
    }
}
