# CITY HUNTERS — Smart Contracts

On-chain hero game on BNB Smart Chain. Mint heroes, send them to work for HUNT, and battle other hunters.

- Website: https://cityhunters.io
- X: https://x.com/CityHunters_X
- Chain: BNB Smart Chain (chainId 56)

## Mainnet deployments (all verified on BscScan)

| Contract | Address |
|---|---|
| HUNT Token | [`0x03353e0Dfc5123de796417f98437e45B48d88146`](https://bscscan.com/address/0x03353e0Dfc5123de796417f98437e45B48d88146#code) |
| Hero NFT | [`0xF10d29ea0480AC292a616Ff3692fCd27961A3Aa2`](https://bscscan.com/address/0xF10d29ea0480AC292a616Ff3692fCd27961A3Aa2#code) |
| Game | [`0x286F24d6BA59F4dE3fEb04aC41aBCa12e422d956`](https://bscscan.com/address/0x286F24d6BA59F4dE3fEb04aC41aBCa12e422d956#code) |
| Battle | [`0xE985199d7cDf4a8211b07Ab7C57f3E7e40c5a25A`](https://bscscan.com/address/0xE985199d7cDf4a8211b07Ab7C57f3E7e40c5a25A#code) |
| Agent City | [`0x04a9F5a5f6409DAd7eD9eC54bBACF89663651cD7`](https://bscscan.com/address/0x04a9F5a5f6409DAd7eD9eC54bBACF89663651cD7#code) |
| Referral | [`0xF4F3a0045fB2Bfc1F5cB37E20fb2fdEbDe781DA7`](https://bscscan.com/address/0xF4F3a0045fB2Bfc1F5cB37E20fb2fdEbDe781DA7#code) |
| Genesis Draw | [`0x5A059D831F9208f4435eD7C490EbdB078F909528`](https://bscscan.com/address/0x5A059D831F9208f4435eD7C490EbdB078F909528#code) |
| Whitelist Mint | [`0x0126558a6D93F92E3f1D6195D9BDd863cddf7394`](https://bscscan.com/address/0x0126558a6D93F92E3f1D6195D9BDd863cddf7394#code) |
| Official Agent | [`0x1E5F0896F6d568157fc6f71C29Cb7833d1C41D0f`](https://bscscan.com/address/0x1E5F0896F6d568157fc6f71C29Cb7833d1C41D0f#code) |
| Team Vesting | [`0x6566092A7Baa5DfCC3699C7CC6B6D6786Ae53a9e`](https://bscscan.com/address/0x6566092A7Baa5DfCC3699C7CC6B6D6786Ae53a9e#code) |

Full list incl. Chainlink config: [`deployments/mainnet.json`](deployments/mainnet.json). ABIs: [`deployments/abi`](deployments/abi).

Genesis sale: starts 2026-10-28T12:00:00Z, ends 2026-10-31T12:00:00Z (UTC).

## Repository layout

- `src/` core contracts (Hero, HuntToken, Game, Battle, Referral, OfficialAgent) and mocks for testing
- `src/mainnet/` mainnet versions (GameMainnet, BattleMainnet, ReferralMainnet, GenesisDraw, WhitelistMint, OfficialAgentMainnet)
- `test/` Foundry tests
- `script/` Foundry deployment scripts

## Build & test

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
forge build
forge test
```

## Configuration

All economic parameters are adjustable by the owner through setter functions; nothing is hard-coded into game logic. Randomness uses Chainlink VRF on BSC.

Deployment scripts read `PRIVATE_KEY` from the environment. Copy `.env.example` to `.env` locally; never commit it.

## Security

Found an issue? Please contact the team via X DM @CityHunters_X.

## License

MIT
