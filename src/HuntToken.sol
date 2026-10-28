// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title HUNT - fixed supply 1,000,000,000, all minted once to `holder`. No mint function.
contract HuntToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    constructor(address holder) ERC20("City Hunters HUNT", "HUNT") { _mint(holder, TOTAL_SUPPLY); }
}
