// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../../src/mainnet/BattleMainnetV3.sol";
contract V3Rates is Test {
  function test_rates() public {
    vm.createSelectFork("https://bsc-rpc.publicnode.com");
    Hero hero = Hero(0xF10d29ea0480AC292a616Ff3692fCd27961A3Aa2);
    BattleMainnetV3 nb = new BattleMainnetV3(address(this), IERC20(0x03353e0Dfc5123de796417f98437e45B48d88146), hero);
    uint256[3] memory w; uint256 n;
    for (uint256 id=0; id<=40; id++) {
      try hero.getHero(id) returns (Hero.HeroData memory h) {
        n++;
        for (uint256 s=0;s<200;s++) for (uint8 t=0;t<3;t++){ (bool win,)=nb.simulate(h,t,uint256(keccak256(abi.encode(id,s,t)))); if(win) w[t]++; }
      } catch {}
    }
    console.log("heroes",n);
    console.log("T1 bps",w[0]*10000/(n*200)); console.log("T2 bps",w[1]*10000/(n*200)); console.log("T3 bps",w[2]*10000/(n*200));
    (uint16 a,,)=nb.alienStats(1,1,0); (uint16 b,,)=nb.alienStats(2,1,0); console.log("hp",a,b);
  }
}
