// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Hero} from "../Hero.sol";
import {GameMainnet} from "./GameMainnet.sol";
import {GenesisDraw} from "./GenesisDraw.sol";

/// @title Referral minting (MAINNET CANDIDATE) with self-referral (two-wallet) mitigation.
/// Design:
///  1. Referrer must have made >=1 paid mint through this contract (free/whitelist heroes don't count).
///  2. A referee is bound to the first referrer forever (no rotating referrers).
///  3. Each PAID hero minted by a referee = 1 point; POINTS_PER_CREDIT (2) points = 1 free-mint credit.
///     Credit is granted only after the referee's paid mint succeeds in the same tx.
///  4. A referrer can earn at most maxCreditsPerDay (default 5) credits per UTC day; excess points are dropped.
///  5. Redeemed heroes are minted via Game.mintFree with a 7-day trade lock.
/// Worst-case self-abuse: 3 heroes for the price of 2 (~33% off), capped at 5 free heroes/day.
contract ReferralMainnet is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero; GameMainnet public immutable game;
    uint256 public constant POINTS_PER_CREDIT = 2;
    uint256 public maxCreditsPerDay = 5;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public points;
    mapping(address => uint256) public paidMints;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public totalReferred;
    mapping(address => mapping(uint256 => uint256)) public creditsOnDay;
    mapping(address => bool) public refereeCounted;     // referee already counted as a successful referral
    mapping(address => uint256) public successfulReferrals; // distinct bound friends who paid-minted
    event SuccessfulReferral(address indexed referrer, address indexed referee);
    error Bad(); error Cap(); error NoCredit();
    event ReferredMint(address indexed minter, address indexed referrer, uint256 qty, uint256 firstId, uint256 creditsEarned);
    event Redeemed(address indexed referrer, uint256 heroId);

    constructor(address owner_, IERC20 h, Hero hr, GameMainnet g) Ownable(owner_) { hunt = h; hero = hr; game = g; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setMaxCreditsPerDay(uint256 c) external onlyOwner { maxCreditsPerDay = c; }

    function eligible(address ref) public view returns (bool) { return paidMints[ref] > 0; }

    /// @notice paid mint; pulls price*qty HUNT from caller. ref = address(0) for none.
    /// @notice genesis window: send BNB (game.mintPriceBnb() * qty, small extra is refunded to you). After genesis: send BNB ($20) or msg.value 0 to pay in HUNT.
    function mint(uint256 qty, address ref) external payable nonReentrant returns (uint256 first) {
        if (ref == msg.sender) revert Bad();
        uint256 d = block.timestamp / 1 days;
        first = hero.nextId();
        if (block.timestamp < game.genesisEnd() || msg.value != 0) {
            game.mintForBnb{value: msg.value}(msg.sender, qty); // BNB: $10 Genesis / $20 after; refund goes to the player
        } else {
            uint256 cost = game.mintPriceHunt() * qty;
            hunt.safeTransferFrom(msg.sender, address(this), cost);
            hunt.forceApprove(address(game), cost);
            game.mintFor(msg.sender, qty); // per-player wallet cap (shared with direct mint) + per-player pity; minted to player
        }
        paidMints[msg.sender] += qty;

        uint256 earned;
        address bound = referrerOf[msg.sender];
        if (bound == address(0) && ref != address(0) && eligible(ref) && referrerOf[ref] != msg.sender) { referrerOf[msg.sender] = ref; bound = ref; }
        if (bound != address(0)) {
            if (!refereeCounted[msg.sender]) {
                refereeCounted[msg.sender] = true; successfulReferrals[bound] += 1; emit SuccessfulReferral(bound, msg.sender);
                GenesisDraw gd = game.genesisDraw(); if (address(gd) != address(0)) gd.noteReferral(bound);
            }
            totalReferred[bound] += qty;
            uint256 p = points[bound] + qty;
            earned = p / POINTS_PER_CREDIT; points[bound] = p % POINTS_PER_CREDIT;
            uint256 room = maxCreditsPerDay > creditsOnDay[bound][d] ? maxCreditsPerDay - creditsOnDay[bound][d] : 0;
            if (earned > room) { earned = room; if (room == 0) points[bound] = 0; }
            if (earned > 0) { credits[bound] += earned; creditsOnDay[bound][d] += earned; }
        }
        emit ReferredMint(msg.sender, bound, qty, first, earned);
    }

    function redeem() external nonReentrant returns (uint256 id) {
        if (credits[msg.sender] == 0) revert NoCredit();
        credits[msg.sender] -= 1;
        id = game.mintFree(msg.sender, 3);
        emit Redeemed(msg.sender, id);
    }
}
