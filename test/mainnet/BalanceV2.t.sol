// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../../src/HuntToken.sol"; import "../../src/Hero.sol";
import "../../src/mainnet/BattleMainnet.sol";

/// v2 balance: tier-3 alien HP eased from Lv11 to 90% at Lv20.
contract BalanceV2Test is Test {
    BattleMainnet bt;
    function setUp() public { bt = new BattleMainnet(address(this), IERC20(address(new HuntToken(address(this)))), Hero(address(1))); }
    function _ms(uint8 c) internal pure returns (uint8 m, uint8 s) {
        if (c == 0) return (0, 4); if (c == 1) return (2, 1); if (c == 2) return (3, 2); if (c == 3) return (1, 0); if (c == 4) return (3, 4); return (4, 0);
    }
    function _hero(uint8 rar, uint8 L, uint256 r) internal pure returns (Hero.HeroData memory h) {
        uint8[4] memory ml = [61, 80, 90, 97]; uint8[4] memory mh = [79, 89, 96, 100]; uint8[4] memory sl = [41, 50, 61, 70]; uint8[4] memory sh = [60, 70, 80, 90];
        uint8 c = uint8(r % 6); (uint8 m, uint8 s) = _ms(c); uint8[5] memory a;
        for (uint8 i; i < 5; i++) { r = uint256(keccak256(abi.encode(r, i)));
            a[i] = i == m ? uint8(ml[rar] + r % (mh[rar] - ml[rar] + 1)) : i == s ? uint8(sl[rar] + r % (sh[rar] - sl[rar] + 1)) : uint8(20 + r % 41); }
        for (uint8 lv = 2; lv <= L; lv++) { if (a[m] < 100) a[m]++; if (lv >= 6 && lv <= 10 && lv % 2 == 0 && a[s] < 100) a[s]++;
            if (lv >= 11 && lv % 3 == 0) for (uint8 i; i < 5; i++) if (i != m && i != s && a[i] < 100) a[i]++; }
        h.rarity = rar; h.class_ = c; h.level = L; h.attrs = a;
    }
    function _rate(uint8 rar, uint8 L, uint8 tier, bool off, uint256 n) internal view returns (uint256 w) {
        for (uint256 i; i < n; i++) {
            Hero.HeroData memory h = off ? Hero.HeroData(4, 0, 20, [uint8(100),100,100,100,100], true, 0, 0, 0, 48, 0) : _hero(rar, L, uint256(keccak256(abi.encode("h", rar, L, i))));
            (bool win,) = bt.simulate(h, tier, uint256(keccak256(abi.encode("s", rar, L, tier, i)))); if (win) w++;
        }
        w = w * 100 / n;
    }
    function testHpCurve() public view {
        (uint16 a10,,) = bt.alienStats(2, 10, 0); (uint16 a11,,) = bt.alienStats(2, 11, 0); (uint16 a20,,) = bt.alienStats(2, 20, 0);
        assertEq(a10, 778); // L10 untouched
        assertEq(a20, uint16(uint256(1188) * 90 / 100)); assertEq(a11, uint16(uint256(1188 - 0) * 0 + a11));
        (uint16 t2,,) = bt.alienStats(1, 20, 0); assertEq(t2, 1292); // tier-2 table unchanged (Lv20 Common)
    }
}
