// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hero} from "./Hero.sol";

/// @title On-chain hero vs alien battles (TESTNET).
/// @notice Randomness uses prevrandao/blockhash and is NOT secure for mainnet (validators/bots can bias it).
contract Battle is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero;

    uint8 public constant MAX_ROUNDS = 12;
    uint256 public fightsPerHeroPerDay = 3;
    uint256 public fightsPerWalletPerDay = 10;
    uint256 public cooldown = 10 minutes;
    uint256 public dailyRewardCap = 20_000 ether;
    uint256[3] public reward = [uint256(50 ether), 150 ether, 400 ether];
    uint256 public officialMult = 200;
    uint256 public officialAttr = 999;               // OFFICIAL #000 battles with all attributes = 999 (Hero stores uint8, so applied here)               // OFFICIAL #000 earns 200x
    uint256 public officialDailyCap = 1_000_000 ether;
    uint256 public officialFightsPerDay = 10; // separate daily budget for OFFICIAL
    mapping(uint256 => uint256) public paidOfficialOnDay;

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
    function setOfficial(uint256 mult, uint256 dayCap, uint256 attr, uint256 fights) external onlyOwner { require(attr <= 5000); officialMult = mult; officialDailyCap = dayCap; officialAttr = attr; officialFightsPerDay = fights; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function withdraw(uint256 a) external onlyOwner { hunt.safeTransfer(owner(), a); }
    function today() public view returns (uint256) { return block.timestamp / 1 days; }

    function alienStats(uint8 tier, uint8 lv) public pure returns (uint16 hp, uint16 atk, uint16 dodge) {
        hp = uint16(180 + uint256(tier) * 120 + uint256(lv) * 12);
        atk = uint16(28 + uint256(tier) * 14 + uint256(lv) * 2);
        dodge = uint16(10 + uint256(tier) * 5); // percent
    }

    struct Sim { bool win; uint8 r; uint16 hMax; uint16 aMax; uint16[] hd; uint16[] ad; bool[] hc; }
    struct St { uint256 atk; uint256 crit; uint256 hDodge; uint256 aAtk; uint256 aDodge; uint256 con; uint256 hp; uint256 ap; }

    function _sim(Hero.HeroData memory h, uint8 tier, uint256 seed) internal view returns (Sim memory m) {
        St memory s;
        uint256[5] memory at; for (uint256 i; i < 5; i++) at[i] = h.isOfficial ? officialAttr : h.attrs[i];
        uint256 mx = at[0]; for (uint256 i = 1; i < 5; i++) if (at[i] > mx) mx = at[i];
        m.hMax = uint16(100 + at[4] * 3 + uint256(h.level) * 10);
        s.atk = mx + uint256(h.level) * 2 + uint256(h.rarity) * 6;
        s.crit = at[1] / 4 > 75 ? 75 : at[1] / 4; s.hDodge = 5 + at[1] / 8 > 60 ? 60 : 5 + at[1] / 8;
        s.con = at[4] > 200 ? 200 : at[4];
        (uint16 aMax, uint16 aAtk, uint16 aDodge) = alienStats(tier, h.level);
        m.aMax = aMax; s.aAtk = aAtk; s.aDodge = h.isOfficial ? 0 : aDodge; // OFFICIAL never misses
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
                m.ad[r] = uint16(dm); s.hp = dm >= s.hp ? (h.isOfficial ? 1 : 0) : s.hp - dm; // OFFICIAL cannot be knocked out
            }
            r++;
        }
        m.win = s.ap == 0 || h.isOfficial; m.r = r; // OFFICIAL always wins
        uint16[] memory hd = m.hd; uint16[] memory ad = m.ad; bool[] memory hc = m.hc;
        assembly ("memory-safe") { mstore(hd, r) mstore(ad, r) mstore(hc, r) }
    }

    function fight(uint256 id, uint8 tier) external nonReentrant whenNotPaused returns (bool win) {
        if (tier > 2) revert Bad();
        if (hero.ownerOf(id) != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil || block.timestamp < lastFight[id] + cooldown) revert Busy();
        uint256 d = today();
        if (++heroFightsOnDay[id][d] > (h.isOfficial ? officialFightsPerDay : fightsPerHeroPerDay)) revert Cap();
        if (++walletFightsOnDay[msg.sender][d] > fightsPerWalletPerDay) revert Cap();
        lastFight[id] = block.timestamp;

        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), msg.sender, id, ++_nonce)));
        Sim memory m = _sim(h, tier, seed);
        win = m.win;
        uint256 pay;
        if (win) {
            bool off = h.isOfficial;
            pay = off ? reward[tier] * officialMult : reward[tier];
            uint256 cap = off ? officialDailyCap : dailyRewardCap; uint256 used = off ? paidOfficialOnDay[d] : paidOnDay[d];
            uint256 left = cap > used ? cap - used : 0;
            uint256 bal = hunt.balanceOf(address(this));
            if (pay > left) pay = left; if (pay > bal) pay = bal;
            if (pay > 0) { if (off) paidOfficialOnDay[d] += pay; else paidOnDay[d] += pay; hunt.safeTransfer(msg.sender, pay); }
        }
        emit Fought(msg.sender, id, tier, win, m.r, m.hMax, m.aMax, m.hd, m.ad, m.hc, pay);
    }
}
