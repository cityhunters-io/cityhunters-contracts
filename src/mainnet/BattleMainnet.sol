// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hero} from "../Hero.sol";

/// @title On-chain hero vs alien battles (MAINNET CANDIDATE). OFFICIAL #000: fixed, public 2x reward only; normal stats & simulation.
/// @notice Randomness uses prevrandao/blockhash and is NOT secure for mainnet (validators/bots can bias it).
contract BattleMainnet is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero;

    uint8 public constant MAX_ROUNDS = 12;
    uint256 public fightsPerHeroPerDay = 3;
    uint256 public fightsPerWalletPerDay = 10;
    uint256 public cooldown = 10 minutes;
    uint256 public dailyRewardCap = 20_000 ether;
    uint256[3] public reward = [uint256(50 ether), 150 ether, 400 ether];
    uint256 public constant OFFICIAL_MULT = 2; // publicly disclosed, immutable
    uint256 public constant OFFICIAL_FIGHTS_PER_DAY = 10; // publicly disclosed: OFFICIAL #000 may fight 10x/day (normal heroes: fightsPerHeroPerDay)

    mapping(uint256 => uint256) public lastFight;
    mapping(uint256 => mapping(uint256 => uint256)) public heroFightsOnDay;
    mapping(address => mapping(uint256 => uint256)) public walletFightsOnDay;
    mapping(uint256 => uint256) public paidOnDay;
    uint256 private _nonce;

    error NotOwner(); error Busy(); error Cap(); error Bad();
    /// rounds: per round 4 bits [heroHit, heroCrit, alienHit, unused]; dmg arrays hold damage per strike (0 = MISS).
    event Fought(address indexed player, uint256 indexed heroId, uint8 tier, bool win, uint8 rounds,
        uint16 heroMaxHp, uint16 alienMaxHp, uint16[] heroDmg, uint16[] alienDmg, bool[] heroCrit, uint256 reward);

    constructor(address owner_, IERC20 h, Hero hr) Ownable(owner_) { hunt = h; hero = hr; }

    function setRules(uint256 perHero, uint256 perWallet, uint256 cd, uint256 dayCap, uint256[3] calldata r) external onlyOwner {
        fightsPerHeroPerDay = perHero; fightsPerWalletPerDay = perWallet; cooldown = cd; dailyRewardCap = dayCap; reward = r;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function withdraw(uint256 a) external onlyOwner { hunt.safeTransfer(owner(), a); }
    function today() public view returns (uint256) { return block.timestamp / 1 days; }

    /// @dev alien HP lookup [tier1..2][rarity0..3][level1..20], uint16 big-endian. Calibrated by Monte Carlo so that
    /// Lv1 Common wins ~35% (tier1) / ~5% (tier2), +25pp by Lv10, +10pp more by Lv20, +5pp per rarity step.
    bytes private constant HP_TABLE = hex"02490266028902a802c802f0031303360359037b03a603d403fd04280453047b04a104ca04ec050c031e033f0361038103a103c603e6040b04280447047004a104c704e90514053405540573058a059e03c603e30402041f043c045b0475048c049e04ad04cd04ef05090526054205590570058d05a105b0043f04530467047504840492049e04aa04b604be04d804fd0514052e054e05650576059305a405b502600263026f027d028e02a802bc02d602ed030a0330035c038103a903d703ff04250456047e04a40313031e0330034503560370038a03a303ba03d703fd042b0450047504a104c404e905120534055103a103b203c603dd03f1040b041f04360444045b0478049b04b804d804fd051a0534055c0579059304190428043c04470450046404700481048c049b04b804db04f5050f0531054b0565058a05a105b8";
    function alienStats(uint8 tier, uint8 lv, uint8 rar) public pure returns (uint16 hp, uint16 atk, uint16 dodge) {
        if (tier == 0) return (180, 28, 10);
        uint256 l = lv == 0 ? 0 : lv > 20 ? 19 : uint256(lv) - 1; uint256 r = rar > 3 ? 3 : rar;
        uint256 i = (((uint256(tier) - 1) * 4 + r) * 20 + l) * 2;
        hp = uint16(uint8(HP_TABLE[i])) << 8 | uint16(uint8(HP_TABLE[i + 1]));
        // v2 balance: tier-3 alien HP eases 1% per level from Lv11 down to 90% at Lv20 (Lv20 Common >=50% vs every tier)
        if (tier == 2 && l >= 10) hp = uint16(uint256(hp) * (100 - (l - 9)) / 100);
        (atk, dodge) = tier == 1 ? (uint16(50), uint16(15)) : (uint16(72), uint16(20));
    }

    struct Sim { bool win; uint8 r; uint16 hMax; uint16 aMax; uint16[] hd; uint16[] ad; bool[] hc; }
    struct St { uint256 atk; uint256 crit; uint256 hDodge; uint256 aAtk; uint256 aDodge; uint256 con; uint256 hp; uint256 ap; }

    function simulate(Hero.HeroData memory h, uint8 tier, uint256 seed) external view returns (bool win, uint8 rounds) { Sim memory m = _sim(h, tier, seed); return (m.win, m.r); }
    function _sim(Hero.HeroData memory h, uint8 tier, uint256 seed) internal view returns (Sim memory m) {
        St memory s;
        uint256[5] memory at; for (uint256 i; i < 5; i++) at[i] = h.attrs[i];
        uint256 mx = at[0]; for (uint256 i = 1; i < 5; i++) if (at[i] > mx) mx = at[i];
        m.hMax = uint16(100 + at[4] * 3 + uint256(h.level) * 10);
        s.atk = mx + uint256(h.level) * 2 + uint256(h.rarity) * 6;
        s.crit = at[1] / 4 > 75 ? 75 : at[1] / 4; s.hDodge = 5 + at[1] / 8 > 60 ? 60 : 5 + at[1] / 8;
        s.con = at[4] > 200 ? 200 : at[4];
        (uint16 aMax, uint16 aAtk, uint16 aDodge) = alienStats(tier, h.level, h.rarity);
        m.aMax = aMax; s.aAtk = aAtk; s.aDodge = aDodge;
        s.hp = m.hMax; s.ap = aMax;
        m.hd = new uint16[](MAX_ROUNDS); m.ad = new uint16[](MAX_ROUNDS); m.hc = new bool[](MAX_ROUNDS);
        uint8 r;
        while (r < MAX_ROUNDS && s.hp > 0 && s.ap > 0) {
            seed = uint256(keccak256(abi.encode(seed)));
            if (seed % 100 >= s.aDodge) {
                uint256 dm = s.atk * (70 + (seed >> 8) % 61) / 100;
                if ((seed >> 16) % 100 < s.crit) { dm *= 2; m.hc[r] = true; }
                if (dm == 0) dm = 1;
                m.hd[r] = uint16(dm); s.ap = dm >= s.ap ? 0 : s.ap - dm;
            }
            if (s.ap > 0 && (seed >> 24) % 100 >= s.hDodge) {
                uint256 dm = s.aAtk * (70 + (seed >> 32) % 61) / 100 * (250 - s.con) / 250;
                if (dm == 0) dm = 1;
                m.ad[r] = uint16(dm); s.hp = dm >= s.hp ? 0 : s.hp - dm;
            }
            r++;
        }
        m.win = s.ap == 0; m.r = r;
        uint16[] memory hd = m.hd; uint16[] memory ad = m.ad; bool[] memory hc = m.hc;
        assembly ("memory-safe") { mstore(hd, r) mstore(ad, r) mstore(hc, r) }
    }

    /// @notice organic-looking drop: whole HUNT uniformly in [50%, 150%] of base; values ending in 0 or 5 are nudged by 1..4 inside the range.
    function _drop(uint256 base, uint256 r) internal pure returns (uint256) {
        uint256 b = base / 1 ether; uint256 lo = b / 2; uint256 hi = b * 3 / 2;
        if (hi <= lo) return base;
        uint256 x = lo + r % (hi - lo + 1);
        if (x % 5 == 0) { uint256 k = 1 + (r >> 128) % 4; x = x + k <= hi ? x + k : x - k; }
        return x * 1 ether;
    }
    function previewDrop(uint8 tier, uint256 r) external view returns (uint256) { return _drop(reward[tier], r); }
    function fight(uint256 id, uint8 tier) external nonReentrant whenNotPaused returns (bool win) {
        if (tier > 2) revert Bad();
        if (hero.ownerOf(id) != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil || block.timestamp < lastFight[id] + cooldown) revert Busy();
        uint256 d = today();
        if (++heroFightsOnDay[id][d] > (h.isOfficial ? OFFICIAL_FIGHTS_PER_DAY : fightsPerHeroPerDay)) revert Cap();
        if (++walletFightsOnDay[msg.sender][d] > fightsPerWalletPerDay) revert Cap();
        lastFight[id] = block.timestamp;

        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), msg.sender, id, ++_nonce)));
        Sim memory m = _sim(h, tier, seed);
        win = m.win;
        uint256 pay;
        if (win) {
            // randomized drop: tier base x 50%..150% (from fight seed), then OFFICIAL 2x
            pay = _drop(reward[tier], uint256(keccak256(abi.encode(seed, "drop")))) ;
            if (h.isOfficial) pay *= OFFICIAL_MULT; // x2 keeps it non-round (2x % 5 == 0 iff x % 5 == 0)
            uint256 left = dailyRewardCap > paidOnDay[d] ? dailyRewardCap - paidOnDay[d] : 0;
            uint256 bal = hunt.balanceOf(address(this));
            if (pay > left) pay = left; if (pay > bal) pay = bal;
            if (pay > 0) { paidOnDay[d] += pay; hunt.safeTransfer(msg.sender, pay); }
        }
        emit Fought(msg.sender, id, tier, win, m.r, m.hMax, m.aMax, m.hd, m.ad, m.hc, pay);
    }
}
