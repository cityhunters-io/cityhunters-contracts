// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// @notice TESTNET ONLY Chainlink-style BNB/USD feed so genesis BNB mints can be rehearsed with scarce tBNB.
/// Anyone may set it (testnet). updatedAt can be back-dated to rehearse the staleness revert.
contract MockBnbUsdFeed {
    int256 public answer; uint256 public updatedAt; uint8 public constant decimals = 8; uint80 public round = 1;
    constructor(int256 a) { answer = a; updatedAt = block.timestamp; }
    function set(int256 a, uint256 ageSeconds) external { answer = a; updatedAt = block.timestamp - ageSeconds; round++; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { return (round, answer, updatedAt, updatedAt, round); }
}
