pragma solidity =0.5.16;

import './interfaces/IDynamicPair.sol';
import './DynamicVoting.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IDynamicFactory.sol';
import './interfaces/IDynamicCallee.sol';

// This contract is implementation of code for pair.
contract DynamicPair is IDynamicPair, DynamicVoting {
    using SafeMath  for uint;
    using UQ112x112 for uint224;
    
    enum Vars {timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodMA}
    uint32[8] public vars; // timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodM
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
    address public token0;
    address public token1;
    uint8 public isPrivate;  // in private pool only LP holder (creator) can add more liquidity

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

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
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event AddReward(uint reward);

    /*
    constructor() public {
        factory = msg.sender;
    }
    */

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1, uint32[8] calldata _vars, uint8 _isPrivate) external {
        require(address(0) == factory, 'Dynamic: FORBIDDEN'); // sufficient check
        unlocked = 1;
        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        vars = _vars;
        isPrivate = _isPrivate;
        super.initialize();
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
            fee =amountOut.mul(10000).mul(ma)/(balanceIn.mul(2**56));
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
            fee = balanceOut.mul(10000 * 2**56)/(balanceIn.mul(ma));
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
    
    function _getFeeAndDumpProtection(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private returns(uint fee0, uint fee1){
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
        // ma = ((periodMA - timeElapsed)*lastMA + lastPrice*timeElapsed) / periodMA
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        uint ma;
        if (timeElapsed >= _vars[uint(Vars.periodMA)]) ma = priceBefore0;
        else ma = ((_vars[uint(Vars.periodMA)] - timeElapsed)*lastMA + priceBefore0*timeElapsed) / _vars[uint(Vars.periodMA)];
        lastMA = ma;
        fee0 = priceAfter0 * 10000 / ma;
        
        // fee should be less than 1
        if (fee0 == 10000) fee0--;
        fee1 = fee0 > 10000 ? (9999 - 100000000 / fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        fee0 = fee0 < 10000 ? (9999 - fee0) * _vars[uint(Vars.coefficient)] / 10000 : _vars[uint(Vars.minimalFee)];
        if (fee1 < _vars[uint(Vars.minimalFee)]) fee1 = _vars[uint(Vars.minimalFee)];
        if (fee0 < _vars[uint(Vars.minimalFee)]) fee0 = _vars[uint(Vars.minimalFee)];
        }
    }

    function _getDenominator(uint v) internal pure returns(uint denominator) {
        if (v>1e54) denominator = 1e27;
        else if (v>1e36) denominator = 1e18;
        else denominator = 1e9;
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

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'Dynamic: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }
/*
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IDynamicFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }
*/
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        //bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            uint priceBefore0 = uint(UQ112x112.encode(uint112(balance1)).uqdiv(uint112(balance0)));
            lastMA = priceBefore0;
            baseLinePrice0 = priceBefore0;
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            require(isPrivate != 1 || balanceOf[to] != 0, "Private pool");
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'Dynamic: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        //if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        //bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'Dynamic: INSUFFICIENT_LIQUIDITY_BURNED');
        uint rewardAmount = _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        IDynamicFactory(factory).mintReward(to, rewardAmount);

        _update(balance0, balance1, _reserve0, _reserve1);
        //if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'Dynamic: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'Dynamic: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'Dynamic: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IDynamicCallee(to).DynamicCall(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'Dynamic: INSUFFICIENT_INPUT_AMOUNT');
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint fee0;
        uint fee1;
        address _token0 = token0;
        address _token1 = token1;
        if (to != factory) {    // avoid endless loop of fee swapping
            (fee0, fee1) = _getFeeAndDumpProtection(balance0, balance1, _reserve0, _reserve1);
            if (amount0In != 0) { 
                fee1 = amount0In.mul(fee0) / 10000; // fee by calculation
                fee0 = balance0.sub(uint(_reserve0) * uint(_reserve1) / balance1 + 1);
                require(fee0 >= fee1, "fee0 lower");
                if (_token0 == IDynamicFactory(factory).WETH()) {
                    fee1 = 0; // take fee in token0 (tokenIn)
                } else {
                    //take fee in token1 (tokenOut) by default
                    fee1 = balance1.sub(uint(_reserve0) * uint(_reserve1) / balance0 + 1);
                    fee0 = 0;
                }
            } else if (amount1In != 0) {
                fee0 = amount1In.mul(fee1) / 10000; // fee by calculation
                fee1 = balance1.sub(uint(_reserve0) * uint(_reserve1) / balance0 + 1);
                require(fee1 >= fee0, "fee1 lower");
                if (_token1 == IDynamicFactory(factory).WETH()) {
                    fee0 = 0; // take fee in token1 (tokenIn)
                } else {
                    //take fee in token0 (tokenOut) by default
                    fee0 = balance0.sub(uint(_reserve0) * uint(_reserve1) / balance1 + 1);
                    fee1 = 0;
                } 
            }
            if (fee0 > 0) IERC20(_token0).approve(factory, fee0);
            if (fee1 > 0) IERC20(_token1).approve(factory, fee1);
            IDynamicFactory(factory).swapFee(_token0, _token1, fee0, fee1);
        }
        //uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        //uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require((balance0.sub(fee0)).mul(balance1.sub(fee1)) >= uint(_reserve0).mul(_reserve1), 'Dynamic: K');
        //_update(IERC20(_token0).balanceOf(address(this)), IERC20(_token1).balanceOf(address(this)), _reserve0, _reserve1);
        if (fee0 > 0) balance0 = IERC20(_token0).balanceOf(address(this));
        if (fee1 > 0) balance1 = IERC20(_token1).balanceOf(address(this));
        }
        _update(balance0, balance1, _reserve0, _reserve1);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    // add reward tokens into the reward pool (only by factory)
    function addReward(uint amount) external {
        require(msg.sender == factory, "Only factory");
        rewardTokens = rewardTokens.add(amount);
        emit AddReward(amount);
    }

    function setVars(uint varId, uint32 value) external onlyVoting {
        require(varId < vars.length, "Wrong varID");
        if (varId == uint(Vars.timeFrame) || varId == uint(Vars.periodMA))
            require(value != 0, "Wrong time frame");
        else
            require(value <= 10000, "Wrong percentage");
        vars[varId] = value;
    }

    // private/public pool switching (just for pools )
    function switchPool(uint toPublic) external onlyVoting {
        require(isPrivate != 0, "Pool can't be switched");
        if(toPublic == 1 && isPrivate == 1) isPrivate = 2;  // switch pool to public mode (anybody can add liquidity)
        if(toPublic == 0 && isPrivate == 2) isPrivate = 1;  // switch pool to private mode (nobody, except LP holders, can add liquidity)
    }
}
