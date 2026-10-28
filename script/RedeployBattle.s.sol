// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "../src/mainnet/BattleMainnet.sol"; import "../src/mainnet/OfficialAgentMainnet.sol";
/// Battle v2 (tier-3 HP ease). Deploy wallet = owner of old Battle + OfficialAgent. Mainnet needs CONFIRM_MAINNET=YES.
contract RedeployBattle is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY"); address me = vm.addr(pk);
        if (block.chainid == 56) require(keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("YES"), "set CONFIRM_MAINNET=YES");
        BattleMainnet old = BattleMainnet(vm.envOr("OLD_BATTLE", address(0xE985199d7cDf4a8211b07Ab7C57f3E7e40c5a25A)));
        OfficialAgentMainnet ag = OfficialAgentMainnet(vm.envOr("OFFICIAL", address(0x1E5F0896F6d568157fc6f71C29Cb7833d1C41D0f)));
        IERC20 hunt = old.hunt(); Hero hero = old.hero();
        uint256[3] memory r = [old.reward(0), old.reward(1), old.reward(2)];
        vm.startBroadcast(pk);
        BattleMainnet nb = new BattleMainnet(me, hunt, hero);
        nb.setRules(old.fightsPerHeroPerDay(), old.fightsPerWalletPerDay(), old.cooldown(), old.dailyRewardCap(), r);
        old.pause();
        uint256 bal = hunt.balanceOf(address(old)); old.withdraw(bal); hunt.transfer(address(nb), bal);
        ag.setBattle(nb);
        vm.stopBroadcast();
        console.log("NEW_BATTLE", address(nb)); console.log("moved HUNT", bal / 1 ether);
    }
}
