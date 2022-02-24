pragma solidity =0.5.16;

library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

contract DynamicPair {
    using SafeMath  for uint;
    using UQ112x112 for uint224;
    
    enum Vars {timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodMA}
    uint32[8] public vars = [86400,10000,10000,10000,10000,10000,10,45*60]; // timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodM
    //timeFrame = 1 days;  // during this time frame rate of reserve1/reserve0 should be in range [baseLinePrice0*(1-maxDump0), baseLinePrice0*(1+maxDump1)]
    //maxDump0 = 10000;   // maximum allowed dump (in percentage with 2 decimals) of reserve1/reserve0 rate during time frame relatively the baseline
    //maxDump1 = 10000;   // maximum allowed dump (in percentage with 2 decimals) of reserve0/reserve1 rate during time frame relatively the baseline
    //maxTxDump0 = 10000; // maximum allowed dump (in percentage with 2 decimals) of token0 price per transaction
    //maxTxDump1 = 10000; // maximum allowed dump (in percentage with 2 decimals) of token1 price per transaction
    //coefficient = 10000; // coefficient (in percentage with 2 decimals) to transform price growing into fee. ie
    //minimalFee = 10;   // Minimal fee percentage (with 2 decimals) applied to transaction. I.e. 10 = 0.1%
    //periodMA = 45*60;  // MA period in seconds

    uint256 public baseLinePrice0;// base line of reserve1/reserve0 rate fixed on beginning od each time frame.
    uint256 public lastMA;        // last MA value

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0 = address(0);
    address public token1 = address(1);
    uint8 public isPrivate;  // in private pool only LP holder (creator) can add more liquidity

    uint112 private reserve0 = 1000*1e18;//*1e11;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1 = 10000*1e18;//*1e11;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast = 1643911141; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    address WETH = address(0);
    uint private unlocked;
    modifier lock() {
        require(unlocked == 1, 'Dynamic: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'Dynamic: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event AddReward(uint reward);
    event Fees(uint fee0, uint fee1);

    
    constructor() public {
        uint priceBefore0 = uint(UQ112x112.encode(reserve1).uqdiv(reserve0));
        baseLinePrice0 = priceBefore0;
        lastMA = priceBefore0;
        unlocked = 1;
    }
    
    function changeMA(uint percent) external {
        lastMA = lastMA * percent / 100;
        blockTimestampLast = uint32(block.timestamp % 2**32);
    }

    function resetMA() external {
        lastMA = baseLinePrice0;
        blockTimestampLast = 1643911141;
    }

    function setWETH(uint _weth) external {
        WETH = address(_weth);
    }

    function setCoef(uint32 coef) external {
        vars[uint(Vars.coefficient)] = coef;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1, uint32[8] calldata _vars, uint8 _isPrivate) external {
        require(address(0) == factory, 'Dynamic: FORBIDDEN'); // sufficient check
        unlocked = 1;
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        vars = _vars;
        isPrivate = _isPrivate;
        //super.initialize();
    }

    function _getDenominator(uint v) internal pure returns(uint denominator) {
        if (v>1e54) denominator = 1e27;
        else if (v>1e36) denominator = 1e18;
        else denominator = 1e9;
    }

    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns(uint amountOut) {
        (amountOut,) = getAmountOutAndFee(amountIn, tokenIn, tokenOut);
    }

    function getAmountOutAndFee(uint amountIn, address tokenIn, address tokenOut) public view returns(uint amountOut, uint fee) {
        uint32[8] memory _vars = vars;
        uint balanceIn;
        uint112 reserveOut = reserve1;
        uint112 reserveIn = reserve0;
        uint ma;
        {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);        
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        uint priceBefore0 = uint(UQ112x112.encode(reserveOut).uqdiv(reserveIn));
        if (timeElapsed >= _vars[uint(Vars.periodMA)]) ma = priceBefore0;
        else ma = ((_vars[uint(Vars.periodMA)] - timeElapsed)*lastMA + priceBefore0*timeElapsed) / _vars[uint(Vars.periodMA)];
        }
        {
        amountOut = amountIn.mul(_vars[uint(Vars.coefficient)]) / 10000;    // reuse amountOut
        uint b;
        uint c;
        ma = ma / 2**56;
        {
        uint k = uint(reserveIn).mul(reserveOut);// / denominator;
        uint denominator = _getDenominator(k);
        k = k / denominator;
        if (tokenIn < tokenOut) {
            balanceIn = amountIn.add(reserveIn);
            b = balanceIn.mul(ma) / 2**56;
            b = b.mul(balanceIn.sub(amountOut));
            b = b / denominator;
            //b = (uint(reserveIn).mul(ma) / 2**56).mul(balanceIn) / denominator;
            c = (k.mul(ma) / 2**56).mul(balanceIn);
        } else {
            (reserveIn, reserveOut) = (reserveOut, reserveIn);
            balanceIn = amountIn.add(reserveIn);
            b = balanceIn.mul(2**56) / ma;
            b = b.mul(balanceIn.sub(amountOut));
            b = b / denominator;
            //b = (uint(reserveIn).mul(2**56) / ma).mul(balanceIn) / denominator;
            c = (k.mul(2**56) / ma).mul(balanceIn);
        }
                
        if (amountOut != 0) {
            c = c / denominator;
            fee = sqrt(b.mul(b).add(c.mul(amountOut*4)));
            amountOut = (fee.sub(b).mul(denominator))/(amountOut*2);
        } else {
            amountOut = c / b;
        }
        }
        }


        // amountOut = balanceOut
        if (tokenIn < tokenOut) {
            fee = amountOut.mul(10000).mul(2**56)/(balanceIn.mul(ma));
        } else {
            fee = amountOut.mul(10000).mul(ma)/(balanceIn.mul(2**56));
        }
        fee = fee < 10000 ? 10000 - fee : 0;
        amountOut = uint(reserveOut).sub(amountOut);

        if (fee < _vars[uint(Vars.minimalFee)]) {
            fee = _vars[uint(Vars.minimalFee)];
        }
        if (fee == _vars[uint(Vars.minimalFee)] || amountIn < 1e14) {
            uint amountInWithFee = amountIn.mul(10000 - fee);
            uint numerator = amountInWithFee.mul(reserveOut);
            uint denominator = uint(reserveIn).mul(10000).add(amountInWithFee);
            amountOut = numerator / denominator;            
        }


    }

    function getAmountIn(uint amountOut, address tokenIn, address tokenOut) external view returns(uint amountIn) {
        (amountIn,) = getAmountInAndFee(amountOut, tokenIn, tokenOut);
    }

    function getAmountInAndFee(uint amountOut, address tokenIn, address tokenOut) public view returns(uint amountIn, uint fee) {
        uint32[8] memory _vars = vars;
        uint ma;
        uint112 reserveIn = reserve0;
        uint112 reserveOut = reserve1;
        uint balanceOut;
        {
        {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);        
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        uint priceBefore0 = uint(UQ112x112.encode(reserveOut).uqdiv(reserveIn));
        if (timeElapsed >= _vars[uint(Vars.periodMA)]) ma = priceBefore0;
        else ma = ((_vars[uint(Vars.periodMA)] - timeElapsed)*lastMA + priceBefore0*timeElapsed) / _vars[uint(Vars.periodMA)];
        }
        uint b;
        uint c;
        uint denominator;
        ma = ma / 2**56;
        {
        if (tokenIn < tokenOut) {
            balanceOut = uint(reserveOut).sub(amountOut);
            fee = uint(reserveIn).mul(ma) / 2**56;
            amountIn = balanceOut.mul(10000 - _vars[uint(Vars.coefficient)]) / 10000;
            amountIn = amountIn.mul(ma) / 2**56; // reuse amountIn
        } else {
            (reserveIn, reserveOut) = (reserveOut, reserveIn);
            balanceOut = uint(reserveOut).sub(amountOut);
            fee = uint(reserveIn).mul(2**56) / ma; // reuse fee
            amountIn = balanceOut.mul(10000 - _vars[uint(Vars.coefficient)]) / 10000;
            amountIn = amountIn.mul(2**56) / ma; // reuse amountIn

        }
        b = fee.mul(balanceOut).mul(20000 - _vars[uint(Vars.coefficient)]) / 10000;
        denominator = _getDenominator(b);
        b = b.add((balanceOut.mul(_vars[uint(Vars.coefficient)])/10000).mul(balanceOut));
        b = b.sub(fee.mul(reserveOut));
        b = b / denominator;

        c = fee.mul(reserveIn) / denominator;
        c = c.mul(amountOut);        
        }
        if (amountIn != 0) {
            c = c / denominator;
            fee = sqrt(b.mul(b).add(c.mul(amountIn*4)));
            amountIn = (fee.sub(b).mul(denominator))/(amountIn*2);
        } else {
            amountIn = c / b;
        }
        }
        
        {
        uint balanceIn = amountIn.add(reserveIn);
        if (tokenIn < tokenOut) {
            fee =balanceOut.mul(10000 * 2**56)/(balanceIn.mul(ma));
        } else {
            fee = balanceOut.mul(10000 * ma)/(balanceIn.mul(2**56));
        }
        fee = fee < 10000 ? 10000 - fee : 0;

        if (fee < _vars[uint(Vars.minimalFee)]) {
            fee = _vars[uint(Vars.minimalFee)];
            uint numerator = uint(reserveIn).mul(amountOut).mul(10000);
            uint denominator = uint(reserveOut).sub(amountOut).mul(10000 - fee);
            amountIn = (numerator / denominator).add(1);          
        }
        }

    }
    
    function swap(uint amount0In, uint amount1In, uint amount0Out, uint amount1Out) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'Dynamic: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'Dynamic: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        //address _token0 = token0;
        //address _token1 = token1;
        balance0 = _reserve0 + amount0In - amount0Out;
        balance1 = _reserve1 + amount1In - amount1Out;
        }
        require(amount0In > 0 || amount1In > 0, 'Dynamic: INSUFFICIENT_INPUT_AMOUNT');
        //emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out);
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint fee0;
        uint fee1;
        address _token0 = token0;
        address _token1 = token1;
        {    // avoid endless loop of fee swapping

            (fee0, fee1) = _getFeeAndDumpProtection(balance0, balance1, _reserve0, _reserve1);
            emit Fees(fee0, fee1);
            if (amount0In != 0) { 
                fee1 = amount0In.mul(fee0) / 10000; // fee by calculation
                fee0 = balance0.sub(uint(_reserve0) * uint(_reserve1) / balance1 + 1);
        emit Fees(balance0, balance1);
                require(fee0 >= fee1, "fee0 lower");
                if (_token0 == WETH) {
                    fee1 = 0;   // take fee in token0 (tokenIn)
                } else {
                    //take fee in token1 (tokenOut) by default
                    fee1 = balance1.sub(uint(_reserve0) * uint(_reserve1) / balance0 + 1);
                    fee0 = 0;
                }
            } else if (amount1In != 0) {
                fee0 = amount1In.mul(fee1) / 10000; // fee by calculation
                fee1 = balance1.sub(uint(_reserve0) * uint(_reserve1) / balance0 + 1);
                require(fee1 >= fee0, "fee1 lower");
                if (_token1 == WETH) {
                    fee0 = 0; // // take fee in token1 (tokenIn)
                } else {
                    //take fee in token0 (tokenOut) by default
                    fee0 = balance0.sub(uint(_reserve0) * uint(_reserve1) / balance1 + 1);
                    fee1 = 0;
                }
            }
        emit Fees(fee0, fee1);
        }
        //uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        //uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require((balance0.sub(fee0)).mul(balance1.sub(fee1)) >= uint(_reserve0).mul(_reserve1), 'Dynamic: K');
        emit Fees((balance0.sub(fee0)).mul(balance1.sub(fee1)), uint(_reserve0).mul(_reserve1));

        //_update(IERC20(_token0).balanceOf(address(this)), IERC20(_token1).balanceOf(address(this)), _reserve0, _reserve1);
        if (fee0 > 0) balance0 -= fee0;
        if (fee1 > 0) balance1 -= fee1;
        }
        
    }


    function _getFeeAndDumpProtection(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) public returns(uint fee0, uint fee1){
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        require(_reserve0 != 0, "_reserve0 = 0");
        require(_reserve1 != 0, "_reserve1 = 0");        
        require(balance0 != 0, "balance0 = 0");
        require(balance1 != 0, "balance1 = 0");
        uint priceBefore0 = uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0));
        uint priceAfter0 = uint(UQ112x112.encode(uint112(balance1)).uqdiv(uint112(balance0)));
        require(priceBefore0 != 0, "priceBefore0 = 0");
        require(priceAfter0 != 0, "priceAfter0 = 0");
        uint32[8] memory _vars = vars;
        {
        // check transaction dump range
        require(priceAfter0 * 10000 / priceBefore0 >= (uint(10000).sub(_vars[uint(Vars.maxTxDump0)])) &&
            priceBefore0 * 10000 / priceAfter0 >= (uint(10000).sub(_vars[uint(Vars.maxTxDump1)])),
            "Slippage out of allowed range"
        );
        // check time frame dump range
        uint _baseLinePrice0 = baseLinePrice0;
        if (blockTimestamp/_vars[uint(Vars.timeFrame)] != blockTimestampLast/_vars[uint(Vars.timeFrame)]) {   //new time frame 
            _baseLinePrice0 = priceBefore0; // uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0));
            baseLinePrice0 = _baseLinePrice0;
        }
        if (_baseLinePrice0 !=0)
            require(priceAfter0 * 10000 / _baseLinePrice0 >= (uint(10000).sub(_vars[uint(Vars.maxDump0)])) &&
                _baseLinePrice0 * 10000 / priceAfter0 >= (uint(10000).sub(_vars[uint(Vars.maxDump1)])),
                "Slippage out of time frame allowed range"
            );
        }
        {        
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        uint ma;
        // ma = ((periodMA - timeElapsed)*lastMA + lastPrice*timeElapsed) / periodMA
        if (timeElapsed >= _vars[uint(Vars.periodMA)]) ma = priceBefore0;
        else ma = ((_vars[uint(Vars.periodMA)] - timeElapsed)*lastMA + priceBefore0*timeElapsed) / _vars[uint(Vars.periodMA)];
        lastMA = ma;
        fee0 = priceAfter0 * 10000 / ma;
        
        /*if (fee0 < 10000) {    // sell token0
            fee0 = (10000 - fee0 - 1) * _vars[uint(Vars.coefficient)] / 10000;
            if (fee0 < _vars[uint(Vars.minimalFee)]) fee0 = _vars[uint(Vars.minimalFee)];
            fee1 = _vars[uint(Vars.minimalFee)];   // minimalFee when price drop
        } else {    // sell token1
            // fee1 = 10000*10000 / fee0
            fee1 = uint(10000).sub(100000000 / fee0) * _vars[uint(Vars.coefficient)] / 10000;
            if (fee1 < _vars[uint(Vars.minimalFee)]) fee1 = _vars[uint(Vars.minimalFee)];
            fee0 = _vars[uint(Vars.minimalFee)];   // minimalFee when price drop
        }*/
        // fee should be less by 1
        if (fee0 == 10000) fee0--;
        fee1 = fee0 > 10000 ? (9999 - 100000000 / fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        fee0 = fee0 < 10000 ? (9999 - fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        if (fee1 < _vars[uint(Vars.minimalFee)]) fee1 = _vars[uint(Vars.minimalFee)];
        if (fee0 < _vars[uint(Vars.minimalFee)]) fee0 = _vars[uint(Vars.minimalFee)];
        }
    }

    function _getFee(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) public view returns(uint fee0, uint fee1){
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        require(_reserve0 != 0, "_reserve0 = 0");
        require(_reserve1 != 0, "_reserve1 = 0");        
        require(balance0 != 0, "balance0 = 0");
        require(balance1 != 0, "balance1 = 0");
        uint priceBefore0 = uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0));
        uint priceAfter0 = uint(UQ112x112.encode(uint112(balance1)).uqdiv(uint112(balance0)));
        require(priceBefore0 != 0, "priceBefore0 = 0");
        require(priceAfter0 != 0, "priceAfter0 = 0");
        uint32[8] memory _vars = vars;

        {        
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        uint ma;
        // ma = ((periodMA - timeElapsed)*lastMA + lastPrice*timeElapsed) / periodMA
        if (timeElapsed >= _vars[uint(Vars.periodMA)]) ma = priceBefore0;
        else ma = ((_vars[uint(Vars.periodMA)] - timeElapsed)*lastMA + priceBefore0*timeElapsed) / _vars[uint(Vars.periodMA)];
        fee0 = priceAfter0 * 10000 / ma;
        
        // fee should be less by 1
        fee1 = fee0 > 10000 ? (9999 - 100000000 / fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        fee0 = fee0 < 10000 ? (9999 - fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        if (fee1 < _vars[uint(Vars.minimalFee)]) fee1 = _vars[uint(Vars.minimalFee)];
        if (fee0 < _vars[uint(Vars.minimalFee)]) fee0 = _vars[uint(Vars.minimalFee)];
        }
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}








// SPDX-License-Identifier: No License (None)
pragma solidity ^0.6.0;

/**
 * @title SafeMath
 * @dev Math operations with safety checks that throw on error
 */
library SafeMath {
  function mul(uint a, uint b) internal pure returns (uint) {
    if (a == 0) {
      return 0;
    }
    uint c = a * b;
    require(c / a == b);
    return c;
  }

  function div(uint a, uint b) internal pure returns (uint) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    uint c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold
    return c;
  }

  function sub(uint a, uint b) internal pure returns (uint) {
    require(b <= a);
    return a - b;
  }

  function add(uint a, uint b) internal pure returns (uint) {
    uint c = a + b;
    require(c >= a);
    return c;
  }
}

contract ColdStaking {
    
    // NOTE: The contract only works for intervals of time > round_interval

    using SafeMath for uint;

    event StartStaking(address addr, uint value, uint amount, uint time, uint end_time);
    event WithdrawStake(address staker, uint amount);
    event Claim(address staker, uint reward);
    event DonationDeposited(address _address, uint value);

    struct Staker
    {
        uint amount;
        uint time;              // Staking start time or last claim rewards
        uint multiplier;        // Rewards multiplier = 0.40 + (0.05 * rounds). [0.45..1] (max rounds 12)
        uint end_time;          // Time when staking ends and user may withdraw. After this time user will not receive rewards.
    }


    uint public LastBlock = block.number;
    uint public Timestamp = now;    //timestamp of the last interaction with the contract.

    uint public TotalStakingWeight; //total weight = sum (each_staking_amount * each_staking_time).
    uint public TotalStakingAmount; //currently frozen amount for Staking.
    uint public StakingRewardPool;  //available amount for paying rewards.
    uint public staking_threshold = 0 ether;

    uint public constant round_interval   = 27 days;     // 1 month.
    uint public constant max_delay        = 365 days;    // 1 year after staking ends.
    uint public constant BlockStartStaking = 7600000;

    uint constant NOMINATOR = 10**18;           // Nominator / denominator used for float point numbers

    address public constant SOY = 0x9FaE2529863bD691B4A7171bDfCf33C7ebB10a65;
    address public constant globalFarm = 0x64Fa36ACD0d13472FD786B03afC9C52aD5FCf023;
    uint public stake_until = 1662033600; // 1 September 2022 12:00:00 GMT (all staking should be finished until this time)
    address public admin;   // admin address who can set stake_until

    //========== TESTNET VALUES ===========
    //uint public constant round_interval   = 1 hours; 
    //uint public constant max_delay        = 2 days;
    //uint public constant BlockStartStaking = 0;
    //========== END TEST VALUES ==========
    
    mapping(address => Staker) public staker;

    modifier reward_request
    {
        if(ISimplifiedGlobalFarm(globalFarm).rewardMintingAvailable(address(this)))
        {
            ISimplifiedGlobalFarm(globalFarm).mintFarmingReward(address(this));
        }
        _;
    }

    constructor() public {
        admin = msg.sender;
    }

    function setStakeUntil(uint newDate) external {
        require(admin == msg.sender, "Only admin");
        stake_until = newDate;
    }

    // ERC223 token transfer callback
    // bytes _data = abi.encode(address receiver, uint256 toChainId)
    function tokenReceived(address _from, uint _value, bytes calldata _data) external {
        require(msg.sender == SOY, "Only SOY");
        if (_from != globalFarm) {
            // No donations accepted to fallback!
            // Consider value deposit is an attempt to become staker.
            // May not accept deposit from other contracts due GAS limit.
            // by default stake for 1 round
            uint rounds;
            if (_data.length >= 32) {
                rounds = abi.decode(_data, (uint256));  // _data should contain ABI encoded UINT =  number of rounds
            }
            if (rounds == 0) rounds = 1;
            start_staking(_from, _value, rounds);
        }
    }

    // Update reward variables of this Local Farm to be up-to-date.
    function update() public reward_request {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = lpToken.balanceOf(address(this));
       
        if (lpSupply == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 multiplier = block.timestamp - lastRewardTimestamp;
        
        // This silently calculates "assumed" reward!
        // This function does not take contract's actual balance into account
        // Global Farm and `reward_request` modifier are responsible for keeping this contract
        // stocked with funds to pay actual rewards.
        
        uint256 _reward = multiplier * getRewardPerSecond() * getAllocationX1000() / 1000;
        accumulatedRewardPerShare = accumulatedRewardPerShare + (_reward * 1e18 / lpSupply);
        lastRewardTimestamp = block.timestamp;
    }

    // update TotalStakingAmount value.
    function new_block() internal
    {
        if (block.number > LastBlock)   //run once per block.
        {
            uint _LastBlock = LastBlock;
            LastBlock = block.number;

            StakingRewardPool = address(this).balance.sub(TotalStakingAmount + msg.value);   //fix rewards pool for this block.
            // msg.value here for case new_block() is calling from start_staking(), and msg.value will be added to CurrentBlockDeposits.

            //The consensus protocol enforces block timestamps are always at least +1 from their parent, so a node cannot "lie into the past". 
            if (now > Timestamp) //But with this condition I feel safer :) May be removed.
            {
                uint _blocks = block.number - _LastBlock;
                uint _seconds = now - Timestamp;
                if (_seconds > _blocks * 25) //if time goes far in the future, then use new time as 25 second * blocks.
                {
                    _seconds = _blocks * 25;
                }
                TotalStakingWeight += _seconds.mul(TotalStakingAmount);
                Timestamp += _seconds;
            }
        }
    }

    function start_staking() external payable {
        // by default stake for 1 round
        start_staking(1);
    }

    function start_staking(uint rounds) public staking_available payable
    {
        assert(msg.value >= staking_threshold);
        require(rounds > 0);
        new_block(); //run once per block.
        // to reduce gas cost we will use local variable instead of global
        uint _Timestamp = Timestamp;
        uint staker_amount = staker[msg.sender].amount;
        uint r = rounds;
        if (r > 12) r = 12;
        uint multiplier = (40 + (5 * r)) * NOMINATOR / 100;  // staker multiplier = 0.40 + (0.05 * rounds). [0.45..1]
        uint end_time = _Timestamp.add(round_interval.mul(rounds));
        // claim reward if available.
        if (staker_amount > 0)
        {
            if (_Timestamp >= staker[msg.sender].time + round_interval)
            { 
                _claim(msg.sender); 
            }
            uint staker_end_time = staker[msg.sender].end_time;
            if (staker_end_time > end_time) {
                end_time = staker_end_time;     // Staking end time is the bigger from previous and new one.
                r = (end_time.sub(_Timestamp)).div(round_interval);  // update number of rounds
                if (r > 12) r = 12;
                multiplier = (40 + (5 * r)) * NOMINATOR / 100;  // staker multiplier = 0.40 + (0.05 * rounds). [0.45..1]
            }
            // if there is active staking with bigger multiplier
            if (staker[msg.sender].multiplier > multiplier && staker_end_time > _Timestamp) {
                // recalculate multiplier = (staker.multiplier * staker.amount + new.multiplier * new.amount) / ( staker.amount + new.amount)
                multiplier = ((staker[msg.sender].multiplier.mul(staker_amount)).add(multiplier.mul(msg.value))).div(staker_amount.add(msg.value));
                if (multiplier > NOMINATOR) multiplier = NOMINATOR; // multiplier can't be more then 1
            }
            TotalStakingWeight = TotalStakingWeight.sub((_Timestamp.sub(staker[msg.sender].time)).mul(staker_amount)); // remove from Weight
        }

        TotalStakingAmount = TotalStakingAmount.add(msg.value);
        staker[msg.sender].time = _Timestamp;
        staker[msg.sender].amount = staker_amount.add(msg.value);
        staker[msg.sender].multiplier = multiplier;
        staker[msg.sender].end_time = end_time;

        emit StartStaking(
            msg.sender,
            msg.value,
            staker[msg.sender].amount,
            _Timestamp,
            end_time
        );
    }

    function DEBUG_donation() external payable {
        emit DonationDeposited(msg.sender, msg.value);
    }

    function withdraw_stake() external {
        _withdraw_stake(msg.sender);
    }

    function withdraw_stake(address payable user) external {
        _withdraw_stake(user);
    }

    function _withdraw_stake(address payable user) internal
    {
        new_block(); //run once per block.
        require(Timestamp >= staker[user].end_time); //reject withdrawal before end time.

        uint _amount = staker[user].amount;
        require(_amount != 0);
        // claim reward if available.
        _claim(user); 
        TotalStakingAmount = TotalStakingAmount.sub(_amount);
        TotalStakingWeight = TotalStakingWeight.sub((Timestamp.sub(staker[user].time)).mul(staker[user].amount)); // remove from Weight.
        
        staker[user].amount = 0;
        user.transfer(_amount);
        emit WithdrawStake(user, _amount);
    }

    //claim rewards
    function claim() external only_staker
    {
        _claim(msg.sender);
    }


    function _claim(address payable user) internal
    {
        new_block(); //run once per block
        // to reduce gas cost we will use local variable instead of global
        uint _Timestamp = Timestamp;
        if (_Timestamp > staker[user].end_time) _Timestamp = staker[user].end_time; // rewards calculates until staking ends
        uint _StakingInterval = _Timestamp.sub(staker[user].time);  //time interval of deposit.
        if (_StakingInterval >= round_interval)
        {
            uint _CompleteRoundsInterval = (_StakingInterval / round_interval).mul(round_interval); //only complete rounds.
            uint _StakerWeight = _CompleteRoundsInterval.mul(staker[user].amount); //Weight of completed rounds.
            uint _reward = StakingRewardPool.mul(_StakerWeight).div(TotalStakingWeight);  //StakingRewardPool * _StakerWeight/TotalStakingWeight
            _reward = _reward.mul(staker[user].multiplier) / NOMINATOR;   // reduce rewards if staked on less then 12 rounds.
            StakingRewardPool = StakingRewardPool.sub(_reward);
            TotalStakingWeight = TotalStakingWeight.sub(_StakerWeight); // remove paid Weight.

            staker[user].time = staker[user].time.add(_CompleteRoundsInterval); // reset to paid time, staking continue without a loss of incomplete rounds.
	    
            user.transfer(_reward);
            emit Claim(user, _reward);
        }
    }

    //This function may be used for info only. This can show estimated user reward at current time.
    function stake_reward(address _addr) external view returns (uint _reward)
    {
        require(staker[_addr].amount > 0);

        uint _blocks = block.number - LastBlock;
        uint _seconds = now - Timestamp;
        if (_seconds > _blocks * 25) //if time goes far in the future, then use new time as 25 second * blocks.
        {
            _seconds = _blocks * 25;
        }
        uint _Timestamp = Timestamp + _seconds;
        if (_Timestamp > staker[_addr].end_time) _Timestamp = staker[_addr].end_time; // rewards calculates until staking ends
        uint _TotalStakingWeight = TotalStakingWeight + _seconds.mul(TotalStakingAmount);
        uint _StakingInterval = _Timestamp.sub(staker[_addr].time); //time interval of deposit.
	
        //uint _StakerWeight = _StakingInterval.mul(staker[_addr].amount); //Staker weight.
        uint _CompleteRoundsInterval = (_StakingInterval / round_interval).mul(round_interval); //only complete rounds.
        uint _StakerWeight = _CompleteRoundsInterval.mul(staker[_addr].amount); //Weight of completed rounds.
        uint _StakingRewardPool = address(this).balance.sub(TotalStakingAmount);
        _reward = _StakingRewardPool.mul(_StakerWeight).div(_TotalStakingWeight);  //StakingRewardPool * _StakerWeight/TotalStakingWeight
        _reward = _reward.mul(staker[_addr].multiplier) / NOMINATOR;   // reduce rewards if staked on less then 12 rounds.
    }

    modifier only_staker
    {
        require(staker[msg.sender].amount > 0);
        _;
    }

    modifier staking_available
    {
        require(block.number >= BlockStartStaking);
        _;
    }

    //return deposit to inactive staker after 1 year when staking ends.
    function report_abuse(address payable _addr) public only_staker
    {
        require(staker[_addr].amount > 0);
        new_block(); //run once per block.
        require(Timestamp > staker[_addr].end_time.add(max_delay));
        
        uint _amount = staker[_addr].amount;
        
        TotalStakingAmount = TotalStakingAmount.sub(_amount);
        TotalStakingWeight = TotalStakingWeight.sub((Timestamp.sub(staker[_addr].time)).mul(_amount)); // remove from Weight.

        staker[_addr].amount = 0;
        _addr.transfer(_amount);
    }
}
