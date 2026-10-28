// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
/// @notice TESTNET ONLY stand-in for AgentCity genesis city cards (mainnet 0x04a9F5a5f6409DAd7eD9eC54bBACF89663651cD7).
contract MockAgentCity is ERC721 {
    uint256 public totalSupply;
    constructor() ERC721("Mock AgentCity", "mCITY") {}
    function mint(address to) external returns (uint256 id) { id = totalSupply++; _mint(to, id); }
}
