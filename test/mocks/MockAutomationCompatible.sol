// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/chainlink/AutomationCompatibleInterface.sol";

contract MockAutomationCompatible is AutomationCompatibleInterface {
    uint256 public counter;
    uint48 public lastUpkeeped;
    uint48 public constant UPKEEP_COOLDOWN = 1 minutes;

    function checkUpkeep(bytes calldata checkData)
        external
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        bool shouldUpkeep = _shouldUpkeep();
        return (shouldUpkeep, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override {
        require(_shouldUpkeep(), "Upkeep is nod needed");
        lastUpkeeped = uint48(block.timestamp);
        ++counter;
    }

    function _shouldUpkeep() internal view returns (bool) {
        return uint48(block.timestamp) > lastUpkeeped + UPKEEP_COOLDOWN;
    }
}
