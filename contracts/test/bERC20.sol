pragma solidity =0.5.16;

import '../DynamicERC20.sol';

contract bERC20 is DynamicERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}