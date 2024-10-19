// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PosmTestSetup} from "v4-periphery/test/shared/PosmTestSetup.sol";
import "forge-std/console2.sol";

// import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {Create2Deployer} from "./utils/Create2Deployer.sol";

import {KeeperHook} from "src/KeeperHook.sol";

contract KeeperHookTest is PosmTestSetup {
    address owner;
    KeeperHook keeperHook;
    Create2Deployer create2Deployer;

    uint128 constant MAX_TOTAL_GAS = 3 * 10e7; // 30m

    function setUp() public {
        owner = makeAddr("owner");

        create2Deployer = new Create2Deployer();

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployPosm(manager);

        _deployKeeperHook();
    }

    function test_BaseFunctionality() public {}

    function _deployKeeperHook() internal {
        uint160 hookFlags = uint160(Hooks.BEFORE_SWAP_FLAG);

        bytes memory encodedConstructorArgs = abi.encode(address(manager), address(lpm), MAX_TOTAL_GAS, owner);

        (address predictedAddr, bytes32 salt) =
            HookMiner.find(address(create2Deployer), hookFlags, type(KeeperHook).creationCode, encodedConstructorArgs);

        bytes memory hookBytecodeWithConstructorArgs =
            abi.encodePacked(type(KeeperHook).creationCode, encodedConstructorArgs);

        address keeperHookAddress = create2Deployer.deploy(salt, hookBytecodeWithConstructorArgs);

        require(predictedAddr == keeperHookAddress, "HookMiner: Addresses are not the same");
        keeperHook = KeeperHook(keeperHookAddress);
    }

    function _deployPoolWith1To10Ratio() internal {}
}
