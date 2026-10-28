// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Script.sol";
import "../src/HuntToken.sol"; import "../src/Hero.sol"; import "../src/MockAgentCity.sol";
import "../src/mainnet/GameMainnet.sol"; import "../src/MockVRFCoordinator.sol"; import "../src/mainnet/BattleMainnet.sol";
import "../src/mainnet/OfficialAgentMainnet.sol"; import "../src/mainnet/ReferralMainnet.sol"; import "../src/mainnet/WhitelistMint.sol"; import "../src/mainnet/GenesisDraw.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// Mainnet-candidate deploy. Gas estimate (dry run, no broadcast):
///   forge script script/DeployMainnet.s.sol --rpc-url https://bsc-dataseed.bnbchain.org --legacy
/// Real mainnet broadcast additionally requires CONFIRM_MAINNET=YES and --broadcast (owner approval first!).
/// env: PRIVATE_KEY, TREASURY (default user wallet), AGENT_CITY (mainnet: AgentCity NFT),
///      HUNT_PER_USD (wei, default 100e18), GAME_POOL / BATTLE_POOL / OFFICIAL_POOL (HUNT wei).
contract DeployMainnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY"); address me = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", address(0x145479F86ff50d9Ea3DA856f81Fa22B7F53665ad));
        bool main = block.chainid == 56;
        require(main || block.chainid == 97 || block.chainid == 31337, "unsupported chain");
        if (main) require(keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("YES"), "set CONFIRM_MAINNET=YES");
        uint256 gamePool = vm.envOr("GAME_POOL", uint256(10_000_000 ether));
        uint256 battlePool = vm.envOr("BATTLE_POOL", uint256(2_000_000 ether));
        uint256 offPool = vm.envOr("OFFICIAL_POOL", uint256(1_000_000 ether));
        vm.startBroadcast(pk);
        HuntToken hunt = new HuntToken(me); Hero hero = new Hero(me);
        address city = main ? vm.envAddress("AGENT_CITY") : vm.envOr("AGENT_CITY", address(0));
        if (city == address(0)) city = address(new MockAgentCity());
        GameMainnet game = new GameMainnet(me, hunt, hero, IERC721(city), treasury, treasury, vm.envOr("HUNT_PER_USD", uint256(100 ether)));
        hero.setGame(address(game));
        BattleMainnet bt = new BattleMainnet(me, hunt, hero);
        OfficialAgentMainnet ag = new OfficialAgentMainnet(me, hunt, hero, game, bt);
        ReferralMainnet rf = new ReferralMainnet(me, hunt, hero, game);
        WhitelistMint wl = new WhitelistMint(me, game); // 200 slots, no addresses yet
        game.setMinter(address(rf), true); game.setMinter(address(wl), true);
        GenesisDraw gd = new GenesisDraw(me, hunt, IGameG(address(game))); // 15% genesis escrow, no owner withdraw
        game.setGenesisDraw(gd); gd.setReferral(address(rf));
        // Chainlink BNB/USD for genesis BNB pricing
        address feed = vm.envOr("PRICE_FEED", main ? address(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE) : address(0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526));
        game.setPriceFeed(AggregatorV3Interface(feed), vm.envOr("PRICE_MAX_AGE", main ? uint256(1 hours) : uint256(1 days)));
        // public sale gate: no mint before SALE_START (mainnet fixed: 2026-10-28 12:00 UTC = 1793188800)
        uint256 sale = main ? 1793188800 : vm.envOr("SALE_START", uint256(1793188800));
        game.setSaleStart(sale);
        // Chainlink VRF v2.5 (native-paid subscription). Create/fund the subscription first, then pass VRF_SUB_ID; add the Game as consumer after deploy.
        uint256 sub = vm.envOr("VRF_SUB_ID", uint256(0));
        if (main) require(sub != 0, "VRF_SUB_ID required on mainnet");
        if (sub != 0) game.setVrf(IVRFCoordinatorV2Plus(main ? 0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9 : 0xDA3b641D438362C440Ac5458c57e00a712b66700),
            main ? bytes32(0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4) : bytes32(0x8596b430971ac45bdf6088665b9ad8e8630c9d5049ab54b14dff711bee7c0e26),
            sub, 3, uint32(vm.envOr("VRF_CB_GAS", uint256(900_000))));
        if (!main && sub == 0 && vm.envOr("MOCK_VRF", false)) game.setVrf(IVRFCoordinatorV2Plus(address(new MockVRFCoordinator())), bytes32(0), 1, 3, 900_000);
        uint256 gsec = vm.envOr("GENESIS_SECONDS", uint256(0)); // testnet rehearsal only
        if (gsec > 0) { require(!main, "mainnet genesis is fixed at 3 days"); game.setGenesisDurationTestnet(gsec); }
        game.mintOfficial(); hero.safeTransferFrom(me, vm.envOr("OFFICIAL_TO", address(0x6DdF5CbFe74CB7c5e2a840fe10eefCA9feE36096)), 0);
        hunt.approve(address(game), gamePool); game.fundRewards(gamePool);
        hunt.transfer(address(bt), battlePool); hunt.transfer(address(ag), offPool);
        // allocation: team 100M vesting (locked to 2027-04-28 12:00 UTC, linear to 2028-04-28 12:00 UTC)
        VestingWallet vest = new VestingWallet(0xE5f18Ce0B11250Ef4176D565Dcc9a7D71271663f, 1808913600, 1840536000 - 1808913600);
        hunt.transfer(address(vest), 100_000_000 ether);
        hunt.transfer(0xC64F47373305F3315870502aCD1D557F15aC1008, 100_000_000 ether); // community
        hunt.transfer(0x0dBE9F08c75cd46B43F1276C9a39AA6bE36e7e14, 100_000_000 ether); // ecosystem/BOUNTY
        hunt.transfer(0x6DdF5CbFe74CB7c5e2a840fe10eefCA9feE36096, 1_000_000 ether); // from treasury share
        hunt.transfer(treasury, hunt.balanceOf(me)); // treasury 149M + liquidity 150M + game reserve 387M
        console.log("Vesting", address(vest));
        vm.stopBroadcast();
        console.log("HUNT", address(hunt)); console.log("Hero", address(hero)); console.log("AgentCity", city);
        console.log("Game", address(game)); console.log("Battle", address(bt)); console.log("OfficialAgent", address(ag));
        console.log("Referral", address(rf)); console.log("Whitelist", address(wl)); console.log("GenesisDraw", address(gd));
    }
}
