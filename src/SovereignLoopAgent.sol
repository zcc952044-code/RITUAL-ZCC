// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Sovereign Loop Agent
/// @notice 自唤醒循环 sovereign agent — 通过 Scheduler 定期调用 0x080C precompile
interface IScheduler {
    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256);
}

contract SovereignLoopAgent {
    address constant SOVEREIGN_AGENT = address(0x080C);
    address constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address constant SCHEDULER = 0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;

    bytes32 public lastJobId;
    bytes public lastResult;
    bytes public agentInput;
    address public owner;
    uint256 public wakeCount;
    uint256 public callId;
    bool public isRunning;
    bool public schedulerApproved;

    event SovereignAgentResultDelivered(bytes32 indexed jobId, bytes result);
    event WakeUpTriggered(uint256 indexed executionIndex, uint256 wakeCount);
    event LoopStarted(uint256 callId);

    constructor() {
        owner = msg.sender;
    }

    /// @notice 授权 Scheduler 回调（部署后第一步）
    function approveScheduler() external {
        require(msg.sender == owner, "not owner");
        schedulerApproved = true;
    }

    /// @notice 启动循环（传入 23 字段 ABI 编码的 agent 请求）
    function start(bytes calldata input) external {
        require(msg.sender == owner, "not owner");
        require(!isRunning, "already running");
        require(schedulerApproved, "call approveScheduler first");
        agentInput = input;
        isRunning = true;
        callId = _scheduleNext(500);
        emit LoopStarted(callId);
    }

    /// @notice Scheduler 回调此函数，每次唤醒执行 agent + 调度下一次
    function wakeUp(uint256 executionIndex) external {
        require(msg.sender == SCHEDULER, "not scheduler");
        if (!isRunning) return;
        wakeCount++;
        emit WakeUpTriggered(executionIndex, wakeCount);

        // 调用 sovereign agent precompile
        (bool ok,) = SOVEREIGN_AGENT.call(agentInput);
        require(ok, "precompile failed");

        // 调度下一次唤醒
        callId = _scheduleNext(500);
    }

    /// @notice Phase 2 回调 — AsyncDelivery 交付 agent 结果
    function onSovereignAgentResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == ASYNC_DELIVERY, "unauthorized");
        lastJobId = jobId;
        lastResult = result;
        emit SovereignAgentResultDelivered(jobId, result);
    }

    function stop() external {
        require(msg.sender == owner, "not owner");
        isRunning = false;
    }

    function restart() external {
        require(msg.sender == owner, "not owner");
        require(schedulerApproved, "call approveScheduler first");
        isRunning = true;
        callId = _scheduleNext(500);
        emit LoopStarted(callId);
    }

    function _scheduleNext(uint32 delay) internal returns (uint256) {
        return IScheduler(SCHEDULER).schedule(
            abi.encodeWithSelector(this.wakeUp.selector, uint256(0)),
            800_000,                        // gas
            uint32(block.number) + delay,   // startBlock
            1,                              // numCalls
            1,                              // frequency
            30,                             // ttl
            20 gwei,                        // maxFeePerGas
            2 gwei,                         // maxPriorityFeePerGas
            0,                              // value
            address(this)                   // payer = 合约自己
        );
    }
}
