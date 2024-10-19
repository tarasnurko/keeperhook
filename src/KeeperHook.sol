// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {AutomationCompatibleInterface} from "./chainlink/AutomationCompatibleInterface.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

contract KeeperHook is BaseHook {
    // @dev uniswap-v4 position manager
    IPositionManager public immutable positionManager;

    // FEES
    uint24 public constant ZERO_ITERATIONS_FEE = 500; // 0.05%, 1000000 = 100%
    uint24 public constant DEFAULT_FEE = 100; // 0.01%

    // GAS
    uint128 public immutable maxTotalGas;

    // @dev struct that represetns parameters when calling AutomationCompatible functions
    struct KeepersData {
        uint128 maxCheckUpkeepGas;
        uint128 maxPerformUpkeepGas;
        address contractAddress;
    }

    error LiquidityPositionForPoolIsNotEmpty();

    // @dev owner of deposited liquidity position token
    mapping(uint256 positionTokenId => address liquidityOwner) public liquidityPositionOwners;
    mapping(address liquidityOwner => mapping(PoolId poolId => uint256 positionTokenId)) public liquidityPositions;
    mapping(address liquidityOwner => KeepersData keepersData) public keepers;
    // @dev represent contracts that need to be upkeeped
    mapping(PoolId poolId => address[] liquidityOwners) public keeperOrders;

    constructor(address _poolManager, address _positionManager, uint128 _maxTotalGas)
        BaseHook(IPoolManager(_poolManager))
    {
        validateHookAddress(this);
        positionManager = IPositionManager(_positionManager);
        maxTotalGas = _maxTotalGas;
    }

    /////////////////////////////////////
    //          HOOK FUNCTIONS         //
    /////////////////////////////////////

    function beforeSwap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = poolKey.toId();
        uint256 keepersForPoolLength = keeperOrders[poolId].length;

        if (keepersForPoolLength == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, ZERO_ITERATIONS_FEE);
        }

        bool hasUpkeepPerformed;
        address liquidityOwner;

        for (uint256 i = 0; i < keepersForPoolLength; ++i) {
            liquidityOwner = keeperOrders[poolId][i];
            KeepersData memory keepersData = keepers[liquidityOwner];

            // TODO: write function to check for data without changing storage
            (bool success, bytes memory data) = keepersData.contractAddress.call{gas: keepersData.maxCheckUpkeepGas}(
                abi.encodeWithSelector(AutomationCompatibleInterface.checkUpkeep.selector, bytes(""))
            );

            if (!success) continue;

            (bool upkeepNeeded, bytes memory performData) = abi.decode(data, (bool, bytes));

            if (!upkeepNeeded) continue;

            (success,) = keepersData.contractAddress.call{gas: keepersData.maxPerformUpkeepGas}(
                abi.encodeWithSelector(AutomationCompatibleInterface.performUpkeep.selector, performData)
            );

            if (success) {
                hasUpkeepPerformed = true;
                break;
            }
        }

        if (!hasUpkeepPerformed) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, DEFAULT_FEE);
        }

        _withdrawFees(poolKey, tx.origin, liquidityPositions[liquidityOwner][poolId]);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /////////////////////////////////////
    //        LIQUIDITY FUNCTIONS      //
    /////////////////////////////////////

    function depositLiquidity(uint256 positionTokenId) external {
        address liquidityOwner = msg.sender;
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(positionTokenId);
        PoolId poolId = poolKey.toId();

        _checkLiquidityPositionDoesntExist(liquidityOwner, poolId);

        _positionManagerAsERC721().transferFrom(liquidityOwner, address(this), positionTokenId);

        liquidityPositionOwners[positionTokenId] = liquidityOwner;
        // modifyLiquidityPositionCooldowns[positionTokenId] = Time.timestamp() + MODIFY_POSITION_LIQUIDITY_COOLDOWN;
        liquidityPositions[liquidityOwner][poolId] = positionTokenId;
        keeperOrders[poolId].push(liquidityOwner);

        _sortKeeperOrders(poolId);
        _checkOrderOperationsInGasLimit(poolId);
    }

    function withdrawLiquidity() external {}

    // collect accumulated fees from position
    function _withdrawFees(PoolKey calldata poolKey, address to, uint256 positionTokenId) internal {
        // https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/collect

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        /// @dev collecting fees is achieved with liquidity=0, the second parameter
        params[0] = abi.encode(positionTokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, to);

        uint256 deadline = block.timestamp + 60;
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /////////////////////////////////////
    //        INTERNAL FUNCTIONS       //
    /////////////////////////////////////

    function _checkLiquidityPositionDoesntExist(address liquidityOwner, PoolId poolId)
        internal
        view
        returns (uint256 positionTokenId)
    {
        positionTokenId = liquidityPositions[liquidityOwner][poolId];

        if (positionTokenId != 0) {
            revert LiquidityPositionForPoolIsNotEmpty();
        }
    }

    function _positionManagerAsERC721() internal view returns (IERC721) {
        return IERC721(address(positionManager));
    }

    function _sortKeeperOrders(PoolId poolId) internal {
        address[] memory order = keeperOrders[poolId];
        uint256 orderLength = order.length;

        for (uint256 i = 0; i < orderLength - 1; i++) {
            for (uint256 j = 0; j < orderLength - 1 - i; j++) {
                // Compare the values from the mapping and swap addresses if needed
                if (liquidityPositions[order[j]][poolId] < liquidityPositions[order[j + 1]][poolId]) {
                    // Swap addresses[j] and addresses[j + 1]
                    address temp = order[j];
                    order[j] = order[j + 1];
                    order[j + 1] = temp;
                }
            }
        }

        keeperOrders[poolId] = order;
    }

    function _checkOrderOperationsInGasLimit(PoolId poolId) internal view {
        uint256 totalGas;
        uint256 orderLength = keeperOrders[poolId].length;

        for (uint256 i = 0; i < orderLength; ++i) {
            address keeper = keeperOrders[poolId][i];
            KeepersData memory keepersData = keepers[keeper];
            totalGas += keepersData.maxCheckUpkeepGas + keepersData.maxPerformUpkeepGas;
        }

        require(totalGas <= maxTotalGas);
    }
}
