pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    //address public factory;
    uint public rewardTokens;
    uint lastUpdate;
    uint totalWeight;
    mapping(address => uint) public stakingStart;
    mapping(address => uint) public stakingWeight;

    string public constant name = 'bSwap V2';
    string public constant symbol = 'bSwap-V2';
    uint8 public constant decimals = 18;
    uint  public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _updateTotalWeight() internal {
        uint _lastUpdate = lastUpdate;
        if (_lastUpdate < block.timestamp) {
            totalWeight = totalWeight.add(
                (block.timestamp.sub(_lastUpdate))  // time interval
                .mul(totalSupply.sub(balanceOf[address(0)])) // total supply without address(0) balance
            );
            lastUpdate = block.timestamp;
        }
    }
    
    function _getWeight(address user) internal view returns (uint weight) {
        uint start = stakingStart[user];
        if (start != 0) {
            weight = stakingWeight[user].add(
                (block.timestamp.sub(start))    // time interval
                .mul(balanceOf[user])
            );
        }
    }

    function _mint(address to, uint value) internal {
        _updateTotalWeight();
        if (to != address(0)) {
            stakingWeight[to] = _getWeight(to);
            stakingStart[to] = block.timestamp;
        }
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal returns (uint rewardAmount) {
        _updateTotalWeight();
        uint weight = _getWeight(from);
        uint unstake = weight.mul(value) / balanceOf[from]; // unstake weight is proportional of value
        stakingWeight[from] = weight.sub(unstake);
        stakingStart[from] = block.timestamp;
        rewardAmount = rewardTokens.mul(unstake) / totalWeight;
        rewardTokens = rewardTokens.sub(rewardAmount);
        totalWeight = totalWeight.sub(unstake);
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        require(to == address(this), "Remove liquidity allowed only");
        _updateTotalWeight();
        uint weight = _getWeight(from);
        uint transferWeight = weight.mul(value) / balanceOf[from]; // transferWeight is proportional of transferring value
        stakingWeight[from] = weight - transferWeight;
        stakingStart[from] = block.timestamp;
        stakingWeight[to] = _getWeight(to) + transferWeight;
        stakingStart[to] = block.timestamp;

        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function getRewards(address user) external view returns (uint) {
        uint _totalWeight = totalWeight.add(
            (block.timestamp.sub(lastUpdate))  // time interval
            .mul(totalSupply.sub(balanceOf[address(0)])) // total supply without address(0) balance
        );
        uint weight = stakingWeight[user].add(
            (block.timestamp.sub(stakingStart[user]))    // time interval
            .mul(balanceOf[user])
        );
        return rewardTokens.mul(weight) / _totalWeight;
    }



    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}
