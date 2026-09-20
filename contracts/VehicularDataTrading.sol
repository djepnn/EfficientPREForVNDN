// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract TradingAlgorithms {
    enum State { Missing, Funded, KeySubmitted, Disputed, Paid, Refunded }
    struct Listing { address producer; uint256 price; bytes32 dataHash; bytes32 packetHash; }
    struct Trade {
        bytes32 listing; address consumer; bytes consumerKey; uint256 amount;
        uint256 keyDeadline; uint256 evidenceDeadline; uint256 arbitrationDeadline;
        uint256 keyExpiry; State state; bytes32 evidenceHash; bytes32 decisionHash;
    }
    mapping(bytes32 => Listing) public listings;
    mapping(bytes32 => Trade) private trades;
    mapping(bytes32 => bytes) private keys;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public purchaseNonce;
    address public immutable adjudicator;
    uint256 public immutable keyWindow;
    uint256 public immutable evidenceWindow;
    uint256 public immutable arbitrationWindow;
    uint256 private entered;
    event Listed(bytes32 indexed name, address indexed producer);
    event Purchased(bytes32 indexed tradeId, bytes32 indexed name, address indexed consumer);
    event KeyRecorded(bytes32 indexed tradeId, bytes key, uint256 expiration, bytes signature);
    event Disputed(bytes32 indexed tradeId, bytes32 evidenceHash);
    event Terminal(bytes32 indexed tradeId, State state, bytes32 decisionHash);
    event Withdrawal(address indexed recipient, uint256 amount);

    constructor(address arbiter, uint256 kw, uint256 ew, uint256 aw) {
        require(arbiter != address(0) && kw > 0 && ew > 0 && aw > 0, "parameters");
        adjudicator = arbiter; keyWindow = kw; evidenceWindow = ew; arbitrationWindow = aw;
    }
    // SC_DataList: registration of the listing and its integrity commitments.
    function listData(bytes32 name, uint256 price, bytes32 dataHash, bytes32 packetHash) external {
        require(listings[name].producer == address(0) && price > 0, "listing");
        require(dataHash != bytes32(0) && packetHash != bytes32(0), "commitments");
        listings[name] = Listing(msg.sender, price, dataHash, packetHash);
        emit Listed(name, msg.sender);
    }
    // SC_Fund: purchase-specific escrow, separate from eventual withdrawal.
    function deposit(bytes32 name, bytes calldata consumerKey) external payable returns (bytes32 id) {
        Listing storage l = listings[name];
        require(l.producer != address(0) && msg.value == l.price && consumerKey.length > 0, "purchase");
        id = keccak256(abi.encode(block.chainid, address(this), name, msg.sender, ++purchaseNonce[msg.sender]));
        Trade storage t = trades[id];
        require(t.state == State.Missing, "duplicate");
        t.listing = name; t.consumer = msg.sender; t.consumerKey = consumerKey; t.amount = msg.value;
        t.keyDeadline = block.timestamp + keyWindow; t.state = State.Funded;
        emit Purchased(id, name, msg.sender);
    }
    // SC_Trade: authenticate the submitted key while keeping payment locked.
    function submissionDigest(bytes32 id, bytes calldata rk, uint256 expires) public view returns (bytes32) {
        Trade storage t = trades[id];
        return keccak256(abi.encode(block.chainid, address(this), id, t.listing, t.consumer,
            keccak256(t.consumerKey), keccak256(rk), expires));
    }
    function submitRK(bytes32 id, bytes calldata rk, uint256 expires, bytes calldata signature) external {
        Trade storage t = trades[id];
        require(t.state == State.Funded && block.timestamp <= t.keyDeadline, "key state");
        address producer = listings[t.listing].producer;
        require(msg.sender == producer && rk.length > 0, "producer/key");
        require(expires >= block.timestamp + evidenceWindow, "short validity");
        require(recover(submissionDigest(id, rk, expires), signature) == producer, "binding signature");
        keys[id] = rk; t.keyExpiry = expires;
        t.evidenceDeadline = block.timestamp + evidenceWindow; t.state = State.KeySubmitted;
        emit KeyRecorded(id, rk, expires, signature);
    }
    // SC_Trade: confirmation or an unchallenged timeout creates producer credit.
    function confirmReceipt(bytes32 id) external {
        Trade storage t = trades[id];
        require(t.consumer == msg.sender && t.state == State.KeySubmitted, "confirmation");
        finish(id, t, true, bytes32(0));
    }
    function finalizeAfterTimeout(bytes32 id) external {
        Trade storage t = trades[id];
        require(t.state == State.KeySubmitted && block.timestamp > t.evidenceDeadline, "window");
        finish(id, t, true, bytes32(0));
    }
    // SC_Fund: missing-key timeout creates consumer refund credit.
    function withdrawAfterKeyTimeout(bytes32 id) external {
        Trade storage t = trades[id];
        require(t.state == State.Funded && block.timestamp > t.keyDeadline, "key window");
        finish(id, t, false, bytes32(0));
    }
    // SC_Dispute: a timely complaint freezes normal settlement for trusted adjudication.
    function submitDispute(bytes32 id, bytes32 evidenceHash) external {
        Trade storage t = trades[id];
        require(msg.sender == t.consumer && t.state == State.KeySubmitted, "dispute state");
        require(block.timestamp <= t.evidenceDeadline && evidenceHash != bytes32(0), "evidence");
        t.evidenceHash = evidenceHash; t.arbitrationDeadline = block.timestamp + arbitrationWindow;
        t.state = State.Disputed; emit Disputed(id, evidenceHash);
    }
    function adjudicate(bytes32 id, bool payProducer, bytes32 decisionHash) external {
        require(msg.sender == adjudicator, "adjudicator");
        Trade storage t = trades[id];
        require(t.state == State.Disputed && block.timestamp <= t.arbitrationDeadline, "arbitration window");
        require(decisionHash != bytes32(0), "reason");
        finish(id, t, payProducer, decisionHash);
    }
    function refundAfterArbitrationTimeout(bytes32 id) external {
        Trade storage t = trades[id];
        require(t.state == State.Disputed && block.timestamp > t.arbitrationDeadline, "arbitration active");
        finish(id, t, false, bytes32(0));
    }
    // Shared settlement bookkeeping. State guards are enforced by the entry points.
    function finish(bytes32 id, Trade storage t, bool payProducer, bytes32 reason) private {
        uint256 amount = t.amount; require(amount > 0, "released");
        t.amount = 0; t.state = payProducer ? State.Paid : State.Refunded; t.decisionHash = reason;
        credit[payProducer ? listings[t.listing].producer : t.consumer] += amount;
        emit Terminal(id, t.state, reason);
    }
    // SC_Fund: actual payment occurs only when the credited recipient withdraws.
    function withdrawCredit() external {
        require(entered == 0, "reentry"); entered = 1;
        uint256 amount = credit[msg.sender]; require(amount > 0, "empty"); credit[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}(""); require(ok, "transfer");
        entered = 0; emit Withdrawal(msg.sender, amount);
    }
    function recover(bytes32 digest, bytes calldata sig) internal pure virtual returns (address signer);
}
