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
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract KeeperHook is BaseHook, AccessControl {
    // @dev uniswap-v4 position manager
    IPositionManager public immutable positionManager;
    address public slasher;

    // FEES
    uint24 public constant ZERO_ITERATIONS_FEE = 500; // 0.05%, 1000000 = 100%
    uint24 public constant DEFAULT_FEE = 100; // 0.01%

    // uint256 public constant KEEPERS_ORDER_MAX_LENGTH = 10;

    // ROLES
    bytes32 constant SLAHSER_ROLE = keccak256("SLAHSER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // GAS
    // @dev max total gas that can be spent by user while checkUpkeep + performUpkeep for all keepers in beforeSwap, must be less then block gas
    uint128 public immutable maxTotalGas;

    uint48 public constant MODIFY_POSITION_LIQUIDITY_COOLDOWN = 4 hours;
    uint48 public constant POSITION_WITHDRAWAL_COOLDOWN = 1 days;

    // @dev struct that represetns parameters when calling AutomationCompatible functions
    struct KeepersData {
        uint128 maxCheckUpkeepGas;
        uint128 maxPerformUpkeepGas;
        address contractAddress;
    }

    /**
     * @param date after which withdrawal request can be completed
     */
    struct LiquidityWithdrawalRequest {
        bool completed;
        uint48 date;
        address liquidityOwner;
        PoolId poolId;
        uint256 positionTokenId;
    }

    error SenderIsNotLiquidityOwner();
    error PositionTokenIsNotReturned();
    error LiquidityAfterLessThenBefore();
    error LiquidityPositionForPoolIsNotEmpty();
    error TotalGasExceedsMaxTotalGas();
    error LiquidityOwnerIsAlreadySlashed();

    /**
     * @notice event when checkUpkeep returns true but performUpkeep failed
     * @dev such performUpkeep can be malicious and be subsequet to slashing
     */
    event PerformUpkeepFailed(address liquidityOwner, PoolId poolId, address contractAddress);

    // @dev owner of deposited liquidity position token
    mapping(uint256 positionTokenId => address liquidityOwner) public liquidityPositionOwners;
    mapping(address liquidityOwner => mapping(PoolId poolId => uint256 positionTokenId)) public liquidityPositions;
    mapping(address liquidityOwner => KeepersData keepersData) public keepers;
    // @dev represent contracts that need to be upkeeped
    mapping(PoolId poolId => address[] liquidityOwners) public keeperOrders;

    // Liquidity manipulation cooldown
    mapping(uint256 positionTokenId => uint48 expiresAt) public modifyLiquidityPositionCooldowns;
    // Liquidity withdrawal requests
    mapping(bytes32 withdrawalHash => LiquidityWithdrawalRequest request) public liquidityWithdrawalRequests;

    // Slash info mappings
    mapping(address liquidityOwner => bool isSlashed) public slashedLiquidityOwner;
    mapping(address keepersContractAddress => bool isSlashed) public slashedKeepersContracts;

    constructor(address _poolManager, address _positionManager, uint128 _maxTotalGas, address _slasher)
        BaseHook(IPoolManager(_poolManager))
    {
        validateHookAddress(this);
        positionManager = IPositionManager(_positionManager);
        maxTotalGas = _maxTotalGas;
        slasher = _slasher;
    }

    /////////////////////////////////////
    //          HOOK FUNCTIONS         //
    /////////////////////////////////////

    /**
     * @notice main functionality of the protocol. If user successfuly performs upkeep they pay 0 swap fee and also get accumulate fees of appropriate poolid liquidity position
     */
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

            // TODO: write function to check for data without changing storage (use revertDelegateCall?)
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

            emit PerformUpkeepFailed(liquidityOwner, poolId, keepersData.contractAddress);
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

    // function that allows liquidity owner to change liquidityPosition to new (for example for different amount of liquidity or for different ticks)
    // function changeLiquidityPosition(uint256 newTokenId) external {}

    function depositLiquidityPosition(uint256 positionTokenId) external {
        address liquidityOwner = msg.sender;
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(positionTokenId);
        PoolId poolId = poolKey.toId();

        _checkLiquidityPositionDoesntExist(liquidityOwner, poolId);

        _positionManagerAsERC721().transferFrom(liquidityOwner, address(this), positionTokenId);

        liquidityPositionOwners[positionTokenId] = liquidityOwner;
        modifyLiquidityPositionCooldowns[positionTokenId] = Time.timestamp() + MODIFY_POSITION_LIQUIDITY_COOLDOWN;
        liquidityPositions[liquidityOwner][poolId] = positionTokenId;
        keeperOrders[poolId].push(liquidityOwner);

        _sortKeeperOrders(poolId);
        _checkOrderOperationsInGasLimit(poolId);
    }

    /**
     * @dev when liquidity owner is being liquidates so they dont front-run and not withdraw all liquidity before slashing as there is cooldown between withdrawal request and withdrawal completion
     */
    function withdrawLiquidityPosition(PoolId poolId, uint256 positionTokenId)
        external
        returns (LiquidityWithdrawalRequest memory, bytes32)
    {
        address liquidityOwner = msg.sender;

        require(positionTokenId != 0);
        require(liquidityPositionOwners[positionTokenId] == liquidityOwner);
        require(liquidityPositions[liquidityOwner][poolId] == positionTokenId);

        delete liquidityPositionOwners[positionTokenId];
        // remove from keeperOrders
        uint256 orderLength = keeperOrders[poolId].length;
        for (uint256 i; i < orderLength; i++) {
            if (keeperOrders[poolId][i] == liquidityOwner) {
                keeperOrders[poolId][i] = keeperOrders[poolId][orderLength - 1];
                keeperOrders[poolId].pop();
                break;
            }
        }

        LiquidityWithdrawalRequest memory liquidityWithdrawalRequest;
        liquidityWithdrawalRequest.date = Time.timestamp() + POSITION_WITHDRAWAL_COOLDOWN;
        liquidityWithdrawalRequest.liquidityOwner = liquidityOwner;
        liquidityWithdrawalRequest.poolId = poolId;
        liquidityWithdrawalRequest.positionTokenId = positionTokenId;

        bytes32 hash = _getLiquidityWithdrawalRequestHash(liquidityWithdrawalRequest);

        return (liquidityWithdrawalRequest, hash);
    }

    function completeWithdrawLiquidityPosition(bytes32 requestHash) external {
        LiquidityWithdrawalRequest storage request = liquidityWithdrawalRequests[requestHash];

        require(request.date != 0, "Request doesnt exist");
        require(Time.timestamp() > request.date);
        require(!request.completed, "Requst has been already completed");

        request.completed = true;

        _positionManagerAsERC721().safeTransferFrom(address(this), request.liquidityOwner, request.positionTokenId);
    }

    /**
     * @notice slashes malicious liquidity owner
     * @dev sends all slashed positionTokens to slasher
     * @dev executes in case keepers contract make some malicious actions like
     * - doesnt allow any user to performUpkeep by always reverting
     * - returngasbombs user, blocking functionality
     * - other malicious actions that dont allow user to correctly check upkeep or perform upkeep
     * @param liquidityOwner liquidity owner address to be liquidated
     * @param poolIds array of poolIds where liquidityOwner has any liquidity
     * @param positionTokenIds array of owned positionTokenIds
     */
    function slashKeepers(address liquidityOwner, PoolId[] calldata poolIds, uint256[] calldata positionTokenIds)
        external
        onlyRole(SLAHSER_ROLE)
    {
        require(!slashedLiquidityOwner[liquidityOwner]);
        require(!slashedKeepersContracts[liquidityOwner]);

        slashedLiquidityOwner[liquidityOwner] = true;
        slashedKeepersContracts[liquidityOwner] = true;

        delete keepers[liquidityOwner];

        uint256 poolIdsLength = poolIds.length;
        uint256 positionTokenIdsLength = positionTokenIds.length;

        // delete all pool liquidityPositions
        for (uint256 i = 0; i < poolIdsLength; ++i) {
            PoolId poolId = poolIds[i];

            require(liquidityPositions[liquidityOwner][poolId] != 0);
            delete liquidityPositions[liquidityOwner][poolId];

            address[] memory poolLiquidityOwners = keeperOrders[poolId];
            uint256 len = poolLiquidityOwners.length;

            // remove liquidityPosition
            for (uint256 j = 0; j < len; ++j) {
                if (poolLiquidityOwners[j] == liquidityOwner) {
                    poolLiquidityOwners[j] = poolLiquidityOwners[len - 1];
                    break;
                }
            }

            keeperOrders[poolId] = poolLiquidityOwners;
            keeperOrders[poolId].pop();

            _sortKeeperOrders(poolId);
        }

        // delete liquidityOwner from onwing liquidityPosition
        for (uint256 i = 0; i < positionTokenIdsLength; ++i) {
            uint256 positionTokenId = positionTokenIds[i];

            require(liquidityPositionOwners[positionTokenId] != address(0));
            delete liquidityPositionOwners[positionTokenId];
        }
    }

    // @notice collect accumulated fees from position
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

    function _getLiquidityWithdrawalRequestHash(LiquidityWithdrawalRequest memory req)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(req.date, req.liquidityOwner, req.poolId, req.positionTokenId));
    }

    // function _checkLiquidityPosition

    /**
     * @notice updates liquidityPosition without removing it from contract
     * @notice can be used when protocol want to add liquidity or/and change tick lower/upper to    (concentrate liquidity) generate more fees (for example)
     */
    function updateLiquidityPosition(uint256 positionTokenId) external {
        if (msg.sender != liquidityPositionOwners[positionTokenId]) {
            revert SenderIsNotLiquidityOwner();
        }

        // (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(positionTokenId);
        // PoolId poolId = poolKey.toId();

        uint128 liquidityBefore = positionManager.getPositionLiquidity(positionTokenId);

        _positionManagerAsERC721().safeTransferFrom(address(this), msg.sender, positionTokenId);

        if (_positionManagerAsERC721().ownerOf(positionTokenId) != address(this)) {
            revert PositionTokenIsNotReturned();
        }

        uint128 liquidityAfter = positionManager.getPositionLiquidity(positionTokenId);

        if (liquidityAfter < liquidityBefore) {
            revert LiquidityAfterLessThenBefore();
        }
    }

    function setKeepersData(KeepersData calldata keepersData) external {
        keepers[msg.sender] = keepersData;
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
