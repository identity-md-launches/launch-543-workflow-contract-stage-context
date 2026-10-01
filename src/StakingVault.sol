// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Ownerless, seven-day locked staking of LaunchToken with separately funded token rewards.
/// @dev Only the immutable, non-rebasing, fee-free LaunchToken is supported. No shares or compounding.
contract StakingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant LOCK_DURATION = 7 days;
    uint256 public constant REWARD_DURATION = 7 days;
    uint256 public constant PRECISION = 1e36;

    IERC20 public immutable token;
    uint256 public totalStaked;
    /// @notice Accepted funding less paid claims; excludes all principal and unsolicited transfers.
    uint256 public rewardReserve;
    /// @notice Minor token units per second until periodFinish.
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    /// @notice Checkpointed idle emissions and schedule-division dust reserved for a new period.
    uint256 public queuedRewards;

    mapping(address account => uint256) public balanceOf;
    mapping(address account => uint256) public unlockTime;
    mapping(address account => uint256) public rewards;
    mapping(address account => uint256) public userRewardPerTokenPaid;
    /// @notice Sub-unit reward fraction, scaled by PRECISION, preserved across claims and exits.
    mapping(address account => uint256) public rewardRemainder;

    error InvalidToken();
    error ZeroAmount();
    error InsufficientStake();
    error StakeLocked(uint256 unlockAt);
    error NoRewards();
    error InsufficientRewardFunding();
    error ActiveRewardPeriod();
    error RewardDurationTooShort(uint256 actual, uint256 minimum);
    error UnexpectedTokenAmount();

    event Staked(address indexed account, uint256 amount, uint256 unlockAt);
    event Unstaked(address indexed account, uint256 amount);
    event RewardClaimed(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rate, uint256 finish);
    event RewardsRestarted(address indexed caller, uint256 rate, uint256 finish);

    /// @param token_ The deployed LaunchToken; use $token in the separately generated manifest.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    /// @notice Stake your own tokens. Every addition resets the lock on your entire position.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        balanceOf[msg.sender] += amount;
        totalStaked += amount;
        uint256 unlockAt = block.timestamp + LOCK_DURATION;
        unlockTime[msg.sender] = unlockAt;
        _pullExact(amount);
        emit Staked(msg.sender, amount, unlockAt);
    }

    /// @notice Return only your principal after the lock. Accrued rewards remain claimable.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();
        if (block.timestamp < unlockTime[msg.sender]) revert StakeLocked(unlockTime[msg.sender]);
        _checkpoint(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        if (balanceOf[msg.sender] == 0) unlockTime[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Claim to yourself at any time, including during the principal lock or after exit.
    function claim() external nonReentrant returns (uint256 amount) {
        _checkpoint(msg.sender);
        amount = rewards[msg.sender];
        if (amount == 0) revert NoRewards();
        rewards[msg.sender] = 0;
        // Checked subtraction is an additional hard barrier against paying from principal.
        rewardReserve -= amount;
        token.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice Irrevocably fund rewards from your own wallet, with an ERC-20 approval first.
    /// @dev An active period keeps its finish time: a tiny top-up cannot delay existing rewards.
    /// Queued rewards are included only in a new period, which needs at least 604800 minor units.
    /// This overload accepts any remaining duration, even one second.
    function fundRewards(uint256 amount) external nonReentrant {
        _fundRewards(amount, 0);
    }

    /// @notice Donate only if the resulting stream has at least minDuration seconds left when mined.
    /// @dev Use REWARD_DURATION to require a full week. The active period's finish is never extended.
    function fundRewards(uint256 amount, uint256 minDuration) external nonReentrant {
        _fundRewards(amount, minDuration);
    }

    function _fundRewards(uint256 amount, uint256 minDuration) private {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(address(0));
        rewardReserve += amount;
        _schedule(amount);
        uint256 duration = periodFinish - block.timestamp;
        if (duration < minDuration) revert RewardDurationTooShort(duration, minDuration);
        _pullExact(amount);
        emit RewardsFunded(msg.sender, amount, rewardRate, periodFinish);
    }

    /// @notice Anyone may restart enough queued rewards after the prior period ends, without paying.
    function restartRewards() external nonReentrant {
        if (block.timestamp < periodFinish) revert ActiveRewardPeriod();
        _checkpoint(address(0));
        _schedule(0);
        emit RewardsRestarted(msg.sender, rewardRate, periodFinish);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 emission = (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        return rewardPerTokenStored + Math.mulDiv(emission, PRECISION, totalStaked);
    }

    /// @notice Claimable whole minor units as of the current block timestamp.
    function earned(address account) public view returns (uint256) {
        (uint256 whole,) = _accrual(account, rewardPerToken());
        return rewards[account] + whole;
    }

    /// @notice queuedRewards plus idle emissions not yet checkpointed.
    function unallocatedRewards() external view returns (uint256) {
        if (totalStaked != 0) return queuedRewards;
        return queuedRewards + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
    }

    /// @notice Instantaneous simple annualized token APR in basis points (10000 = 100%).
    /// @dev Assumes today's rate and total stake for 365 days; not a promised or compounded yield.
    function aprBps() external view returns (uint256) {
        if (totalStaked == 0 || block.timestamp >= periodFinish) return 0;
        return Math.mulDiv(rewardRate, 365 days * 10_000, totalStaked);
    }

    function _checkpoint(address account) private {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0) {
            queuedRewards += (applicable - lastUpdateTime) * rewardRate;
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdateTime = applicable;
        if (account != address(0)) {
            (uint256 whole, uint256 fraction) = _accrual(account, rewardPerTokenStored);
            rewards[account] += whole;
            rewardRemainder[account] = fraction;
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _accrual(address account, uint256 current) private view returns (uint256 whole, uint256 fraction) {
        uint256 delta = current - userRewardPerTokenPaid[account];
        uint256 stakeAmount = balanceOf[account];
        uint256 scaledRemainder = mulmod(stakeAmount, delta, PRECISION) + rewardRemainder[account];
        whole = Math.mulDiv(stakeAmount, delta, PRECISION) + scaledRemainder / PRECISION;
        fraction = scaledRemainder % PRECISION;
    }

    function _schedule(uint256 added) private {
        uint256 duration;
        uint256 budget = added;
        if (block.timestamp >= periodFinish) {
            budget += queuedRewards;
            queuedRewards = 0;
            duration = REWARD_DURATION;
            periodFinish = block.timestamp + duration;
        } else {
            duration = periodFinish - block.timestamp;
            budget += duration * rewardRate;
        }
        rewardRate = budget / duration;
        if (rewardRate == 0) revert InsufficientRewardFunding();
        queuedRewards += budget % duration;
        lastUpdateTime = block.timestamp;
    }

    function _pullExact(uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert UnexpectedTokenAmount();
    }
}
