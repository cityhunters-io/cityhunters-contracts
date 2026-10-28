// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol"; import "../src/mainnet/BattleMainnet.sol";
contract VerifyBattle is Script {
    function ms(uint8 c) internal pure returns (uint8, uint8) {
        if (c == 0) return (0, 4); if (c == 1) return (2, 1); if (c == 2) return (3, 2);
        if (c == 3) return (1, 0); if (c == 4) return (3, 4); return (4, 0);
    }
    function rg(uint8 r) internal pure returns (uint8, uint8, uint8, uint8) {
        if (r == 0) return (61, 79, 41, 60); if (r == 1) return (80, 89, 50, 70);
        if (r == 2) return (90, 96, 61, 80); return (97, 100, 70, 90);
    }
    function run() external view {
        BattleMainnet b = BattleMainnet(vm.envAddress("BATTLE")); uint256 N = vm.envUint("N");
        uint8[5] memory lvs = [1, 5, 10, 15, 20];
        for (uint8 rar; rar < 4; rar++) for (uint256 li; li < 5; li++) {
            uint8 lv = lvs[li]; uint256[3] memory w;
            for (uint256 k; k < N; k++) {
                uint256 r = uint256(keccak256(abi.encode(rar, lv, k)));
                Hero.HeroData memory h; h.rarity = rar; h.level = lv; h.class_ = uint8(r % 6);
                (uint8 m, uint8 s) = ms(h.class_); (uint8 a, uint8 bb, uint8 c, uint8 d) = rg(rar);
                for (uint8 i; i < 5; i++) {
                    r = uint256(keccak256(abi.encode(r, i)));
                    (uint8 lo, uint8 hi) = i == m ? (a, bb) : i == s ? (c, d) : (20, 60);
                    uint256 v = lo + r % (uint256(hi) - lo + 1);
                    for (uint8 L = 2; L <= lv; L++) {
                        if (i == m) v++; else if (i == s) { if (L >= 6 && L <= 10 && L % 2 == 0) v++; }
                        else if (L >= 11 && L % 3 == 0) v++;
                    }
                    h.attrs[i] = uint8(v > 100 ? 100 : v);
                }
                for (uint8 t; t < 3; t++) { (bool win,) = b.simulate(h, t, uint256(keccak256(abi.encode(r, t, "s")))); if (win) w[t]++; }
            }
            console.log(string.concat("R", vm.toString(rar), " L", vm.toString(lv), " ", vm.toString(w[0] * 1000 / N), " ", vm.toString(w[1] * 1000 / N), " ", vm.toString(w[2] * 1000 / N)));
        }
    }
}
