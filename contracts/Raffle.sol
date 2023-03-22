// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

/* Errors */
error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);
error Raffle__SendMoreToEnterRaffle();
error Raffle__TransferFailed();
error Raffle__RaffleNotOpen();
error Raffle__AlreadyPaid();
error Raffle__NotOwner();

/**@title A revamp of Patrick Collins raffle contract
 * @author Godand
 * @notice This contract would handle multiple raffles,logic for payments etc
 * @dev This implements the Chainlink VRF Version 2 and chainlink Keepers
 */
contract Raffle is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type declarations */
    enum RaffleState {
        OPEN,
        CALCULATING
    }
    /* State variables */
    // Chainlink VRF Variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    uint64 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    // Lottery Variables
    uint256 private immutable i_interval;
    uint256 private immutable i_entranceFee;
    uint256 private s_currentRaffle = 0;
    uint256 private s_lastTimeStamp;
    uint256 private s_feeBalance = 0;
    uint256 private s_minimumRafflePayout;
    Winner private s_recentWinner;
    address payable private s_owner;
    RaffleState private s_raffleState;

    mapping(uint256 => address payable[]) private s_raffleToPlayers; // each raffle to its players
    mapping(uint256 => Winner) private s_raffleToWinner; // each raffle to their winner

    // winner structure
    struct Winner {
        address payable winner;
        uint256 payAmount;
        bool isPaid;
    }

    /* Events */
    event RequestedRaffleWinner(uint256 indexed requestId);
    event RaffleEnter(uint256 indexed raffleId, address indexed player);
    event WinnerPicked(uint256 indexed raffleId,address indexed player);

    /* Modifiers */
    modifier onlyOwner {
        if (payable(msg.sender)!=s_owner) revert Raffle__NotOwner();
        _;
    }

    /* Functions */
    constructor(
        address vrfCoordinatorV2,
        uint64 subscriptionId,
        bytes32 gasLane, // keyHash
        uint256 interval,
        uint256 entranceFee,
        uint256 minimumRafflePayout,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_gasLane = gasLane;
        i_interval = interval;
        i_subscriptionId = subscriptionId;
        i_entranceFee = entranceFee;
        i_callbackGasLimit = callbackGasLimit;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_minimumRafflePayout=minimumRafflePayout;
        s_owner=payable(msg.sender);
    }

    fallback()external{
        enterRaffle();
    }

    function enterRaffle() public payable {
        // require(msg.value >= i_entranceFee, "Not enough value sent");
        // require(s_raffleState == RaffleState.OPEN, "Raffle is not open");
        if (msg.value < i_entranceFee) {
            revert Raffle__SendMoreToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        uint256 currentRaffle = s_currentRaffle;
        s_feeBalance += (msg.value * 10) / 100;
        s_raffleToPlayers[currentRaffle].push(payable(msg.sender));
        // Emit an event when we update a dynamic array or mapping
        // Named events with the function name reversed
        emit RaffleEnter(currentRaffle, msg.sender);
    }

    /**
     * @dev This is the function that the Chainlink Keeper nodes call
     * they look for `upkeepNeeded` to return True.
     * the following should be true for this to return true:
     * 1. The time interval has passed between raffle runs.
     * 2. The lottery is open.
     * 3. The contract has ETH.
     * 4. Implicity, your subscription is funded with LINK.
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        uint256 playerLength = s_raffleToPlayers[s_currentRaffle].length;
        bool isOpen = RaffleState.OPEN == s_raffleState;
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval);
        bool hasPlayers = playerLength > 0;
        bool hasBalance = address(this).balance > 0;
        bool hasMinPayout = (playerLength * i_entranceFee) >= s_minimumRafflePayout;
        upkeepNeeded = (timePassed && isOpen && hasBalance && hasPlayers && hasMinPayout);
        return (upkeepNeeded, "0x0"); // can I comment this out?
    }

    /**
     * @dev Once `checkUpkeep` is returning `true`, this function is called
     * and it kicks off a Chainlink VRF call to get a random winner.
     */
    function performUpkeep(bytes calldata /* performData */) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        // require(upkeepNeeded, "Upkeep not needed");
        if (!upkeepNeeded) {
            uint256 playerLength = s_raffleToPlayers[s_currentRaffle].length;
            revert Raffle__UpkeepNotNeeded(
                playerLength * i_entranceFee,
                playerLength,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        // is this redundant?
        emit RequestedRaffleWinner(requestId);
    }

    /**
     * @dev This is the function that Chainlink VRF node
     * calls to send the money to the random winner.
     */
    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] memory randomWords
    ) internal override {
        // players size 10
        // randomNumber 202
        // 202 % 10 ? what's doesn't divide evenly into 202?
        // 20 * 10 = 200
        // 2
        // 202 % 10 = 2
        uint256 currentRaffle=s_currentRaffle;
        address payable[] memory players = s_raffleToPlayers[currentRaffle];
        uint256 indexOfWinner = randomWords[0] % players.length;
        address payable recentWinner = players[indexOfWinner];
        Winner memory winner=Winner(
            payable(recentWinner),
            (players.length * i_entranceFee * 90) / 100,
            false
        );
        s_recentWinner = winner;
        s_raffleToWinner[currentRaffle] = winner;
        s_currentRaffle += 1;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        emit WinnerPicked(currentRaffle,recentWinner);
    }

    function winnerWithdraw(uint256 raffleId)external{
        Winner memory winner=s_raffleToWinner[raffleId];
        if(winner.isPaid) revert Raffle__AlreadyPaid();
        s_raffleToWinner[raffleId].isPaid=true;
        (bool success, ) = winner.winner.call{value: winner.payAmount}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    function ownerWithdraw(uint256 amount)external onlyOwner{
        if(amount>s_feeBalance) revert Raffle__TransferFailed();
        s_feeBalance-=amount;
        (bool success, ) = s_owner.call{value: amount}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    function changeOwner(address addr)external onlyOwner{
        s_owner=payable(addr);
    }

    /** Getter Functions */

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getNumWords() external pure returns (uint256) {
        return NUM_WORDS;
    }

    function getRequestConfirmations() external pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getRecentWinner() external view returns (Winner memory) {
        return s_recentWinner;
    }

    function getWinner(uint256 raffleId)external view returns(Winner memory){
        return s_raffleToWinner[raffleId];
    }

    function getPlayer(uint256 raffleId,uint256 index) external view returns (address) {
        return s_raffleToPlayers[raffleId][index];
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getInterval() external view returns (uint256) {
        return i_interval;
    }

    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getCurrentNumberOfPlayers() external view returns (uint256) {
        return s_raffleToPlayers[s_currentRaffle].length;
    }

    function getNumberOfPlayers(uint256 raffleId)external view returns(uint256){
        return s_raffleToPlayers[raffleId].length;
    }

    function getMinimumRafflePayout()external view returns(uint256){
        return s_minimumRafflePayout;
    }

    function getFeeBalance()external view returns(uint256){
        return s_feeBalance;
    }

    function getOwner()external view returns(address){
        return s_owner;
    }
}
