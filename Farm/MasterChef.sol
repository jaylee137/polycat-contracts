// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v3.1.0/contracts/utils/ReentrancyGuard.sol";

import "./FishToken.sol";
import "./libs/IReferral.sol";

// MasterChef is the master of Fish. He can make Fish and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Fish is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of FISHes
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFishPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFishPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. FISHes to distribute per block.
        uint256 lastRewardBlock;  // Last block number that FISHes distribution occurs.
        uint256 accFishPerShare;   // Accumulated FISHes per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The FISH TOKEN!
    FishToken public fish;
    address public devAddress;
    address public feeAddress;
    address public vaultAddress;

    // FISH tokens created per block.
    uint256 public fishPerBlock = 1 ether;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when FISH mining starts.
    uint256 public startBlock;

    // Fish referral contract address.
    IReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);
    event SetVaultAddress(address indexed user, address indexed newAddress);
    event SetReferralAddress(address indexed user, IReferral indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 fishPerBlock);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        FishToken _fish,
        uint256 _startBlock,
        address _devAddress,
        address _feeAddress,
        address _vaultAddress
    ) public {
        fish = _fish;
        startBlock = _startBlock;

        devAddress = _devAddress;
        feeAddress = _feeAddress;
        vaultAddress = _vaultAddress;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    mapping(IERC20 => bool) public poolExistence;
    modifier nonDuplicated(IERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20 _lpToken, uint16 _depositFeeBP) external onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_lpToken] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accFishPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's FISH allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP) external onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending FISHes on frontend.
    function pendingFish(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFishPerShare = pool.accFishPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 fishReward = multiplier.mul(fishPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFishPerShare = accFishPerShare.add(fishReward.mul(1e18).div(lpSupply));
        }
        return user.amount.mul(accFishPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 fishReward = multiplier.mul(fishPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        fish.mint(devAddress, fishReward.div(10));
        fish.mint(address(this), fishReward);
        pool.accFishPerShare = pool.accFishPerShare.add(fishReward.mul(1e18).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for FISH allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            referral.recordReferral(msg.sender, _referrer);
        }
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFishPerShare).div(1e18).sub(user.rewardDebt);
            if (pending > 0) {
                safeFishTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            uint256 beforeDeposit = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            uint256 afterDeposit = pool.lpToken.balanceOf(address(this));
            _amount = afterDeposit.sub(beforeDeposit);
            
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee.div(2));
                pool.lpToken.safeTransfer(vaultAddress, depositFee.div(2));
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFishPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accFishPerShare).div(1e18).sub(user.rewardDebt);
        if (pending > 0) {
            safeFishTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFishPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe fish transfer function, just in case if rounding error causes pool to not have enough FISH.
    function safeFishTransfer(address _to, uint256 _amount) internal {
        uint256 fishBal = fish.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > fishBal) {
            transferSuccess = fish.transfer(_to, fishBal);
        } else {
            transferSuccess = fish.transfer(_to, _amount);
        }
        require(transferSuccess, "safeFishTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) external onlyOwner {
        devAddress = _devAddress;
        emit SetDevAddress(msg.sender, _devAddress);
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function setVaultAddress(address _vaultAddress) external onlyOwner {
        vaultAddress = _vaultAddress;
        emit SetVaultAddress(msg.sender, _vaultAddress);
    }
    
    function updateEmissionRate(uint256 _fishPerBlock) external onlyOwner {
        massUpdatePools();
        fishPerBlock = _fishPerBlock;
        emit UpdateEmissionRate(msg.sender, _fishPerBlock);
    }

    // Update the referral contract address by the owner
    function setReferralAddress(IReferral _referral) external onlyOwner {
        referral = _referral;
        emit SetReferralAddress(msg.sender, _referral);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) external onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                fish.mint(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
	    require(startBlock > block.number, "Farm already started");
        startBlock = _startBlock;
    }
}
