// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./Mainnet.t.sol";
contract DropTest is Base {
    function testDropWholeNonRoundInRange() public view {
        uint256[3] memory b = [uint256(50), 150, 400];
        for (uint8 t; t < 3; t++) {
            uint256 mn = type(uint256).max; uint256 mx; uint256 distinct;
            bool[1000] memory seen;
            for (uint256 i; i < 2000; i++) {
                uint256 d = bt.previewDrop(t, uint256(keccak256(abi.encode(t, i))));
                assertEq(d % 1 ether, 0, "whole HUNT"); uint256 x = d / 1 ether;
                assertTrue(x % 5 != 0, "never ends in 0/5");
                assertGe(x, b[t] / 2); assertLe(x, b[t] * 3 / 2);
                if (x < mn) mn = x; if (x > mx) mx = x; if (!seen[x]) { seen[x] = true; distinct++; }
                assertTrue((2 * x) % 5 != 0, "official 2x also non-round");
            }
            // 80% of integers in range are non-multiples of 5
            assertGe(distinct, (b[t] + 1) * 8 / 10 * 95 / 100, "covers nearly every allowed integer");
            assertLe(mn, b[t] / 2 + 2); assertGe(mx, b[t] * 3 / 2 - 2);
        }
    }
    function testFightPaysOrganicAmount() public {
        vm.prank(alice); game.mint(1); uint256 id = hero.nextId() - 1;
        bt.setRules(100, 100, 0, 1_000_000 ether, [uint256(50 ether), 150 ether, 400 ether]);
        uint256 wins;
        for (uint256 i; i < 40; i++) {
            vm.prevrandao(bytes32(i + 3)); uint256 b0 = hunt.balanceOf(alice); vm.prank(alice); bool w = bt.fight(id, 0);
            uint256 got = hunt.balanceOf(alice) - b0;
            if (w) { wins++; assertEq(got % 1 ether, 0); assertTrue((got / 1 ether) % 5 != 0); assertGe(got, 25 ether); assertLe(got, 75 ether); }
        }
        assertGt(wins, 0);
    }
}
