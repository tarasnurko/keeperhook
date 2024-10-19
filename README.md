# KeeperHook

It's uniswap v4 based hook that allow users exchange their transaction work in return of lower swap fees and additional collected fee from appropriate liquidity position in current pool.

## How does it work?

## Why?

Let's imagine situation that you are small protocol with little money that try to build code in the shortest period of time. Your smart-contract includes simple AutomationCompatible interface...

1. Why do you need AutomationCompatible interface? This interface is usually used when smart-contract need to update some data dependint on other state-changing stuff onchain ([https://docs.chain.link/chainlink-automation](read more from chainlink)). This can be used in various ocasions, for example:
  - automate liquidations of unhealthy users
  - update contract state that should be updated when other contract state (external from your system) is also updated  
  - when function need to be called consistently with some interval
  - and it's small part of what Automation can do to improve protocol...

So... Why not just use Chainlink or create own script to call smart-contract consistently??? Of courese you can, but...:
  - Own code. Firstly you need to create script that would check state as you want, then you need to somwhere deploy this script, you need to make sure this script never fails, you use RPC calls that can be very limited, you need to rent some server to host this script and more and more time and material expences.
  - Chainlink. Chainlink solves problem described above but it still need to be managed and more important, YOU STILL NEED TO PAY FOR TRANSACTION!!! (bet we dont😊)

Instead **KeeperHook** add ability to protocol owners to provide liquidity which is preserved and does not disappear anywhere. And that's a pros for user as user make transaction, checks whether you contract need upkeep and perform upkeep if it's needed. This gives advantages to both the user and protocol owner. WIN-WIN SITUATION.