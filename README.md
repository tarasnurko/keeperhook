# KeeperHook

It's uniswap v4 based hook that allow users exchange their transaction work in return of lower swap fees and additional collected fee from appropriate liquidity position in current pool.

## Guide for protocol owner (team member)

You are one of protocol members. First you need to mint some liquidity position using UniSwap V4 [PositionManager](https://github.com/Uniswap/v4-periphery/blob/main/src/PositionManager.sol). It would be better for you if you would mint liquidity position on pool with high usage (highest swap count per amo9unt of time) as more frequently users make swaps, less time there would be between check upkeep calls (which is good for you). After you selected good pair and created liquidity position with good enough for you amound of liquidity you deposit this liquidity position to `KeeperHook` (also dont forget to call `KeeperHook.setKeepersData()` to set desired max gas and your contract that uses `AutomationCompatible` interface). Aaaaaand, THATS ALL🎉🎉🎉. Now every user that make swap in pool (where you minted liquidity position) would check and perform upkeep (if needed). Be carefull to implement `AutomationCompatible` interface because if you make that `checkUpkeep()` or `performUpkeep()` make damage to user (they always revert or use all gas) than this contract as you would be considered malicious and you would be subsequent to **SLASH** (all deposits would be taken from you and your contract would be out of systam that means your contract would not be checked for upkeeps).

## Guide for user

Find pool with hook `KeeperHook`, and make swaps. If you `performUpkeep()` you would get **0 fee** for swap and moreover you would get accumulated fees from liquidity position that was provided for contract you did `performUpkeep()` to.

## Why?

Let's imagine situation that you are small protocol with little money that try to build code in the shortest period of time. Your smart-contract includes simple `AutomationCompatible` interface...

1. Why do you need AutomationCompatible interface? This interface is usually used when smart-contract need to update some data dependint on other state-changing stuff onchain ([read more from chainlink](https://docs.chain.link/chainlink-automation)). This can be used in various ocasions, for example:
  - automate liquidations of unhealthy users
  - update contract state that should be updated when other contract state (external from your system) is also updated  
  - when function need to be called consistently with some interval
  - and it's small part of what Automation can do to improve protocol...

So... Why not just use Chainlink or create own script to call smart-contract consistently??? Of courese you can, but...:
  - Own code. Firstly you need to create script that would check state as you want, then you need to somwhere deploy this script, you need to make sure this script never fails, you use RPC calls that can be very limited, you need to rent some server to host this script and more and more time and material expences.
  - Chainlink. Chainlink solves problem described above but it still need to be managed and more important, YOU STILL NEED TO PAY FOR TRANSACTION!!! (bet we dont😊)

Instead **KeeperHook** add ability to protocol owners to provide liquidity which is preserved and does not disappear anywhere. And that's a pros for user as user make transaction, checks whether you contract need upkeep and perform upkeep if it's needed. This gives advantages to both the user and protocol owner. WIN-WIN SITUATION.