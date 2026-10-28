// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Hero} from "./Hero.sol";
import {Game} from "./Game.sol";

/// @title Referral minting (TESTNET). Mints through Game.mint and forwards heroes to the minter.
/// Each paid mint tx made with a referrer (not self) gives the referrer 1 free-mint credit,
/// redeemable for 1 hero paid from this contract's HUNT pool.
contract Referral is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    IERC20 public immutable hunt; Hero public immutable hero; Game public immutable game;
    uint256 public walletDailyCap = 10;          // per real wallet (Referral is one wallet to Game)
    mapping(address => uint256) public credits;
    mapping(address => uint256) public totalReferred;
    mapping(address => mapping(uint256 => uint256)) public mintedOnDay;
    error Bad(); error Cap(); error NoCredit();
    event ReferredMint(address indexed minter, address indexed referrer, uint256 qty, uint256 firstId);
    event Redeemed(address indexed referrer, uint256 heroId);

    constructor(address owner_, IERC20 h, Hero hr, Game g) Ownable(owner_) { hunt = h; hero = hr; game = g; }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) { return this.onERC721Received.selector; }
    function setWalletDailyCap(uint256 c) external onlyOwner { walletDailyCap = c; }
    function withdraw(uint256 a) external onlyOwner { hunt.safeTransfer(owner(), a); }

    function _mintTo(address to, uint256 qty) internal returns (uint256 first) {
        uint256 d = block.timestamp / 1 days;
        if ((mintedOnDay[to][d] += qty) + game.walletMintedOnDay(to, d) > walletDailyCap) revert Cap();
        uint256 cost = game.mintPriceHunt() * qty;
        hunt.forceApprove(address(game), cost);
        first = hero.nextId();
        game.mint(qty);
        for (uint256 i; i < qty; i++) hero.transferFrom(address(this), to, first + i);
    }

    /// @notice paid mint; pulls price*qty HUNT from caller. ref = address(0) for none.
    function mint(uint256 qty, address ref) external nonReentrant returns (uint256 first) {
        if (ref == msg.sender) revert Bad();
        uint256 cost = game.mintPriceHunt() * qty;
        hunt.safeTransferFrom(msg.sender, address(this), cost);
        first = _mintTo(msg.sender, qty);
        if (ref != address(0)) { credits[ref] += 1; totalReferred[ref] += 1; }
        emit ReferredMint(msg.sender, ref, qty, first);
    }

    /// @notice spend 1 credit for 1 free hero (paid from the pool).
    function redeem() external nonReentrant returns (uint256 id) {
        if (credits[msg.sender] == 0) revert NoCredit();
        credits[msg.sender] -= 1;
        id = _mintTo(msg.sender, 1);
        emit Redeemed(msg.sender, id);
    }
}
