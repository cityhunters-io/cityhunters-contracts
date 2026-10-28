// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Hero} from "./Hero.sol";
import {Game} from "./Game.sol";
import {Battle} from "./Battle.sol";

/// @title Holds OFFICIAL #000 and boosts its work income to `mult`x (TESTNET).
/// Game.claim pays OFFICIAL output to the treasury; this contract measures that exact amount in the same tx
/// and tops it up by (mult-1)x from its own pool. Battle rewards (already 200x in Battle) are forwarded to treasury.
contract OfficialAgent is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero; Game public immutable game; Battle public battle;
    uint256 public constant ID = 0;
    uint256 public mult = 200;
    uint256 public dailyBoostCap = 2_000_000 ether;
    mapping(uint256 => uint256) public boostedOnDay;
    event WorkBoosted(uint256 base, uint256 bonus, address to);
    event BattleForwarded(uint256 amount, address to);

    constructor(address owner_, IERC20 h, Hero hr, Game g, Battle b) Ownable(owner_) { hunt = h; hero = hr; game = g; battle = b; }
    function setParams(uint256 m, uint256 cap, Battle b) external onlyOwner { require(m >= 1); mult = m; dailyBoostCap = cap; battle = b; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }

    function work(uint8 job, uint8 hrs) external onlyOwner { game.startWork(ID, job, hrs); }
    function claimWork() external onlyOwner nonReentrant returns (uint256 base, uint256 bonus) {
        address t = game.treasury(); uint256 b0 = hunt.balanceOf(t);
        game.claim(ID);
        base = hunt.balanceOf(t) - b0;
        bonus = base * (mult - 1);
        uint256 d = block.timestamp / 1 days; uint256 left = dailyBoostCap > boostedOnDay[d] ? dailyBoostCap - boostedOnDay[d] : 0;
        uint256 bal = hunt.balanceOf(address(this));
        if (bonus > left) bonus = left; if (bonus > bal) bonus = bal;
        if (bonus > 0) { boostedOnDay[d] += bonus; hunt.safeTransfer(t, bonus); }
        emit WorkBoosted(base, bonus, t);
    }
    function fight(uint8 tier) external onlyOwner nonReentrant returns (bool win) {
        uint256 b0 = hunt.balanceOf(address(this));
        win = battle.fight(ID, tier);
        uint256 got = hunt.balanceOf(address(this)) - b0;
        if (got > 0) { address t = game.treasury(); hunt.safeTransfer(t, got); emit BattleForwarded(got, t); }
    }
    function withdraw(uint256 a) external onlyOwner { hunt.safeTransfer(owner(), a); }
    /// return #000 to the owner (e.g. when Game gets a native multiplier)
    function release() external onlyOwner { hero.safeTransferFrom(address(this), owner(), ID); }
}
