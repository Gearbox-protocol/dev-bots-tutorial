# Gearbox bots developer tutorial

Smart contracts and tests for Gearbox bots dev [tutorial](https://dev.gearbox.fi/bots/overview).

All the code in this repo can be used as template for other bots.

## Installation

You would need to have [Foundry](https://github.com/foundry-rs/foundry) installed in order to run the tests.

After cloning the repository, run `forge install`.
This would install the common dependencies like `forge-std` and `OpenZeppelin` as well as proper versions of Gearbox smart contracts needed for writing and testing bots.

## Testing

Create a `.env` file with following environment variables:

| Variable | Description |
| -------- | ----------- |
| `RPC_URL` | Ethereum Mainnet JSON RPC URL. It will be used to fork the state, so it must support archive mode. |
| `ETHERSCAN_API_KEY` | Your Etherscan API key. Will be used for making cleaner stack traces. |
| `FORK_BLOCK_NUMBER` | Block number to use in tests. `16200000` would work just fine. |

To run tests, execute

```bash
source .env

forge test \
    --fork-url $RPC_URL \
    --fork-block-number $FORK_BLOCK_NUMBER \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --gas-report \
    -vvv
```
