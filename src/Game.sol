// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {HuntToken} from "./HuntToken.sol";
import {Hero} from "./Hero.sol";

/// @title CITY HUNTERS Game v1 (phase 1: HUNT only). All numbers are design-doc example values.
/// Randomness is blockhash/prevrandao based (NOT secure vs validators) -> replace with Chainlink VRF before scale.
/// Price is an owner-set HUNT/USD rate -> replace with TWAP/oracle (30-min TWAP, 5% deviation pause) later.
/// Phase 2 (BOUNTY) will be a new Game contract; Hero.setGame is one-shot so a migration path must be added then.
contract Game is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    HuntToken public immutable hunt;
    Hero public immutable hero;
    IERC721 public immutable agentCity;
    address public treasury;
    address public seasonPool;

    // ---- economy params ----
    uint256 public huntPerUsd;            // HUNT wei per 1 USD (owner-set; oracle later)
    uint256 public cWei = 0.1 ether;      // HUNT wei per 1 V
    uint256 public launchTime;            // genesis window = first 3 days
    uint256 public constant GENESIS_DAYS = 3 days;
    uint256 public constant GENESIS_PRICE_USD = 10;
    uint256 public constant PRICE_USD = 20;
    uint256 public constant MAX_PER_TX = 2;
    uint256 public dailyMintCap = 300;
    uint256 public walletDailyCap = 2;
    uint256 public constant PITY = 30;
    uint256 public dailyEmissionCap = 1_000_000 ether; // HUNT paid out per day, all heroes
    uint256 public maxPoolBalance = 50_000_000 ether;  // cap on HUNT reward funds held here

    // ---- free mints ----
    bytes32 public agentRoot; uint256 public agentClaimStart; uint256 public constant AGENT_WINDOW = 14 days;
    uint256 public constant FREE_LOCK = 7 days;
    mapping(bytes32 => bool) public agentIdClaimed; mapping(address => bool) public walletClaimedAgent;
    uint256 public constant GENESIS_FREE_PER_CARD = 20;
    mapping(uint256 => uint256) public genesisUsed;
    uint256 public genesisLock;          // default FREE_LOCK (7d), set in constructor
    uint256 public genesisClaimEnd;      // default launch + 14d; 0 = open-ended

    // ---- counters ----
    mapping(uint256 => uint256) public mintedOnDay;
    mapping(address => mapping(uint256 => uint256)) public walletMintedOnDay;
    mapping(address => uint256) public pityCounter;
    mapping(uint256 => uint256) public emittedOnDay;
    mapping(uint256 => mapping(uint256 => uint256)) public refillsOnDay; // hero => day => points
    uint256 private nonce;

    struct Job { uint16 base; uint16 k; uint8 minLevel; uint8 minMain; uint8 minSub; uint8 classMask; }
    Job[6] public jobs;
    struct Shift { uint8 job; uint8 hours_; }
    mapping(uint256 => Shift) public shifts;

    event Minted(address indexed to, uint256 indexed id, uint8 rarity, uint8 class_, uint8 source); // 0 paid 1 agent 2 genesis
    event WorkStarted(uint256 indexed id, uint8 job, uint8 hours_);
    event Claimed(uint256 indexed id, address indexed to, uint256 hunt);
    event Upgraded(uint256 indexed id, uint8 level, uint256 cost);
    event Merged(uint256 a, uint256 b, uint256 newId, bool success);

    error Cap(); error NotOwner(); error Busy(); error Bad();

    constructor(address owner_, HuntToken h, Hero hr, IERC721 city, address treasury_, address pool_, uint256 huntPerUsd_) Ownable(owner_) {
        hunt = h; hero = hr; agentCity = city; treasury = treasury_; seasonPool = pool_; huntPerUsd = huntPerUsd_;
        launchTime = block.timestamp;
        genesisLock = FREE_LOCK; genesisClaimEnd = block.timestamp + AGENT_WINDOW;
        uint8 all = 0x3f;
        jobs[0] = Job(1500, 0, 1, 0, 0, all);                 // street part-time
        jobs[1] = Job(1500, 200, 1, 86, 61, (1 << 0) | (1 << 5)); // dojo guard: Ronin, Guardian
        jobs[2] = Job(1500, 200, 1, 86, 61, 1 << 1);          // on-chain hack: Hacker
        jobs[3] = Job(1500, 200, 1, 86, 61, (1 << 2) | (1 << 4)); // night-market fortune: Warlock, Astrologer
        jobs[4] = Job(1500, 200, 1, 86, 61, 1 << 3);          // rooftop recon: Scout
        jobs[5] = Job(2200, 300, 10, 95, 0, all);             // high commission
    }

    // ================= admin =================
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function setHuntPerUsd(uint256 v) external onlyOwner { require(v > 0); huntPerUsd = v; }
    function setAddresses(address t, address p) external onlyOwner { require(t != address(0) && p != address(0)); treasury = t; seasonPool = p; }
    function setCaps(uint256 dMint, uint256 wMint, uint256 dEmit, uint256 maxPool) external onlyOwner {
        dailyMintCap = dMint; walletDailyCap = wMint; dailyEmissionCap = dEmit; maxPoolBalance = maxPool;
    }
    function openAgentClaim(bytes32 root) external onlyOwner { agentRoot = root; if (agentClaimStart == 0) agentClaimStart = block.timestamp; }
    function setGenesisTerms(uint256 lock, uint256 end) external onlyOwner { genesisLock = lock; genesisClaimEnd = end; }
    function mintOfficial() external onlyOwner { hero.mintOfficial(owner()); }
    /// @notice fund work rewards; pool balance is capped.
    function fundRewards(uint256 amt) external onlyOwner {
        IERC20(hunt).safeTransferFrom(msg.sender, address(this), amt);
        if (hunt.balanceOf(address(this)) > maxPoolBalance) revert Cap();
    }
    function withdrawRewards(uint256 amt) external onlyOwner { IERC20(hunt).safeTransfer(owner(), amt); }

    // ================= views =================
    function today() public view returns (uint256) { return block.timestamp / 1 days; }
    function mintPriceHunt() public view returns (uint256) {
        return (block.timestamp < launchTime + GENESIS_DAYS ? GENESIS_PRICE_USD : PRICE_USD) * huntPerUsd;
    }
    function mainSub(uint8 c) public pure returns (uint8 m, uint8 s) {
        // attrs idx: 0 STR 1 AGI 2 INT 3 SPI 4 CON
        if (c == 0) return (0, 4); if (c == 1) return (2, 1); if (c == 2) return (3, 2);
        if (c == 3) return (1, 0); if (c == 4) return (3, 4); return (4, 0);
    }
    function energyCap(uint8 lv) public pure returns (uint8) { return uint8(8 + 2 * (uint256(lv) - 1)); }
    function currentEnergy(Hero.HeroData memory h) public view returns (uint8) {
        uint256 e = h.energy + (block.timestamp - h.energyUpdatedAt) / 2 hours;
        uint256 cap = energyCap(h.level);
        return uint8(e > cap ? cap : e);
    }

    // ================= minting =================
    function mint(uint256 qty) external nonReentrant whenNotPaused {
        if (qty == 0 || qty > MAX_PER_TX) revert Bad();
        uint256 d = today();
        if ((mintedOnDay[d] += qty) > dailyMintCap) revert Cap();
        if ((walletMintedOnDay[msg.sender][d] += qty) > walletDailyCap) revert Cap();
        uint256 cost = mintPriceHunt() * qty;
        IERC20 t = IERC20(hunt);
        if (block.timestamp < launchTime + GENESIS_DAYS) {
            t.safeTransferFrom(msg.sender, treasury, cost);
        } else {
            uint256 toT = cost * 40 / 100; uint256 toP = cost * 30 / 100;
            t.safeTransferFrom(msg.sender, treasury, toT);
            t.safeTransferFrom(msg.sender, seasonPool, toP);
            t.safeTransferFrom(msg.sender, address(this), cost - toT - toP);
            hunt.burn(cost - toT - toP);
        }
        for (uint256 i; i < qty; i++) _mintRandom(msg.sender, 0, 0);
    }

    /// @param agentId hashed Binance Agent ID; leaf = keccak256(bytes.concat(keccak256(abi.encode(account, agentId))))
    function claimAgentFree(bytes32 agentId, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        if (agentClaimStart == 0 || block.timestamp > agentClaimStart + AGENT_WINDOW) revert Bad();
        if (agentIdClaimed[agentId] || walletClaimedAgent[msg.sender]) revert Cap();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, agentId))));
        if (!MerkleProof.verifyCalldata(proof, agentRoot, leaf)) revert Bad();
        agentIdClaimed[agentId] = true; walletClaimedAgent[msg.sender] = true;
        _mintRandom(msg.sender, uint64(block.timestamp + FREE_LOCK), 1);
    }

    function claimGenesisFree(uint256 cardId, uint256 qty) external nonReentrant whenNotPaused {
        if (qty == 0 || qty > 5) revert Bad();
        if (genesisClaimEnd != 0 && block.timestamp > genesisClaimEnd) revert Bad();
        if (agentCity.ownerOf(cardId) != msg.sender) revert NotOwner();
        if ((genesisUsed[cardId] += qty) > GENESIS_FREE_PER_CARD) revert Cap();
        uint64 lock = genesisLock == 0 ? 0 : uint64(block.timestamp + genesisLock);
        for (uint256 i; i < qty; i++) _mintRandom(msg.sender, lock, 2);
    }

    function _rand() internal returns (uint256) {
        return uint256(keccak256(abi.encode(blockhash(block.number - 1), block.prevrandao, msg.sender, nonce++)));
    }
    function _roll(uint256 r, uint8 lo, uint8 hi) internal pure returns (uint8) { return uint8(lo + r % (uint256(hi) - lo + 1)); }
    function _ranges(uint8 rar) internal pure returns (uint8 mlo, uint8 mhi, uint8 slo, uint8 shi) {
        if (rar == 0) return (61, 79, 41, 60); if (rar == 1) return (80, 89, 50, 70);
        if (rar == 2) return (90, 96, 61, 80); return (97, 100, 70, 90);
    }
    function _attrs(uint8 c, uint8 rar, uint256 r) internal pure returns (uint8[5] memory a) {
        (uint8 m, uint8 s) = mainSub(c); (uint8 mlo, uint8 mhi, uint8 slo, uint8 shi) = _ranges(rar);
        for (uint8 i; i < 5; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            a[i] = i == m ? _roll(r, mlo, mhi) : i == s ? _roll(r, slo, shi) : _roll(r, 20, 60);
        }
    }
    function _mintRandom(address to, uint64 lock, uint8 src) internal {
        uint256 r = _rand();
        uint256 p = r % 100;
        uint8 rar = p < 60 ? 0 : p < 88 ? 1 : p < 98 ? 2 : 3;
        if (rar >= 2) pityCounter[to] = 0;
        else if (++pityCounter[to] >= PITY) { rar = 2; pityCounter[to] = 0; }
        uint8 c = uint8((r >> 64) % 6);
        Hero.HeroData memory d = Hero.HeroData(rar, c, 1, _attrs(c, rar, r >> 128), false, 0, lock, 0, energyCap(1), uint64(block.timestamp));
        uint256 id = hero.mintHero(to, d);
        emit Minted(to, id, rar, c, src);
    }

    // ================= work / earn =================
    function startWork(uint256 id, uint8 jobId, uint8 hrs) external whenNotPaused {
        if (hero.ownerOf(id) != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil || shifts[id].hours_ != 0) revert Busy();
        if (jobId >= 6 || hrs == 0) revert Bad();
        Job memory j = jobs[jobId];
        (uint8 m, uint8 s) = mainSub(h.class_);
        if ((j.classMask >> h.class_) & 1 == 0 || h.level < j.minLevel || h.attrs[m] < j.minMain || h.attrs[s] < j.minSub) revert Bad();
        if (!h.isOfficial && h.workedHours >= 90 * 24) revert Cap();
        uint8 e = currentEnergy(h);
        if (hrs > e) revert Cap();
        h.energy = e - hrs; h.energyUpdatedAt = uint64(block.timestamp);
        h.busyUntil = uint64(block.timestamp + uint256(hrs) * 1 hours);
        hero.setHero(id, h);
        shifts[id] = Shift(jobId, hrs);
        emit WorkStarted(id, jobId, hrs);
    }

    function pendingReward(uint256 id) public view returns (uint256 v, uint256 paidHours) {
        Shift memory sh = shifts[id]; Hero.HeroData memory h = hero.getHero(id);
        if (sh.hours_ == 0) return (0, 0);
        paidHours = sh.hours_;
        if (!h.isOfficial && h.workedHours + paidHours > 2160) paidHours = 2160 - h.workedHours;
        Job memory j = jobs[sh.job]; (uint8 m,) = mainSub(h.class_);
        uint256 daily = uint256(j.base) + (h.attrs[m] > 85 ? uint256(h.attrs[m] - 85) * j.k : 0);
        v = daily * paidHours * 1e18 / 24;                     // V scaled 1e18
        if (!h.isOfficial) v = v * 720 / (720 + h.workedHours); // decay 1/(1+t/30), t in hours/24
    }

    function claim(uint256 id) external nonReentrant whenNotPaused {
        address o = hero.ownerOf(id);
        if (o != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil) revert Busy();
        (uint256 v, uint256 ph) = pendingReward(id);
        delete shifts[id];
        h.workedHours += uint32(ph); hero.setHero(id, h);
        uint256 amt = v * cWei / 1e18;
        uint256 d = today(); uint256 left = dailyEmissionCap - emittedOnDay[d];
        if (amt > left) amt = left; // dynamic coefficient (simplified: clamp to remaining daily budget)
        uint256 bal = hunt.balanceOf(address(this));
        if (amt > bal) amt = bal;
        emittedOnDay[d] += amt;
        address to = h.isOfficial ? treasury : o; // OFFICIAL #000 output = official revenue
        if (amt > 0) IERC20(hunt).safeTransfer(to, amt);
        emit Claimed(id, to, amt);
    }

    // ================= sinks =================
    function refillEnergy(uint256 id, uint8 pts) external nonReentrant whenNotPaused {
        if (hero.ownerOf(id) != msg.sender) revert NotOwner();
        uint256 d = today();
        if ((refillsOnDay[id][d] += pts) > 12 || pts == 0) revert Cap();
        Hero.HeroData memory h = hero.getHero(id);
        uint8 e = currentEnergy(h);
        if (uint256(e) + pts > energyCap(h.level)) revert Cap();
        h.energy = e + pts; h.energyUpdatedAt = uint64(block.timestamp); hero.setHero(id, h);
        uint256 cost = uint256(pts) * 60 * cWei;
        IERC20(hunt).safeTransferFrom(msg.sender, address(this), cost); hunt.burn(cost); // 100% burn
    }

    function _payBurn80(uint256 cost) internal {
        uint256 toT = cost * 20 / 100;
        IERC20(hunt).safeTransferFrom(msg.sender, treasury, toT);
        IERC20(hunt).safeTransferFrom(msg.sender, address(this), cost - toT); hunt.burn(cost - toT);
    }

    function upgrade(uint256 id) external nonReentrant whenNotPaused {
        if (hero.ownerOf(id) != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil || shifts[id].hours_ != 0) revert Busy();
        if (h.level >= 20) revert Cap();
        uint256 cost = 5000 * uint256(h.level) * cWei;
        _payBurn80(cost);
        uint8 L = h.level + 1; h.level = L;
        (uint8 m, uint8 s) = mainSub(h.class_);
        h.attrs[m] = _inc(h.attrs[m]);
        if (L >= 6 && L <= 10 && L % 2 == 0) h.attrs[s] = _inc(h.attrs[s]);
        if (L >= 11 && L % 3 == 0) for (uint8 i; i < 5; i++) if (i != m && i != s) h.attrs[i] = _inc(h.attrs[i]);
        hero.setHero(id, h);
        emit Upgraded(id, L, cost);
    }
    function _inc(uint8 a) internal pure returns (uint8) { return a >= 100 ? 100 : a + 1; }

    function merge(uint256 a, uint256 b) external nonReentrant whenNotPaused {
        if (a == b || hero.ownerOf(a) != msg.sender || hero.ownerOf(b) != msg.sender) revert NotOwner();
        Hero.HeroData memory x = hero.getHero(a); Hero.HeroData memory y = hero.getHero(b);
        if (block.timestamp < x.busyUntil || block.timestamp < y.busyUntil || shifts[a].hours_ != 0 || shifts[b].hours_ != 0) revert Busy();
        if (x.isOfficial || y.isOfficial || x.class_ != y.class_ || x.rarity != y.rarity || x.rarity > 2) revert Bad();
        uint8 rar = x.rarity;
        uint256 fee = (rar == 0 ? 7500 : rar == 1 ? 20000 : 50000) * cWei;
        _payBurn80(fee);
        (uint8 m,) = mainSub(x.class_);
        uint8 bestMain = x.attrs[m] > y.attrs[m] ? x.attrs[m] : y.attrs[m];
        uint256 r = _rand();
        bool ok = r % 100 < (rar == 0 ? 40 : rar == 1 ? 25 : 10);
        Hero.HeroData memory n;
        n.class_ = x.class_; n.level = x.level < y.level ? x.level : y.level;
        n.tradeLockUntil = x.tradeLockUntil > y.tradeLockUntil ? x.tradeLockUntil : y.tradeLockUntil;
        if (ok) {
            n.rarity = rar + 1; n.attrs = _attrs(n.class_, n.rarity, r >> 8);
            if (n.attrs[m] < bestMain) n.attrs[m] = bestMain;
        } else {
            n.rarity = rar; n.attrs = x.attrs[m] >= y.attrs[m] ? x.attrs : y.attrs;
            uint8 bonus = rar == 0 ? 3 : 2;
            n.attrs[m] = n.attrs[m] + bonus > 100 ? 100 : n.attrs[m] + bonus;
        }
        n.energy = energyCap(n.level); n.energyUpdatedAt = uint64(block.timestamp);
        hero.burn(a); hero.burn(b);
        uint256 id = hero.mintHero(msg.sender, n);
        emit Merged(a, b, id, ok);
    }
}
