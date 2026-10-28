// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Hero NFT. All state changes are done by the single `game` contract.
/// Transfers are blocked while a hero is working or inside its trade lock.
contract Hero is ERC721, Ownable {
    // rarity: 0 Common, 1 Rare, 2 Epic, 3 Legendary, 4 OFFICIAL
    // class: 0 Ronin(STR/CON) 1 Hacker(INT/AGI) 2 Warlock(SPI/INT) 3 Scout(AGI/STR) 4 Astrologer(SPI/CON) 5 Guardian(CON/STR)
    struct HeroData {
        uint8 rarity; uint8 class_; uint8 level;
        uint8[5] attrs; // STR, AGI, INT, SPI, CON
        bool isOfficial;
        uint32 workedHours;   // cumulative hours worked (decay + 90-day cap)
        uint64 tradeLockUntil;
        uint64 busyUntil;     // working lock
        uint8 energy; uint64 energyUpdatedAt;
    }
    mapping(uint256 => HeroData) internal _heroes;
    address public game;
    uint256 public nextId = 1; // tokenId 0 reserved for OFFICIAL #000
    bool public officialMinted;
    string private _base;

    error NotGame(); error Locked(); error OfficialDone();
    modifier onlyGame() { if (msg.sender != game) revert NotGame(); _; }

    constructor(address owner_) ERC721("City Hunters Hero", "HERO") Ownable(owner_) {}

    function setGame(address g) external onlyOwner { require(game == address(0), "game set"); game = g; }
    function setBaseURI(string calldata b) external onlyOwner { _base = b; }
    function _baseURI() internal view override returns (string memory) { return _base; }

    function getHero(uint256 id) external view returns (HeroData memory) { _requireOwned(id); return _heroes[id]; }

    function mintHero(address to, HeroData memory d) external onlyGame returns (uint256 id) {
        id = nextId++; _heroes[id] = d; _safeMint(to, id);
    }
    /// @notice OFFICIAL #000: tokenId 0, all attrs 100, only once, minted to `to` (owner/treasury).
    function mintOfficial(address to) external onlyGame {
        if (officialMinted) revert OfficialDone();
        officialMinted = true;
        _heroes[0] = HeroData(4, 0, 20, [uint8(100),100,100,100,100], true, 0, 0, 0, 48, uint64(block.timestamp));
        _safeMint(to, 0);
    }
    function setHero(uint256 id, HeroData memory d) external onlyGame { _requireOwned(id); _heroes[id] = d; }
    function burn(uint256 id) external onlyGame { delete _heroes[id]; _burn(id); }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        if (from != address(0) && to != address(0)) {
            HeroData storage h = _heroes[id];
            if (block.timestamp < h.tradeLockUntil || block.timestamp < h.busyUntil) revert Locked();
        }
        return super._update(to, id, auth);
    }
}
