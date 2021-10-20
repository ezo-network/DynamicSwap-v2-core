pragma solidity =0.5.16;

import './interfaces/IBSwapV2Router02.sol';
import './interfaces/IBSwapV2Factory.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './libraries/Clones.sol';
import './interfaces/IBSwapV2Pair.sol';
//import './BSwapV2Pair.sol';

interface IReimbursement {
    // returns fee percentage with 2 decimals
    function getLicenseeFee(address vault, address projectContract) external view returns(uint256);
    // returns fee receiver address or address(0) if need to refund fee to user.
    function requestReimbursement(address user, uint256 feeAmount, address vault) external returns(address);
}

contract BswapV2Factory is IBSwapV2Factory {
    enum Vars {timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodMA}
    uint32[8] public vars; // timeFrame, maxDump0, maxDump1, maxTxDump0, maxTxDump1, coefficient, minimalFee, periodMA
    //timeFrame = 1 days;  // during this time frame rate of reserve1/reserve0 should be in range [baseLinePrice0*(1-maxDump0), baseLinePrice0*(1+maxDump1)]
    //maxDump0 = 100;   // maximum allowed dump (in percentage) of reserve1/reserve0 rate during time frame relatively the baseline
    //maxDump1 = 100;   // maximum allowed dump (in percentage) of reserve0/reserve1 rate during time frame relatively the baseline
    //maxTxDump0 = 100; // maximum allowed dump (in percentage) of token0 price per transaction
    //maxTxDump1 = 100; // maximum allowed dump (in percentage) of token1 price per transaction
    //coefficient = 100; // coefficient (in percentage) to transform price growing into fee. ie
    //minimalFee = 1;   // Minimal fee percentage (with 1 decimals) applied to transaction. I.e. 1 = 0.1%
    //periodMA = 45 minutes;  // MA period in seconds
    address public bswap;   // bSwap token address
    address public uniV2Router; // uniswap compatible router
    address public reimbursement; // address of users reimbursements contract
    address public reimbursementVault;  // address of company vault for reimbursements
    address public pairImplementation;  // pair implementation code contract (using in clone).
    address public feeTo;
    uint256 public feeToPart = 20; // company part of charged fee (in percentage). I.e. send to `feeTo` amount of (charged fee * feeToPart / 100)
    address public feeToSetter;
    bool public defaultCircuitBreakerEnable = true; // protect from dumping token against WETH

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    mapping(address => bool) isPair;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter, address _pairImplementation) public {
        require(_feeToSetter != address(0) && _pairImplementation != address(0), "Address zero");
        feeToSetter = _feeToSetter;
        pairImplementation = _pairImplementation;
        vars = [1 days, 100, 100, 100, 100, 100, 1, 45 minutes];
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        uint8 circuitBreaker;
        if (defaultCircuitBreakerEnable) circuitBreaker = 3;
        return _createPair(tokenA, tokenB, circuitBreaker);
    }

    // circuitBreaker:
    // 0 - disable
    // 1 - protect from dumping token A
    // 2 - protect from dumping token B
    // 3 - protect from dumping token against WETH
    function createPair(address tokenA, address tokenB, uint8 circuitBreaker) external returns (address pair) {
        require(circuitBreaker < 4, "Wrong circuitBreaker");
        return _createPair(tokenA, tokenB, circuitBreaker+4);
    }
    
    function createPrivatePair(address tokenA, address tokenB, uint8 circuitBreaker) external returns (address pair) {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        require(circuitBreaker < 4, "Wrong circuitBreaker");
        return _createPair(tokenA, tokenB, circuitBreaker+4);
    }

    function _createPair(address tokenA, address tokenB, uint8 circuitBreaker) internal returns (address pair) {
        require(tokenA != tokenB, 'BSwapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'BSwapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'BSwapV2: PAIR_EXISTS'); // single check is sufficient
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        /*
        bytes memory bytecode = type(BSwapV2Pair).creationCode;
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        */
        uint32[8] memory _vars = vars;
        address WETH = IBSwapV2Router02(uniV2Router).WETH();
        uint8 isPrivate;
        if (circuitBreaker > 3) isPrivate = 1;
        if ((circuitBreaker == 3 && token0 == WETH) || circuitBreaker == 2) {
            _vars[uint(Vars.maxDump1)] = 10;    // 10% allowed dump during the time frame
            _vars[uint(Vars.maxTxDump1)] = 0;    // 0% allowed dump in single transaction
        } else if ((circuitBreaker == 3 && token1 == WETH) || circuitBreaker == 1) {
            _vars[uint(Vars.maxDump0)] = 10;    // 10% allowed dump during the time frame
            _vars[uint(Vars.maxTxDump0)] = 0;    // 0% allowed dump in single transaction
        }

        pair = Clones.cloneDeterministic(pairImplementation, salt);
        IBSwapV2Pair(pair).initialize(token0, token1, _vars, isPrivate);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        isPair[pair] = true;
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    // mint bswap tokens for LP
    function mintReward(address to, uint amount) external {
        require(isPair[msg.sender], "Only pair");
        //return; // TEST
        IERC20(bswap).mint(to, amount);
    }

    function swapFee(address token0, address token1, uint fee0, uint fee1) external returns(bool) {
        //return false; // TEST
        uint gasA = gasleft();
        require(isPair[msg.sender], "Only pair");
        address WETH = IBSwapV2Router02(uniV2Router).WETH();
        address _bswap = bswap;
        address _bSwapPair = getPair[_bswap][WETH];
        if (_bSwapPair == address(0)) return false;
        address _factory = IBSwapV2Router02(uniV2Router).factory();
        uint amount;
        uint fee;
        if (fee0 != 0) amount = _swapFee(_factory, WETH, token0, fee0);
        if (fee1 != 0) amount += _swapFee(_factory, WETH, token1, fee1);
        if (amount == 0) {
            if (reimbursement != address(0)) {
                fee = ((73000 + gasA - gasleft()) * tx.gasprice); // add gas for swap
                IReimbursement(reimbursement).requestReimbursement(tx.origin, fee, reimbursementVault);      // user reimbursement
            }
            return false;
        }
        (uint112 _reserve0, uint112 _reserve1,) = IBSwapV2Pair(_bSwapPair).getReserves();
        if (WETH > _bswap) {
            (_reserve0, _reserve1) = (_reserve1, _reserve0);    // WETH amount = _reserve0
        }
        fee = amount;
        amount = (100 - feeToPart) * amount / 100; // amount in WETH to move to pool
        //_safeTransfer(WETH, _bSwapPair, amount);    // add fee to bswap pool on one side
        //IBSwapV2Pair(_bSwapPair).sync();    // sync in pair
        amount = (amount * _reserve1) / (_reserve0 + amount);
        IBSwapV2Pair(msg.sender).addReward(amount); // amount in bswap
        if (reimbursement != address(0)) {
            fee = fee + ((73000 + gasA - gasleft()) * tx.gasprice); // add gas for swap
            IReimbursement(reimbursement).requestReimbursement(tx.origin, fee, reimbursementVault);      // user reimbursement
        }
        return true;
    }

    function _swapFee(address _factory, address WETH, address _token, uint _feeAmount) internal returns(uint amountOut) {
        if (_token == WETH) {
            _safeTransferFrom(_token, msg.sender, address(this), _feeAmount);
            return _feeAmount;
        }
        address _pair = IBSwapV2Factory(_factory).getPair(_token, WETH);
        if (_pair == address(0)) return 0;  // no pair token-WETH
        (uint112 _reserve0, uint112 _reserve1,) = IBSwapV2Pair(_pair).getReserves();
        _safeTransferFrom(_token, msg.sender, _pair, _feeAmount);
        uint amountInput = IERC20(_token).balanceOf(address(_pair));
        if (_token < WETH) {
            if (amountInput < _reserve0)
                return 0;
            else
                amountInput -=_reserve0;
            amountOut = IBSwapV2Router02(uniV2Router).getAmountOut(amountInput, _reserve0, _reserve1);
            IBSwapV2Pair(_pair).swap(0, amountOut, address(this), new bytes(0));
        } else {
            if (amountInput < _reserve1)
                return 0;
            else
                amountInput -= _reserve1;
            amountOut = IBSwapV2Router02(uniV2Router).getAmountOut(amountInput, _reserve1, _reserve0);
            IBSwapV2Pair(_pair).swap(amountOut, 0, address(this), new bytes(0));
        }
    }

    function _safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FAILED');
    }

    function _safeTransferFrom(address token, address from, address to, uint value) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'TransferHelper: TRANSFER_FROM_FAILED');
    }

    function setVars(uint varId, uint32 value) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        require(varId <= vars.length, "Wrong varID");
        if (varId == uint(Vars.timeFrame) || varId == uint(Vars.periodMA))
            require(value != 0, "Wrong time frame");
        else
            require(value <= 100, "Wrong percentage");
        if (varId < vars.length) {
            vars[varId] = value;
            return;
        }
        if (varId == vars.length) {
            feeToPart = value;    // varId = 8
        }
    }

    // set Router contract address
    function setRouter(address _router) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        require(_router != address(0), "Address zero");
        uniV2Router = _router;
    }

    // set bSwap token address
    function setBSwap(address _bswap) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        require(_bswap != address(0), "Address zero");
        bswap = _bswap;
    }

    // set reimbursement contract address for users reimbursements, address(0) to switch of reimbursement
    function setReimbursementContractAndVault(address _reimbursement, address _vault) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        reimbursement = _reimbursement;
        reimbursementVault = _vault;
    }

    function setDefaultCircuitBreaker(bool enable) external {
        require(msg.sender == feeToSetter, 'BSwapV2: FORBIDDEN');
        defaultCircuitBreakerEnable = enable;
    }

    function withdrawFees() external {
        require(msg.sender == feeTo, 'BSwapV2: FORBIDDEN');
        address WETH = IBSwapV2Router02(uniV2Router).WETH();
        uint balance = IERC20(WETH).balanceOf(address(this));
        if (balance != 0) {
            IWETH(WETH).withdraw(balance);
            msg.sender.transfer(address(this).balance);
            //_safeTransfer(WETH, msg.sender, balance);
        }
    }

    function () external payable {}
}
