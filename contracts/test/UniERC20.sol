pragma solidity =0.5.16;

import '../BSwapV2ERC20.sol';

contract UniERC20 is BSwapV2ERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}