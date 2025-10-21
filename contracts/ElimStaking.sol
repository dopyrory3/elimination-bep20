// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  Gauntlet

  Safety & design highlights:
   - Chainlink VRF v2 for randomness (one request per round).
   - Prevent VRF frontrunning: require at least 1 block after request before processing.
   - Batch elimination with participantIndex mapping (1-based) and swap-pop removal.
   - Loop-free survivor reward claims via per-round cumulative prefix sums.
   - SafeERC20 for transfers, Checks-Effects-Interactions, nonReentrant.
   - Keeper-only batch processing with per-round cap & keeperReserve management.
   - Tokenomics validation and admin eventing.
   - Pause/unpause circuit breaker.
   - Fallback randomness (owner-callable after timeout) for emergency/testnet (weaker).
*/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

contract Gauntlet is Ownable, ReentrancyGuard, VRFConsumerBaseV2 { 
    using SafeERC20 for IERC20;

    /* ========== EVENTS ========== */
    event StakeOpened(uint256 timestamp);
    event Staked(address indexed player, uint256 amount);
    event StakingClosed(uint256 timestamp, uint256 roundStarted);
    event RoundRequested(uint256 indexed round, uint256 requestId, uint256 requestBlock);
    event RoundRandomFulfilled(uint256 indexed round, uint256 randomness);
    event RoundStarted(uint256 indexed round, uint256 startTime);
    event BatchProcessed(uint256 indexed round, uint256 eliminationsThisBatch);
    event PlayerEliminated(uint256 indexed round, address indexed player, uint256 stake);
    event RoundFinalized(uint256 indexed round, uint256 survivors);
    event RewardsClaimed(address indexed player, uint256 amount);
    event Winner(address indexed player, uint256 prizeAmount);
    event KeeperPaid(address indexed keeper, uint256 amount);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event KeeperSet(address indexed keeper);
    event TokenomicsUpdated(uint256 dev, uint256 lp, uint256 burn, uint256 survivor, uint256 prize);
    event WalletsUpdated(address dev, address lp, address burn);
    event KeeperReserveDeposited(address indexed sender, uint256 amount);
    event KeeperReserveWithdrawn(address indexed owner, uint256 amount);
    event EmergencyFallbackUsed(uint256 indexed round, uint256 fallbackSeed);

    /* ========== TOKEN & STATE ========== */
    IERC20 public immutable stakingToken;

    bool public stakingActive;
    bool public gauntletActive;
    bool public paused;

    uint256 public currentRound;      // starts at 1 when gauntlet begins
    uint256 public roundDuration;     // seconds
    uint256 public roundStartTime;

    address[] private participants;   // participant addresses
    mapping(address => Participant) public participantInfo;
    mapping(address => uint256) public participantIndex; // 1-based index; 0 == not present

    struct Participant {
        uint256 stake;
        uint256 lastClaimedRound; // for prefix-sum claiming
    }

    // prefix-sum bookkeeping: cumulativeSurvivorPerPlayer[r] = sum of per-player rewards up to round r
    mapping(uint256 => uint256) public cumulativeSurvivorPerPlayer;
    mapping(uint256 => RoundInfo) public rounds;

    struct RoundInfo {
        uint256 survivorRewardPerPlayer;
        uint256 eliminationsDone;
        uint256 randomSeed;
        uint256 randomRequestedBlock;
        bool randomnessFulfilled;
        bool fallbackUsed;
    }

    // tokenomics: percentages must sum to 100
    uint256 public devPercent = 5;
    uint256 public lpPercent = 5;
    uint256 public burnPercent = 10;
    uint256 public survivorPercent = 30;
    uint256 public prizePoolPercent = 50;

    uint256 public prizePool; // tokens destined for final winner
    uint256 public pendingSurvivorPool; // accumulates survivor slices this round from eliminated stakes

    // wallets
    address public devWallet;
    address public lpWallet;
    address public burnWallet;

    /* ========== BATCH & KEEPER ========== */
    uint256 public batchSize = 100; // suggested default
    uint256 public nextEliminationIndex = 0;

    address public keeper; // onlyKeeper may call requestRandomForRound and runEliminationBatch
    uint256 public keeperPayPerCall = 0.01 ether; // pay in BNB
    uint256 public keeperReserve; // owner-funded reserve for reimbursements
    uint256 public maxKeeperCallsPerRound = 50;
    mapping(uint256 => uint256) public keeperCallsInRound; // round => calls made

    /* ========== VRF v2 ========== */
    VRFCoordinatorV2Interface COORDINATOR;
    uint64 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit = 200_000;
    uint16 public vrfRequestConfirmations = 3;
    mapping(uint256 => uint256) public vrfRequestToRound;

    /* ========== MODIFIERS ========== */
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    modifier onlyKeeper() {
        require(msg.sender == keeper, "Only keeper");
        _;
    }
    modifier onlyValidAddress(address a) {
        require(a != address(0), "zero address");
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    constructor(
        IERC20 _stakingToken,
        address _devWallet,
        address _lpWallet,
        address _burnWallet,
        address _vrfCoordinator,
        uint64 _vrfSubscriptionId,
        bytes32 _vrfKeyHash,
        address _initialKeeper,
        uint256 _roundDurationSeconds
    )
        Ownable(msg.sender)
        ReentrancyGuard()
        VRFConsumerBaseV2(_vrfCoordinator)
        {
        require(address(_stakingToken) != address(0), "zero token");
        require(_devWallet != address(0) && _lpWallet != address(0) && _burnWallet != address(0), "zero wallets");
        require(_initialKeeper != address(0), "zero keeper");

        stakingToken = _stakingToken;
        devWallet = _devWallet;
        lpWallet = _lpWallet;
        burnWallet = _burnWallet;

        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        vrfSubscriptionId = _vrfSubscriptionId;
        vrfKeyHash = _vrfKeyHash;

        keeper = _initialKeeper;
        roundDuration = _roundDurationSeconds;
    }

    /* ========== ADMIN ========== */

    function setKeeper(address _keeper) external onlyOwner onlyValidAddress(_keeper) {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setKeeperPay(uint256 _wei) external onlyOwner {
        keeperPayPerCall = _wei;
    }

    function setMaxKeeperCallsPerRound(uint256 _max) external onlyOwner {
        require(_max > 0, "max>0");
        maxKeeperCallsPerRound = _max;
    }

    function depositKeeperFunds() external payable onlyOwner {
        require(msg.value > 0, "no BNB");
        keeperReserve += msg.value;
        emit KeeperReserveDeposited(msg.sender, msg.value);
    }

    function withdrawKeeperFunds(uint256 amountWei) external onlyOwner {
        require(amountWei <= keeperReserve, "exceeds reserve");
        keeperReserve -= amountWei;
        payable(msg.sender).transfer(amountWei);
        emit KeeperReserveWithdrawn(msg.sender, amountWei);
    }

    function setBatchSize(uint256 _size) external onlyOwner {
        require(_size > 0 && _size <= 500, "batch size 1-500");
        batchSize = _size;
    }

    function setRoundDuration(uint256 _seconds) external onlyOwner {
        require(_seconds >= 60, "min 60s");
        roundDuration = _seconds;
    }

    function setTokenomicsPercents(
        uint256 _dev,
        uint256 _lp,
        uint256 _burn,
        uint256 _survivor,
        uint256 _prize
    ) external onlyOwner {
        require(_dev + _lp + _burn + _survivor + _prize == 100, "must sum 100");
        require(_prize >= 5, "prize percent too low"); // example minimum to avoid crippling prize
        devPercent = _dev;
        lpPercent = _lp;
        burnPercent = _burn;
        survivorPercent = _survivor;
        prizePoolPercent = _prize;
        emit TokenomicsUpdated(_dev, _lp, _burn, _survivor, _prize);
    }

    function setWallets(address _dev, address _lp, address _burn) external onlyOwner {
        require(_dev != address(0) && _lp != address(0) && _burn != address(0), "zero addresses");
        devWallet = _dev;
        lpWallet = _lp;
        burnWallet = _burn;
        emit WalletsUpdated(_dev, _lp, _burn);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /* ========== STAKING LIFECYCLE ========== */

    function openStaking() external onlyOwner whenNotPaused {
        require(!stakingActive && !gauntletActive, "already active");
        stakingActive = true;
        emit StakeOpened(block.timestamp);
    }

    // stake with optional minReceived to protect against rebasing/fee tokens
    function stake(uint256 amount, uint256 minReceived) external nonReentrant whenNotPaused {
        require(stakingActive, "staking closed");
        require(amount > 0, "zero amount");

        uint256 before = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakingToken.balanceOf(address(this)) - before;
        require(received >= minReceived, "insufficient received");

        if (participantInfo[msg.sender].stake == 0) {
            participants.push(msg.sender);
            participantIndex[msg.sender] = participants.length; // 1-based
        }
        participantInfo[msg.sender].stake += received;

        emit Staked(msg.sender, received);
    }

    function closeStakingAndStartGauntlet() external onlyOwner whenNotPaused {
        require(stakingActive, "staking not active");
        require(participants.length > 1, "need >1 participants");
        stakingActive = false;
        gauntletActive = true;
        currentRound = 1;
        roundStartTime = block.timestamp;
        cumulativeSurvivorPerPlayer[0] = 0;
        emit StakingClosed(block.timestamp, currentRound);
        emit RoundStarted(currentRound, roundStartTime);
    }

    /* ========== VRF: request randomness per round (keeper) ========== */

    // Keeper requests randomness for the current round. We record the request block.
    function requestRandomForRound() external onlyKeeper whenNotPaused returns (uint256 requestId) {
        require(gauntletActive, "gauntlet not active");
        require(block.timestamp >= roundStartTime + roundDuration, "round not ready");
        uint256 round = currentRound;
        require(rounds[round].randomRequestedBlock == 0, "already requested");

        requestId = COORDINATOR.requestRandomWords(
            vrfKeyHash,
            vrfSubscriptionId,
            vrfRequestConfirmations,
            vrfCallbackGasLimit,
            1
        );
        vrfRequestToRound[requestId] = round;
        rounds[round].randomRequestedBlock = block.number;
        emit RoundRequested(round, requestId, block.number);
    }

    // Chainlink VRF callback
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 round = vrfRequestToRound[requestId];
        require(round != 0, "unknown request");
        rounds[round].randomSeed = randomWords[0];
        rounds[round].randomnessFulfilled = true;
        emit RoundRandomFulfilled(round, randomWords[0]);
    }

    /* ========== BATCH ELIMINATION (keeper) ========== */

    // Keeper calls this to process a batch. Requires randomness fulfilled and at least 1 block after request to prevent frontrunning.
    function runEliminationBatch() external nonReentrant onlyKeeper whenNotPaused {
        require(gauntletActive, "gauntlet not active");
        require(participants.length > 1, "not enough participants");
        require(block.timestamp >= roundStartTime + roundDuration, "round not ready");

        uint256 round = currentRound;
        require(rounds[round].randomnessFulfilled, "randomness not fulfilled");
        require(rounds[round].randomRequestedBlock > 0, "randomness not requested");
        require(block.number > rounds[round].randomRequestedBlock, "must wait >1 block after request");

        // prevent keeper drain by capping calls per round
        require(keeperCallsInRound[round] < maxKeeperCallsPerRound, "keeper call limit reached");
        keeperCallsInRound[round]++;

        uint256 eliminationsThisBatch = 0;
        uint256 end = nextEliminationIndex + batchSize;
        if (end > participants.length) end = participants.length;

        // deterministic randomness per elimination using VRF seed + index (use abi.encode)
        uint256 seed = rounds[round].randomSeed;

        for (uint256 i = nextEliminationIndex; i < end; i++) {
            if (participants.length <= 1) break;

            uint256 rand = uint256(keccak256(abi.encode(seed, i, block.number)));
            uint256 idx0 = rand % participants.length;
            address eliminatedPlayer = participants[idx0];
            uint256 eliminatedStake = participantInfo[eliminatedPlayer].stake;

            // Effects-first: zero out stake to prevent reentrancy / double-handling
            participantInfo[eliminatedPlayer].stake = 0;
            // remove participant via swap & pop and keep participantIndex mapping consistent
            _removeParticipantByIndex(idx0);

            // Tokenomics: split eliminatedStake into parts; do transfers (interactions) after state updated
            _distributeEliminatedStake(eliminatedPlayer, eliminatedStake);

            emit PlayerEliminated(round, eliminatedPlayer, eliminatedStake);
            eliminationsThisBatch++;
        }

        nextEliminationIndex = end;

        // finalize round if we've exhausted index or only one participant left
        if (nextEliminationIndex >= participants.length || participants.length <= 1) {
            uint256 survivorsCount = participants.length;
            if (survivorsCount > 0) {
                // compute per-player share from pendingSurvivorPool
                uint256 totalSurvivorSlice = pendingSurvivorPool;
                uint256 perSurvivor = 0;
                if (survivorsCount > 0 && totalSurvivorSlice > 0) {
                    perSurvivor = totalSurvivorSlice / survivorsCount;
                }
                rounds[round].survivorRewardPerPlayer = perSurvivor;

                // update cumulative prefix sum for round
                cumulativeSurvivorPerPlayer[round] = cumulativeSurvivorPerPlayer[round - 1] + perSurvivor;
                // any remainder stays in prizePool (no silent loss)
                uint256 distributed = perSurvivor * survivorsCount;
                if (totalSurvivorSlice > distributed) {
                    uint256 remainder = totalSurvivorSlice - distributed;
                    prizePool += remainder;
                }
            } else {
                // no survivors (shouldn't happen), keep pending pool in prizePool
                prizePool += pendingSurvivorPool;
                cumulativeSurvivorPerPlayer[round] = cumulativeSurvivorPerPlayer[round - 1];
            }

            // reset pendingSurvivorPool
            pendingSurvivorPool = 0;

            rounds[round].eliminationsDone = eliminationsThisBatch;
            emit RoundFinalized(round, participants.length);

            // reset for next round
            nextEliminationIndex = 0;
            currentRound++;
            roundStartTime = block.timestamp;
            emit RoundStarted(currentRound, roundStartTime);
        }

        // reimburse keeper from keeperReserve with per-round cap to prevent drain
        if (keeperReserve >= keeperPayPerCall && keeperPayPerCall > 0) {
            // only allow reimbursement up to maxKeeperCallsPerRound per round (enforced above by keeperCallsInRound)
            keeperReserve -= keeperPayPerCall;
            payable(msg.sender).transfer(keeperPayPerCall);
            emit KeeperPaid(msg.sender, keeperPayPerCall);
        }

        emit BatchProcessed(currentRound - 1, eliminationsThisBatch);

        // if last survivor reached, finalize winner
        if (participants.length == 1) {
            address winnerAddr = participants[0];
            uint256 payout = prizePool;
            prizePool = 0;
            gauntletActive = false;
            // safe transfer
            stakingToken.safeTransfer(winnerAddr, payout);
            emit Winner(winnerAddr, payout);
        }
    }

    /* ========== INTERNAL HELPERS ========== */

    // remove participant at array index idx0 (0-based). Keep participantIndex mapping consistent.
    function _removeParticipantByIndex(uint256 idx0) internal {
        address removed = participants[idx0];
        uint256 lastIndex = participants.length - 1;
        if (idx0 != lastIndex) {
            address moved = participants[lastIndex];
            participants[idx0] = moved;
            participantIndex[moved] = idx0 + 1; // update 1-based index
        }
        participants.pop();
        participantIndex[removed] = 0;
    }

    // Distribute eliminated stake according to tokenomics; state already updated (participant stake zeroed, removed)
    // Uses Checks-Effects-Interactions: state changed before calls (we zeroed stake and removed participant).
    function _distributeEliminatedStake(address /*player*/, uint256 stakeAmount) internal {
        if (stakeAmount == 0) return;

        uint256 devAmount = (stakeAmount * devPercent) / 100;
        uint256 lpAmount = (stakeAmount * lpPercent) / 100;
        uint256 burnAmount = (stakeAmount * burnPercent) / 100;
        uint256 survivorAmount = (stakeAmount * survivorPercent) / 100;
        uint256 prizeAmount = (stakeAmount * prizePoolPercent) / 100;

        uint256 sumParts = devAmount + lpAmount + burnAmount + survivorAmount + prizeAmount;
        if (sumParts > stakeAmount) sumParts = stakeAmount;
        uint256 remainder = stakeAmount - sumParts;

        // apply transfers (external calls) after state changes
        if (devAmount > 0) stakingToken.safeTransfer(devWallet, devAmount);
        if (lpAmount > 0) stakingToken.safeTransfer(lpWallet, lpAmount);
        if (burnAmount > 0) stakingToken.safeTransfer(burnWallet, burnAmount);

        // prize pool increases
        prizePool += prizeAmount;
        // remainders added to prizePool
        prizePool += remainder;

        // survivorAmount aggregates into pendingSurvivorPool for this round
        if (survivorAmount > 0) {
            pendingSurvivorPool += survivorAmount;
        }
    }

    /* ========== CLAIMING (loop-free per-player) ========== */

    // Claim all unclaimed per-round survivor rewards for caller
    function claimSurvivorRewards() external nonReentrant whenNotPaused {
        uint256 lastClaim = participantInfo[msg.sender].lastClaimedRound;
        uint256 upto = currentRound - 1; // last finalized round
        require(upto > lastClaim, "no rounds to claim");

        uint256 owed = cumulativeSurvivorPerPlayer[upto] - cumulativeSurvivorPerPlayer[lastClaim];
        require(owed > 0, "no rewards");

        // mark claimed before transfer
        participantInfo[msg.sender].lastClaimedRound = upto;

        stakingToken.safeTransfer(msg.sender, owed);
        emit RewardsClaimed(msg.sender, owed);
    }

    /* ========== FALLBACK VRF (owner emergency) ========== */

    // Only for emergency/testnet: if VRF never returns, owner can set fallback random seed after a long delay.
    // Use cautiously — this is weaker randomness and should be time-locked in production.
    function emergencyUseFallbackRandom(uint256 round, uint256 fallbackSeed) external onlyOwner whenNotPaused {
        require(rounds[round].randomRequestedBlock > 0, "no request");
        require(!rounds[round].randomnessFulfilled, "already fulfilled");
        // require a large delay: e.g., 5000 blocks (~ ~25k seconds on BSC ~ ~7 hours) — adjust as needed
        require(block.number > rounds[round].randomRequestedBlock + 5000, "too early for fallback");
        rounds[round].randomSeed = fallbackSeed;
        rounds[round].randomnessFulfilled = true;
        rounds[round].fallbackUsed = true;
        emit EmergencyFallbackUsed(round, fallbackSeed);
    }

    /* ========== VIEWS & UTILITIES ========== */

    function getParticipants() external view returns (address[] memory) {
        return participants;
    }

    function participantsCount() external view returns (uint256) {
        return participants.length;
    }

    // Get cumulative up to a round
    function getCumulativeUpTo(uint256 round) external view returns (uint256) {
        return cumulativeSurvivorPerPlayer[round];
    }

    /* ========== RECEIVE: accept BNB to fund keeperReserve ========== */
    receive() external payable {
        require(msg.value > 0, "no BNB");
        keeperReserve += msg.value;
        emit KeeperReserveDeposited(msg.sender, msg.value);
    }
}
