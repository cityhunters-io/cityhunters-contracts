// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Hero} from "../Hero.sol";
import {GameMainnet} from "./GameMainnet.sol";
import {BattleMainnet} from "./BattleMainnet.sol";

/// @title Holds OFFICIAL #000 (MAINNET CANDIDATE). Publicly disclosed 2x work income:
/// Game.claim pays #000's normal output to treasury; this contract adds exactly 1x more (total 2x) from its pool.
/// Battle 2x is applied inside BattleMainnet; winnings are forwarded to treasury. Multiplier is a constant.
contract OfficialAgentMainnet is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero; GameMainnet public immutable game; BattleMainnet public battle;
    uint256 public constant ID = 0;
    uint256 public constant MULT = 2;
    event WorkBoosted(uint256 base, uint256 bonus, address to);
    event BattleForwarded(uint256 amount, address to);

    constructor(address owner_, IERC20 h, Hero hr, GameMainnet g, BattleMainnet b) Ownable(owner_) { hunt = h; hero = hr; game = g; battle = b; }
    function setBattle(BattleMainnet b) external onlyOwner { battle = b; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }

    function work(uint8 job, uint8 hrs) external onlyOwner { game.startWork(ID, job, hrs); }
    function claimWork() external onlyOwner nonReentrant returns (uint256 base, uint256 bonus) {
        address t = game.treasury(); uint256 b0 = hunt.balanceOf(t);
        game.claim(ID);
        base = hunt.balanceOf(t) - b0;
        bonus = base * (MULT - 1);
        uint256 bal = hunt.balanceOf(address(this));
        if (bonus > bal) bonus = bal;
        if (bonus > 0) hunt.safeTransfer(t, bonus);
        emit WorkBoosted(base, bonus, t);
    }
    /// @notice early clock-out for #000; same public 2x as claimWork.
    function stopWork() external onlyOwner nonReentrant returns (uint256 base, uint256 bonus) {
        address t = game.treasury(); uint256 b0 = hunt.balanceOf(t);
        game.stopWork(ID);
        base = hunt.balanceOf(t) - b0; bonus = base * (MULT - 1);
        uint256 bal = hunt.balanceOf(address(this)); if (bonus > bal) bonus = bal;
        if (bonus > 0) hunt.safeTransfer(t, bonus);
        emit WorkBoosted(base, bonus, t);
    }
    function fight(uint8 tier) external onlyOwner nonReentrant returns (bool win) {
        uint256 b0 = hunt.balanceOf(address(this));
        win = battle.fight(ID, tier);
        uint256 got = hunt.balanceOf(address(this)) - b0;
        if (got > 0) { address t = game.treasury(); hunt.safeTransfer(t, got); emit BattleForwarded(got, t); }
    }
    function withdraw(uint256 a) external onlyOwner { hunt.safeTransfer(owner(), a); }
    function release() external onlyOwner { hero.safeTransferFrom(address(this), owner(), ID); }
}
