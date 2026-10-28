// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GameMainnet} from "./GameMainnet.sol";

/// @title 200 free whitelist mints reserved for community operations (events, KOL partners, early supporters).
/// Owner batch-adds addresses any time; each address claims 1 free hero (7-day trade lock). Hard cap 200 total.
contract WhitelistMint is Ownable, ReentrancyGuard {
    GameMainnet public immutable game;
    uint256 public constant MAX_WHITELIST = 200;
    uint256 public added; uint256 public claimed;
    mapping(address => bool) public listed; mapping(address => bool) public hasClaimed;
    error Cap(); error NotListed(); error Done();
    event Added(address indexed a); event Removed(address indexed a); event Claimed(address indexed a, uint256 heroId);

    constructor(address owner_, GameMainnet g) Ownable(owner_) { game = g; }

    function addBatch(address[] calldata a) external onlyOwner {
        for (uint256 i; i < a.length; i++) {
            if (a[i] == address(0) || listed[a[i]] || hasClaimed[a[i]]) continue;
            if (++added > MAX_WHITELIST) revert Cap();
            listed[a[i]] = true; emit Added(a[i]);
        }
    }
    /// @notice remove an unclaimed address, freeing its slot.
    function remove(address a) external onlyOwner { if (listed[a]) { listed[a] = false; added--; emit Removed(a); } }
    function remaining() external view returns (uint256) { return MAX_WHITELIST - added; }

    function claim() external nonReentrant returns (uint256 id) {
        if (!listed[msg.sender]) revert NotListed();
        if (hasClaimed[msg.sender]) revert Done();
        hasClaimed[msg.sender] = true; listed[msg.sender] = false; claimed++;
        id = game.mintFree(msg.sender, 4);
        emit Claimed(msg.sender, id);
    }
}
