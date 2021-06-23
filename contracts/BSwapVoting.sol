pragma solidity =0.5.16;

import './UniswapV2ERC20.sol';


contract BSwapVoting is UniswapV2ERC20 {
    uint256 public votingTime = 1 days;   // duration of voting
    uint256 public minimalLevel = 10; // user who has this percentage of token can suggest change
    
    uint256 public ballotIds;
    uint256 public rulesIds;
    
    enum Vote {None, Yea, Nay}
    enum Status {New , Executed}

    struct Rule {
        //address contr;      // contract address which have to be triggered
        uint32 majority;  // require more than this percentage of participants voting power (in according tokens).
        string funcAbi;     // function ABI (ex. "transfer(address,uint256)")
    }

    struct Ballot {
        uint256 closeVote; // timestamp when vote will close
        uint256 ruleId; // rule which edit
        bytes args; // ABI encoded arguments for proposal which is required to call appropriate function
        Status status;
        address creator;    // wallet address of ballot creator.
        uint256 yea;  // YEA votes according communities (tokens)
        uint256 totalVotes;  // The total voting power od all participant according communities (tokens)
    }
    
    mapping(address => mapping(uint256 => bool)) public voted;
    mapping(uint256 => Ballot) public ballots;
    mapping(uint256 => Rule) public rules;
    //event AddRule(address indexed contractAddress, string funcAbi, uint32 majorMain);
    event ApplyBallot(uint256 indexed ruleId, uint256 indexed ballotId);
    event BallotCreated(uint256 indexed ruleId, uint256 indexed ballotId);
    
    modifier onlyVoting() {
        require(address(this) == msg.sender, "Only voting");
        _;        
    }

    constructor() public {
        rules[0] = Rule(75,"setVotingDuration(uint256)");
        rules[1] = Rule(75,"setMinimalLevel(uint256)");
        rules[2] = Rule(75,"setVars(uint256,uint32)");
        rules[3] = Rule(75,"switchPool(uint256)");
        rulesIds = 3;
    }
    
    /**
     * @dev Add new rule - function that call target contract to change setting.
        * @param contr The contract address which have to be triggered
        * @param majority The majority level (%) for the tokens 
        * @param funcAbi The function ABI (ex. "transfer(address,uint256)")
     */
     /*
    function addRule(
        address contr,
        uint32  majority,
        string memory funcAbi
    ) external onlyOwner {
        require(contr != address(0), "Zero address");
        rulesIds +=1;
        rules[rulesIds] = Rule(contr, majority, funcAbi);
        emit AddRule(contr, funcAbi, majority);
    }
    */

    /**
     * @dev Set voting duration
     * @param time duration in seconds
    */
    function setVotingDuration(uint256 time) external onlyVoting {
        require(time > 600);
        votingTime = time;
    }
    
    /**
     * @dev Set minimal level to create proposal
     * @param level in percentage. I.e. 10 = 10%
    */
    function setMinimalLevel(uint256 level) external onlyVoting {
        require(level >= 1 && level <= 51);    // not less then 1% and not more then 51%
        minimalLevel = level;
    }
    
    /**
     * @dev Get rules details.
     * @param ruleId The rules index
     * @return contr The contract address
     * @return majority The level of majority in according tokens
     * @return funcAbi The function Abi (ex. "transfer(address,uint256)")
    */
    function getRule(uint256 ruleId) external view returns(uint32 majority, string memory funcAbi) {
        Rule storage r = rules[ruleId];
        return (r.majority, r.funcAbi);
    }
    
    function _checkMajority(uint32 majority, uint256 _ballotId) internal view returns(bool){
        Ballot storage b = ballots[_ballotId];
        if (b.yea * 2 > totalSupply) {
            return true;
        }
        if((b.totalVotes - b.yea) * 2 > totalSupply){
            return false;
        }
        if (block.timestamp >= b.closeVote && b.yea > b.totalVotes * majority / 100) {
            return true;
        }
        return false;
    }

    function vote(uint256 _ballotId, bool yea) external returns (bool){
        require(_ballotId <= ballotIds, "Wrong ballot ID");
        require(!voted[msg.sender][_ballotId], "already voted");
        
        Ballot storage b = ballots[_ballotId];
        uint256 closeVote = b.closeVote;
        require(closeVote > block.timestamp, "voting closed");
        uint256 power = balanceOf[msg.sender];
        
        if(yea){
            b.yea += power;    
        }
        b.totalVotes += power;
        voted[msg.sender][_ballotId] = true;
        if(_checkMajority(rules[b.ruleId].majority, _ballotId)) {
            _executeBallot(_ballotId);
        }
        return true;
    }
    

    function createBallot(uint256 ruleId, bytes calldata args) external {
        require(ruleId <= rulesIds, "Wrong rule ID");
        Rule storage r = rules[ruleId];
        uint256 power = balanceOf[msg.sender];
        require(power >= totalSupply * minimalLevel / 100, "require minimal Level to suggest change");
        uint256 closeVote = block.timestamp + votingTime;
        ballotIds += 1;
        Ballot storage b = ballots[ballotIds];
        b.ruleId = ruleId;
        b.args = args;
        b.creator = msg.sender;
        b.yea = power;
        b.totalVotes = power;
        b.closeVote = closeVote;
        b.status = Status.New;
        voted[msg.sender][ballotIds] = true;
        emit BallotCreated(ruleId, ballotIds);
        
        if (_checkMajority(r.majority, ballotIds)) {
            _executeBallot(ballotIds);
        }
    }
    
    function executeBallot(uint256 _ballotId) external {
        Ballot storage b = ballots[_ballotId];
        if(_checkMajority(rules[b.ruleId].majority, _ballotId)){
            _executeBallot(_ballotId);
        }
    }
    
    
    /**
     * @dev Apply changes from ballot.
     * @param ballotId The ballot index
     */
    function _executeBallot(uint256 ballotId) internal {
        Ballot storage b = ballots[ballotId];
        require(b.status != Status.Executed,"Ballot is Executed");
        Rule storage r = rules[b.ruleId];
        bytes memory command = abi.encodePacked(bytes4(keccak256(bytes(r.funcAbi))), b.args);
        trigger(address(this), command);
        b.closeVote = block.timestamp;
        b.status = Status.Executed;
        emit ApplyBallot(b.ruleId, ballotId);
    }

    
    /**
     * @dev Apply changes from Governance System. Call destination contract.
     * @param contr The contract address to call
     * @param params encoded params
     */
    function trigger(address contr, bytes memory params) internal  {
        (bool success,) = contr.call(params);
        require(success, "Trigger error");
    }
}