// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployProxy {
    function deploy(address _logic, address _admin, bytes memory _data) external returns(address) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(_logic, _admin, _data);
        return address(proxy);
    }
}
