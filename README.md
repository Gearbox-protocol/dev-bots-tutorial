# Gearbox bots developer tutorial

Smart contracts and tests for Gearbox bots dev tutorials:
* [Limit orders](https://dev.gearbox.fi/bots/limit-orders);
* [Account manager](https://dev.gearbox.fi/bots/account-manager).

All the code in this repo can be used as template for other bots, while `test/BotTestHelper.sol` can help in testing.

## Installation

You would need to have [Foundry](https://github.com/foundry-rs/foundry) installed in order to run the tests.
We recommend updating it to the latest version prior to proceeding.

After cloning the repository, run `forge install`.
This would install the common dependencies like `forge-std` and `OpenZeppelin` as well as proper versions of Gearbox smart contracts needed for writing and testing bots.

Next, create a `.env` file, copy the contents from `.env.example` and change placeholder values to the appropriate ones.

Finally, run `forge test` to ensure everything works.
