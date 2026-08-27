// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWNat} from "../../src/interfaces/IWNat.sol";

/// Minimal standard ERC20 for tests (no hooks, no fees).
contract MockERC20 {
    string public name;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_) {
        name = name_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// WNat mock: ERC20 + account-wide percentage delegation recording.
contract MockWNat is MockERC20 {
    mapping(address => address) public delegatee;
    mapping(address => uint256) public delegatedBips;

    constructor() MockERC20("WNat") {}

    function delegate(address to, uint256 bips) external {
        delegatee[msg.sender] = to;
        delegatedBips[msg.sender] = bips;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

/// Settable FTSO price feed for tests.
contract MockFtso {
    uint256 public value = 2_000_000; // $0.02/FLR at 8 decimals
    int8 public decimals = 8;
    uint64 public ts;
    bool public tsSet;

    function set(uint256 value_, int8 decimals_) external {
        value = value_;
        decimals = decimals_;
    }

    function setTimestamp(uint64 ts_) external {
        ts = ts_;
        tsSet = true;
    }

    function getFeedById(bytes21) external payable returns (uint256, int8, uint64) {
        return (value, decimals, tsSet ? ts : uint64(block.timestamp));
    }
}

/// Records ClaimSetupManager enrollments per calling account.
contract MockCSM {
    mapping(address => address) public executorOf;
    mapping(address => address) public recipientOf;

    function setClaimExecutors(address[] calldata executors) external payable {
        executorOf[msg.sender] = executors.length > 0 ? executors[0] : address(0);
    }

    function setAllowedClaimRecipients(address[] calldata recipients) external {
        recipientOf[msg.sender] = recipients.length > 0 ? recipients[0] : address(0);
    }
}

/// Fee-on-transfer token: delivers 1% less than sent. Must be REJECTED by the
/// vault's exact-delta accounting (M-09).
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("FEE") {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 fee = amount / 100;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }
}
