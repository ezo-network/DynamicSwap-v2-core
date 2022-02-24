pragma solidity >=0.5.0;

interface IDynamicFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function dynamic() external view returns (address);
    function WETH() external view returns (address);
    function uniV2Router() external view returns (address);
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    //function setFeeTo(address) external;
    function setFeeToSetter(address) external;

    function mintReward(address to, uint amount) external;
    function swapFee(address token0, address token1, uint fee0, uint fee1) external returns(bool);
    function setVars(uint varId, uint32 value) external;
    function setRouter(address _router) external;
    function setReimbursementContractAndVault(address _reimbursement, address _vault) external;
    function claimFee() external returns (uint256);
    function getColletedFees() external view returns (uint256 feeAmount);
}
