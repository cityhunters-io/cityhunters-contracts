// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGameG { function genesisEnd() external view returns (uint256); function treasury() external view returns (address); }

/// @title Genesis lucky draw (MAINNET CANDIDATE).
/// Escrow: 15% of every genesis-window paid mint (paid in BNB) is sent here by Game, held and paid out in BNB. There is NO owner withdraw.
/// Eligibility (only actions inside the genesis window count; the list is published via events + `eligibleAt`):
///   (a) the wallet itself paid-minted >= 10 heroes (direct or through the Referral minter, counted for the real player), or
///   (b) the wallet has >= 10 successful referrals: distinct friends bound to it (ReferralMainnet rules) whose paid mint succeeded.
/// Draw (anyone can call; owner has no special power): after genesis ends,
///   1. commit(): fixes targetBlock = block.number + DELAY (future block, unknown at commit time).
///   2. reveal(): after targetBlock, seed = keccak256(blockhash(targetBlock), eligibleCount, this). Must happen within 256 blocks;
///      if missed, blockhash is gone and anyone may commit() again (a new future block).
///   3 distinct winners by partial Fisher-Yates over the published list; prize = BNB escrow / winners (equal split, dust to last); a winner that cannot receive BNB can claimOwed() later.
///   Fewer than 3 eligible -> split among all of them. None eligible -> whole escrow goes to the project treasury.
/// Limits: a BSC validator producing targetBlock could in theory influence its hash; the owner/caller cannot choose it.
contract GenesisDraw is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; IGameG public immutable game; address public referral;
    uint256 public constant THRESHOLD = 10; uint256 public constant WINNERS = 3; uint256 public constant DELAY = 5;
    mapping(address => uint256) public paidMints;     // genesis-window paid heroes
    mapping(address => uint256) public referrals;     // genesis-window successful referrals
    mapping(address => bool) public isEligible;
    address[] public eligibleAt;
    uint256 public targetBlock; bool public drawn; address[] public winners; uint256 public prizeEach;
    error NotSource(); error Early(); error Done(); error NoCommit(); error Wait();
    event Eligible(address indexed who, uint256 paidMints, uint256 referrals, uint256 index);
    event Committed(uint256 targetBlock); event Drawn(bytes32 seed, address[] winners, uint256 prizeEach, uint256 total);
    event NoWinnersToTreasury(address treasury, uint256 amount);

    constructor(address owner_, IERC20 h, IGameG g) Ownable(owner_) { hunt = h; game = g; }
    function setReferral(address r) external onlyOwner { require(referral == address(0) && r != address(0)); referral = r; }
    function eligibleCount() external view returns (uint256) { return eligibleAt.length; }
    function eligibleList() external view returns (address[] memory) { return eligibleAt; }
    function winnerList() external view returns (address[] memory) { return winners; }
    function escrow() public view returns (uint256) { return address(this).balance - totalOwed; }
    mapping(address => uint256) public owed; uint256 public totalOwed; // pull fallback if a winner cannot receive BNB
    function inGenesis() public view returns (bool) { return block.timestamp < game.genesisEnd(); }

    function notePaidBnb(address who, uint256 qty) external payable {
        if (msg.sender != address(game)) revert NotSource();
        if (!inGenesis()) return;
        paidMints[who] += qty; _check(who);
    }
    function noteReferral(address ref) external {
        if (msg.sender != referral) revert NotSource();
        if (!inGenesis()) return;
        referrals[ref] += 1; _check(ref);
    }
    function _check(address w) internal {
        if (!isEligible[w] && (paidMints[w] >= THRESHOLD || referrals[w] >= THRESHOLD)) {
            isEligible[w] = true; eligibleAt.push(w); emit Eligible(w, paidMints[w], referrals[w], eligibleAt.length - 1);
        }
    }

    function _pay(address to, uint256 v) internal {
        (bool ok,) = payable(to).call{value: v, gas: 50_000}("");
        if (!ok) { owed[to] += v; totalOwed += v; }
    }
    /// @notice winner whose wallet rejected the push payment withdraws here.
    function claimOwed() external nonReentrant {
        uint256 v = owed[msg.sender]; if (v == 0) revert NoCommit(); owed[msg.sender] = 0; totalOwed -= v;
        (bool ok,) = payable(msg.sender).call{value: v}(""); require(ok);
    }
    function commit() external {
        if (inGenesis()) revert Early(); if (drawn) revert Done();
        if (targetBlock != 0 && (block.number <= targetBlock + 256)) revert Wait(); // pending commit still revealable
        targetBlock = block.number + DELAY; emit Committed(targetBlock);
    }
    function reveal() external nonReentrant {
        if (drawn) revert Done(); if (targetBlock == 0) revert NoCommit();
        if (block.number <= targetBlock) revert Wait();
        bytes32 bh = blockhash(targetBlock); if (bh == bytes32(0)) revert NoCommit(); // expired: commit() again
        drawn = true;
        uint256 n = eligibleAt.length; uint256 total = escrow();
        bytes32 seed = keccak256(abi.encode(bh, n, address(this)));
        if (n == 0) { address t = game.treasury(); if (total > 0) _pay(t, total); emit NoWinnersToTreasury(t, total); emit Drawn(seed, winners, 0, total); return; }
        uint256 k = n < WINNERS ? n : WINNERS;
        address[] memory pool = eligibleAt;
        for (uint256 i; i < k; i++) {
            uint256 j = i + uint256(keccak256(abi.encode(seed, i))) % (n - i);
            (pool[i], pool[j]) = (pool[j], pool[i]); winners.push(pool[i]);
        }
        prizeEach = total / k;
        for (uint256 i; i < k; i++) _pay(winners[i], i == k - 1 ? total - prizeEach * (k - 1) : prizeEach);
        emit Drawn(seed, winners, prizeEach, total);
    }
}
