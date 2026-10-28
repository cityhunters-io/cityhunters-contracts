// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {HuntToken} from "../HuntToken.sol";
import {Hero} from "../Hero.sol";
import {GenesisDraw} from "./GenesisDraw.sol";
struct VRFRequest { bytes32 keyHash; uint256 subId; uint16 requestConfirmations; uint32 callbackGasLimit; uint32 numWords; bytes extraArgs; }
interface IVRFCoordinatorV2Plus { function requestRandomWords(VRFRequest calldata req) external returns (uint256); }
interface AggregatorV3Interface { function decimals() external view returns (uint8); function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80); }

/// @title CITY HUNTERS Game v1 (phase 1: HUNT only). All numbers are design-doc example values.
/// Mint & merge randomness: Chainlink VRF v2.5 (native-paid subscription). Heroes are minted / merges resolved in the VRF callback.
/// Without a coordinator (local tests only, never chain 56) it falls back to blockhash/prevrandao.
/// Price is an owner-set HUNT/USD rate -> replace with TWAP/oracle (30-min TWAP, 5% deviation pause) later.
/// Phase 2 (BOUNTY) will be a new Game contract; Hero.setGame is one-shot so a migration path must be added then.
/// MAINNET CANDIDATE: adds trusted minters (Referral/Whitelist) + mintFree; OFFICIAL #000 follows normal work decay/90-day cap.
contract GameMainnet is Ownable, Pausable, ReentrancyGuard {
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
    uint256 public genesisDuration = GENESIS_DAYS; // always 3 days on BSC mainnet; shortenable ONLY on testnets for rehearsals
    GenesisDraw public genesisDraw;                // receives 15% of genesis-window paid-mint revenue (prize escrow)
    uint256 public constant DRAW_BPS = 1500;
    AggregatorV3Interface public priceFeed;        // Chainlink BNB/USD (BSC mainnet 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE)
    uint256 public maxPriceAge = 1 hours;
    event PaidBnb(address indexed to, uint256 qty, uint256 costWei, uint256 toDrawWei);
    error Stale(); error Underpaid();
    uint256 public constant GENESIS_PRICE_USD = 10;
    uint256 public constant PRICE_USD = 20;
    uint256 public constant MAX_PER_TX = 2;
    uint256 public dailyMintCap = 300;
    uint256 public walletDailyCap = 10;
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
    // ---- sale gate ----
    uint256 public saleStart;            // no mint of any kind before this (mainnet: 2026-10-28 12:00 UTC)
    error NotStarted();
    event SaleStartSet(uint256 t);
    // ---- Chainlink VRF v2.5 ----
    IVRFCoordinatorV2Plus public vrfCoordinator; bytes32 public vrfKeyHash; uint256 public vrfSubId;
    uint16 public vrfConfirmations = 3; uint32 public vrfCallbackGas = 900_000;
    struct Pending { address to; uint8 kind; uint8 qty; uint8 src; uint64 lock; uint64 at; uint256 a; uint256 b; uint256 word; }
    mapping(uint256 => Pending) public pending;   // requestId => job (kind 1 mint, 2 merge)
    event RandomRequested(uint256 indexed reqId, address indexed to, uint8 kind, uint8 qty);
    event RandomSettleFailed(uint256 indexed reqId);
    mapping(address => bool) public minters; // Referral / WhitelistMint (enforce their own per-wallet limits)
    event MinterSet(address m, bool on);

    struct Job { uint16 base; uint16 k; uint8 minLevel; uint8 minMain; uint8 minSub; uint8 classMask; }
    Job[6] public jobs;
    struct Shift { uint8 job; uint8 hours_; uint64 startedAt; }
    mapping(uint256 => Shift) public shifts;

    event Minted(address indexed to, uint256 indexed id, uint8 rarity, uint8 class_, uint8 source); // 0 paid 1 agent 2 genesis 3 referral 4 whitelist
    event WorkStarted(uint256 indexed id, uint8 job, uint8 hours_);
    event Claimed(uint256 indexed id, address indexed to, uint256 hunt);
    event WorkStopped(uint256 indexed id, uint256 paidHours, uint256 amount);
    event Upgraded(uint256 indexed id, uint8 level, uint256 cost);
    event Merged(uint256 a, uint256 b, uint256 newId, bool success);

    error Cap(); error NotOwner(); error Busy(); error Bad();

    constructor(address owner_, HuntToken h, Hero hr, IERC721 city, address treasury_, address pool_, uint256 huntPerUsd_) Ownable(owner_) {
        hunt = h; hero = hr; agentCity = city; treasury = treasury_; seasonPool = pool_; huntPerUsd = huntPerUsd_;
        launchTime = block.timestamp; saleStart = block.timestamp;
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
    /// @notice set the public sale start (genesis = saleStart .. +3 days). Mainnet: only before the first hero is minted and only in the future.
    function setSaleStart(uint256 t) external onlyOwner {
        if (block.chainid == 56) require(hero.nextId() == 1 && t >= block.timestamp, "locked");
        saleStart = t; launchTime = t; genesisClaimEnd = t + AGENT_WINDOW; emit SaleStartSet(t);
    }
    modifier afterSale() { if (block.timestamp < saleStart) revert NotStarted(); _; }
    function setVrf(IVRFCoordinatorV2Plus c, bytes32 kh, uint256 sub, uint16 conf, uint32 cbGas) external onlyOwner {
        require(address(c) != address(0) && conf >= 1 && cbGas >= 300_000); vrfCoordinator = c; vrfKeyHash = kh; vrfSubId = sub; vrfConfirmations = conf; vrfCallbackGas = cbGas;
    }
    function setMinter(address m, bool on) external onlyOwner { minters[m] = on; emit MinterSet(m, on); }
    function genesisEnd() public view returns (uint256) { return launchTime + genesisDuration; }
    /// @notice one-shot: attach the Genesis lucky-draw escrow (must be set before any paid mint to be fair).
    function setGenesisDraw(GenesisDraw d) external onlyOwner { require(address(genesisDraw) == address(0) && address(d) != address(0)); genesisDraw = d; }
    /// @notice TESTNET REHEARSAL ONLY: shorten the genesis window. Reverts on BSC mainnet (chainid 56).
    function setGenesisDurationTestnet(uint256 secs) external onlyOwner { require(block.chainid != 56, "mainnet"); genesisDuration = secs; }
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
        return (block.timestamp < genesisEnd() ? GENESIS_PRICE_USD : PRICE_USD) * huntPerUsd;
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
    function mint(uint256 qty) external nonReentrant whenNotPaused afterSale { _paidMint(msg.sender, msg.sender, qty); }
    /// @notice trusted minter (Referral) pays for a paid mint on behalf of real player `to`:
    /// wallet cap and the 30-mint pity counter are tracked per player, heroes are minted straight to the player.
    function mintFor(address to, uint256 qty) external nonReentrant whenNotPaused afterSale {
        if (!minters[msg.sender]) revert NotOwner();
        if (to == address(0)) revert Bad();
        _paidMint(msg.sender, to, qty);
    }
    function _caps(address to, uint256 qty) internal {
        if (qty == 0 || qty > MAX_PER_TX) revert Bad();
        uint256 d = today();
        if ((mintedOnDay[d] += qty) > dailyMintCap) revert Cap();
        if ((walletMintedOnDay[to][d] += qty) > walletDailyCap) revert Cap();
    }
    /// @dev HUNT paid mint: ONLY after the genesis window (no HUNT liquidity exists during genesis).
    function _paidMint(address payer, address to, uint256 qty) internal {
        if (block.timestamp < genesisEnd()) revert Bad(); // genesis: pay in BNB via mintBnb
        _caps(to, qty);
        uint256 cost = mintPriceHunt() * qty;
        IERC20 t = IERC20(hunt);
        {
            uint256 toT = cost * 40 / 100; uint256 toP = cost * 30 / 100;
            t.safeTransferFrom(payer, treasury, toT);
            t.safeTransferFrom(payer, seasonPool, toP);
            t.safeTransferFrom(payer, address(this), cost - toT - toP);
            hunt.burn(cost - toT - toP);
        }
        _mintN(to, 0, 0, qty);
    }

    // ================= genesis BNB minting =================
    /// @notice Chainlink BNB/USD price, with staleness + sanity checks. Returns USD per BNB scaled 1e18.
    function bnbUsd() public view returns (uint256) {
        if (address(priceFeed) == address(0)) revert Bad();
        (uint80 rid, int256 a, , uint256 upd, uint80 ans) = priceFeed.latestRoundData();
        if (a <= 0 || upd == 0 || ans < rid || block.timestamp - upd > maxPriceAge) revert Stale();
        return uint256(a) * 1e18 / (10 ** priceFeed.decimals());
    }
    /// @notice BNB price per hero via Chainlink BNB/USD: 10 USD during Genesis (50% off launch price), 20 USD automatically after. Excess is refunded.
    function priceUsd() public view returns (uint256) { return block.timestamp < genesisEnd() ? GENESIS_PRICE_USD : PRICE_USD; }
    function mintPriceBnb() public view returns (uint256) { uint256 p = bnbUsd(); return (priceUsd() * 1e36 + p - 1) / p; }
    function mintBnb(uint256 qty) external payable nonReentrant whenNotPaused afterSale { _paidMintBnb(msg.sender, qty); }
    /// @notice trusted minter (Referral) forwards the player's BNB; refund goes straight back to the player.
    function mintForBnb(address to, uint256 qty) external payable nonReentrant whenNotPaused afterSale {
        if (!minters[msg.sender]) revert NotOwner();
        if (to == address(0)) revert Bad();
        _paidMintBnb(to, qty);
    }
    function _paidMintBnb(address to, uint256 qty) internal {
        _caps(to, qty); // BNB mint open during and after Genesis (price switches 10 -> 20 USD at genesisEnd)
        uint256 cost = mintPriceBnb() * qty;
        if (msg.value < cost) revert Underpaid();
        uint256 toD = address(genesisDraw) == address(0) || block.timestamp >= genesisEnd() ? 0 : cost * DRAW_BPS / 10_000; // 15% draw escrow only during Genesis
        _mintN(to, 0, 0, qty);
        if (toD > 0) genesisDraw.notePaidBnb{value: toD}(to, qty);
        _sendBnb(treasury, cost - toD);
        if (msg.value > cost) _sendBnb(to, msg.value - cost);
        emit PaidBnb(to, qty, cost, toD);
    }
    function _sendBnb(address a, uint256 v) internal { (bool ok,) = payable(a).call{value: v}(""); if (!ok) revert Bad(); }
    function setPriceFeed(AggregatorV3Interface f, uint256 maxAge) external onlyOwner { require(address(f) != address(0) && maxAge >= 60 && maxAge <= 2 days); priceFeed = f; maxPriceAge = maxAge; }

    /// @param agentId hashed Binance Agent ID; leaf = keccak256(bytes.concat(keccak256(abi.encode(account, agentId))))
    function claimAgentFree(bytes32 agentId, bytes32[] calldata proof) external nonReentrant whenNotPaused afterSale {
        if (agentClaimStart == 0 || block.timestamp > agentClaimStart + AGENT_WINDOW) revert Bad();
        if (agentIdClaimed[agentId] || walletClaimedAgent[msg.sender]) revert Cap();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, agentId))));
        if (!MerkleProof.verifyCalldata(proof, agentRoot, leaf)) revert Bad();
        agentIdClaimed[agentId] = true; walletClaimedAgent[msg.sender] = true;
        _mintN(msg.sender, uint64(block.timestamp + FREE_LOCK), 1, 1);
    }

    /// @notice free mint by a trusted minter (src 3 = referral reward, 4 = whitelist). 7-day trade lock. Counts toward dailyMintCap.
    function mintFree(address to, uint8 src) external nonReentrant whenNotPaused afterSale returns (uint256 id) {
        if (!minters[msg.sender]) revert NotOwner();
        if ((mintedOnDay[today()] += 1) > dailyMintCap) revert Cap();
        id = address(vrfCoordinator) == address(0) ? hero.nextId() : 0; // VRF: id assigned in the callback (see Minted event)
        _mintN(to, uint64(block.timestamp + FREE_LOCK), src, 1);
    }

    function claimGenesisFree(uint256 cardId, uint256 qty) external nonReentrant whenNotPaused afterSale {
        if (qty == 0 || qty > 5) revert Bad();
        if (genesisClaimEnd != 0 && block.timestamp > genesisClaimEnd) revert Bad();
        if (agentCity.ownerOf(cardId) != msg.sender) revert NotOwner();
        if ((genesisUsed[cardId] += qty) > GENESIS_FREE_PER_CARD) revert Cap();
        uint64 lock = genesisLock == 0 ? 0 : uint64(block.timestamp + genesisLock);
        _mintN(msg.sender, lock, 2, qty);
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
    // ================= randomness (Chainlink VRF v2.5) =================
    function _request(Pending memory p) internal returns (uint256 id) {
        id = vrfCoordinator.requestRandomWords(VRFRequest(vrfKeyHash, vrfSubId, vrfConfirmations, vrfCallbackGas, 1,
            abi.encodeWithSelector(bytes4(0x92fd1338), true))); // VRFV2PlusClient.EXTRA_ARGS_V1_TAG, ExtraArgsV1{nativePayment:true}
        p.at = uint64(block.timestamp); pending[id] = p; emit RandomRequested(id, p.to, p.kind, p.qty);
    }
    function _mintN(address to, uint64 lock, uint8 src, uint256 qty) internal {
        if (address(vrfCoordinator) == address(0)) { require(block.chainid != 56, "vrf"); for (uint256 i; i < qty; i++) _mintRandom(to, lock, src, _rand()); return; }
        _request(Pending(to, 1, uint8(qty), src, lock, 0, 0, 0, 0));
    }
    /// @notice VRF callback: store the word, then settle in a guarded self-call so a failing settle never loses the randomness.
    function rawFulfillRandomWords(uint256 reqId, uint256[] calldata words) external {
        require(msg.sender == address(vrfCoordinator), "only coordinator");
        Pending storage p = pending[reqId]; if (p.kind == 0 || p.word != 0) return;
        p.word = words[0] | 1; // never zero
        try this.settleSelf(reqId) {} catch { emit RandomSettleFailed(reqId); }
    }
    function settleSelf(uint256 reqId) external { require(msg.sender == address(this)); _settle(reqId); }
    /// @notice anyone can retry settling a request whose randomness already arrived.
    function settle(uint256 reqId) external nonReentrant { _settle(reqId); }
    function _settle(uint256 reqId) internal {
        Pending memory p = pending[reqId]; if (p.kind == 0 || p.word == 0) revert Bad();
        delete pending[reqId];
        if (p.kind == 1) { for (uint256 i; i < p.qty; i++) _mintRandom(p.to, p.lock, p.src, uint256(keccak256(abi.encode(p.word, i)))); }
        else _mergeResolve(p.to, p.a, p.b, uint256(keccak256(abi.encode(p.word, "merge"))));
    }
    /// @notice owner re-requests randomness for a job stuck > 1h without a VRF answer (same job, new request id).
    function rerequest(uint256 reqId) external onlyOwner {
        Pending memory p = pending[reqId]; if (p.kind == 0 || p.word != 0 || block.timestamp < p.at + 1 hours) revert Bad();
        delete pending[reqId]; _request(p);
    }
    function _mintRandom(address to, uint64 lock, uint8 src, uint256 r) internal {
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
        if (h.workedHours >= 90 * 24) revert Cap();
        uint8 e = currentEnergy(h);
        if (hrs > e) revert Cap();
        h.energy = e - hrs; h.energyUpdatedAt = uint64(block.timestamp);
        h.busyUntil = uint64(block.timestamp + uint256(hrs) * 1 hours);
        hero.setHero(id, h);
        shifts[id] = Shift(jobId, hrs, uint64(block.timestamp));
        emit WorkStarted(id, jobId, hrs);
    }

    function pendingReward(uint256 id) public view returns (uint256 v, uint256 paidHours) {
        Shift memory sh = shifts[id]; return _reward(sh, hero.getHero(id), sh.hours_);
    }
    /// @notice preview of an early clock-out now: fully completed hours paid, fully unstarted hours' energy refunded.
    function stopPreview(uint256 id) public view returns (uint256 v, uint256 paidHours, uint256 refund) {
        Shift memory sh = shifts[id]; if (sh.hours_ == 0) return (0, 0, 0);
        uint256 el = block.timestamp - sh.startedAt;
        uint256 done = el / 1 hours; if (done > sh.hours_) done = sh.hours_;
        uint256 started = (el + 1 hours - 1) / 1 hours; if (started > sh.hours_) started = sh.hours_;
        refund = sh.hours_ - started;
        (v, paidHours) = _reward(sh, hero.getHero(id), done);
    }
    function _reward(Shift memory sh, Hero.HeroData memory h, uint256 hrs) internal view returns (uint256 v, uint256 paidHours) {
        if (sh.hours_ == 0) return (0, 0);
        paidHours = hrs;
        if (h.workedHours + paidHours > 2160) paidHours = 2160 - h.workedHours;
        Job memory j = jobs[sh.job]; (uint8 m,) = mainSub(h.class_);
        uint256 daily = uint256(j.base) + (h.attrs[m] > 85 ? uint256(h.attrs[m] - 85) * j.k : 0);
        v = daily * paidHours * 1e18 / 24;                     // V scaled 1e18
        v = v * 720 / (720 + h.workedHours); // decay 1/(1+t/30), t in hours/24
    }

    function claim(uint256 id) external nonReentrant whenNotPaused {
        address o = hero.ownerOf(id);
        if (o != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (block.timestamp < h.busyUntil) revert Busy();
        (uint256 v, uint256 ph) = pendingReward(id);
        delete shifts[id];
        h.workedHours += uint32(ph); hero.setHero(id, h);
        uint256 amt = _pay(id, h, o, v);
        emit Claimed(id, h.isOfficial ? treasury : o, amt);
    }

    /// @notice Early clock-out. Pays only FULLY completed hours (same formula/decay/clamps as claim);
    /// energy is refunded only for hours that never started: refund = hours - ceil(elapsed / 1h).
    /// The partial hour in progress is neither paid nor refunded, so start/stop can never beat finishing a shift.
    function stopWork(uint256 id) external nonReentrant whenNotPaused {
        address o = hero.ownerOf(id);
        if (o != msg.sender) revert NotOwner();
        Hero.HeroData memory h = hero.getHero(id);
        if (shifts[id].hours_ == 0 || block.timestamp >= h.busyUntil) revert Bad(); // no active shift (finished shifts use claim)
        (uint256 v, uint256 ph, uint256 refund) = stopPreview(id);
        delete shifts[id];
        uint8 e = currentEnergy(h); uint256 cap = energyCap(h.level);
        h.energy = uint8(e + refund > cap ? cap : e + refund); h.energyUpdatedAt = uint64(block.timestamp);
        h.workedHours += uint32(ph); h.busyUntil = uint64(block.timestamp); hero.setHero(id, h);
        uint256 amt = _pay(id, h, o, v);
        emit WorkStopped(id, ph, amt);
    }

    function _pay(uint256, Hero.HeroData memory h, address o, uint256 v) internal returns (uint256 amt) {
        amt = v * cWei / 1e18;
        uint256 d = today(); uint256 left = dailyEmissionCap - emittedOnDay[d];
        if (amt > left) amt = left; // dynamic coefficient (simplified: clamp to remaining daily budget)
        uint256 bal = hunt.balanceOf(address(this));
        if (amt > bal) amt = bal;
        emittedOnDay[d] += amt;
        address to = h.isOfficial ? treasury : o; // OFFICIAL #000 output = official revenue
        if (amt > 0) IERC20(hunt).safeTransfer(to, amt);
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
        if (address(vrfCoordinator) == address(0)) { require(block.chainid != 56, "vrf"); _mergeResolve(msg.sender, a, b, _rand()); return; }
        // lock both heroes (no transfer / work / fight / merge) until the VRF callback resolves the merge
        x.busyUntil = type(uint64).max; y.busyUntil = type(uint64).max; hero.setHero(a, x); hero.setHero(b, y);
        _request(Pending(msg.sender, 2, 2, 0, 0, 0, a, b, 0));
    }
    function _mergeResolve(address to, uint256 a, uint256 b, uint256 r) internal {
        Hero.HeroData memory x = hero.getHero(a); Hero.HeroData memory y = hero.getHero(b);
        uint8 rar = x.rarity;
        (uint8 m,) = mainSub(x.class_);
        uint8 bestMain = x.attrs[m] > y.attrs[m] ? x.attrs[m] : y.attrs[m];
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
        uint256 id = hero.mintHero(to, n);
        emit Merged(a, b, id, ok);
    }
}
