// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {VRFRequest} from "./mainnet/GameMainnet.sol";
interface IVRFConsumer { function rawFulfillRandomWords(uint256, uint256[] calldata) external; }
/// @notice TESTNET ONLY stand-in for the Chainlink VRF v2.5 coordinator (same request/callback interface).
/// Used because the native-funded Chainlink subscription on BSC testnet did not get fulfilled. A keeper calls fulfill().
contract MockVRFCoordinator {
    struct R { address consumer; uint32 gas; bool done; }
    mapping(uint256 => R) public reqs; uint256 public n;
    event Requested(uint256 indexed id, address consumer); event Fulfilled(uint256 indexed id, bool ok);
    function requestRandomWords(VRFRequest calldata q) external returns (uint256 id) { id = ++n; reqs[id] = R(msg.sender, q.callbackGasLimit, false); emit Requested(id, msg.sender); }
    function fulfill(uint256 id) external { R storage r = reqs[id]; require(r.consumer != address(0) && !r.done); r.done = true;
        uint256[] memory w = new uint256[](1); w[0] = uint256(keccak256(abi.encode(blockhash(block.number - 1), id, block.prevrandao)));
        (bool ok,) = r.consumer.call{gas: r.gas}(abi.encodeCall(IVRFConsumer.rawFulfillRandomWords, (id, w))); emit Fulfilled(id, ok); }
}
