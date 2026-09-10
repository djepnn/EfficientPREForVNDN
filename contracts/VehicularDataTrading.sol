// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Research reference implementation for the manuscript workflow.
/// @dev The contract authenticates and records PRE key submissions. It does
///      not publicly verify the functional correctness of an ordinary PRE key.
contract VehicularDataTrading {
    enum Status {
        None,
        Available,
        Locked,
        KeySubmitted,
        Settled,
        Refunded,
        Disputed
    }

    struct Listing {
        address payable producer;
        uint256 price;
        bytes32 packetHash;
        bytes32 dataHash;
        bytes32 tradeId;
        Status status;
    }

    struct Trade {
        address payable consumer;
        bytes consumerPublicKey;
        uint256 lockedFunds;
        uint256 keyDeadline;
        uint256 evidenceDeadline;
    }

    struct KeySubmission {
        bytes temporaryPublicKey;
        bytes reEncryptionKey;
        bytes metadata;
        bytes producerSignature;
        uint256 expiration;
    }

    struct Dispute {
        bytes32 evidenceHash;
        uint256 submittedAt;
    }

    uint256 public immutable keySubmissionWindow;
    uint256 public immutable evidenceWindow;

    mapping(bytes32 => Listing) public listings;
    mapping(bytes32 => Trade) private trades;
    mapping(bytes32 => KeySubmission) private keySubmissions;
    mapping(bytes32 => Dispute) public disputes;

    event DataListed(bytes32 indexed nameHash, address indexed producer, uint256 price);
    event FundLocked(bytes32 indexed nameHash, bytes32 indexed tradeId, address consumer, uint256 amount);
    event ReEncryptionKeySubmitted(bytes32 indexed nameHash, bytes32 indexed tradeId);
    event SettlementComplete(bytes32 indexed nameHash, bytes32 indexed tradeId);
    event FundWithdrawn(bytes32 indexed nameHash, bytes32 indexed tradeId, address consumer);
    event DisputeSubmitted(bytes32 indexed nameHash, bytes32 indexed tradeId, bytes32 evidenceHash);

    constructor(uint256 keyWindow, uint256 disputeWindow) {
        require(keyWindow > 0 && disputeWindow > 0, "invalid window");
        keySubmissionWindow = keyWindow;
        evidenceWindow = disputeWindow;
    }

    function listData(
        bytes32 nameHash,
        uint256 price,
        bytes32 packetHash,
        bytes32 dataHash
    ) external {
        require(price > 0, "invalid price");
        require(listings[nameHash].status == Status.None, "listing exists");

        listings[nameHash] = Listing({
            producer: payable(msg.sender),
            price: price,
            packetHash: packetHash,
            dataHash: dataHash,
            tradeId: bytes32(0),
            status: Status.Available
        });

        emit DataListed(nameHash, msg.sender, price);
    }

    function deposit(bytes32 nameHash, bytes calldata consumerPublicKey) external payable {
        Listing storage listing = listings[nameHash];
        require(listing.status == Status.Available, "not available");
        require(msg.value == listing.price, "incorrect payment");

        bytes32 tradeId = keccak256(
            abi.encode(nameHash, msg.sender, block.timestamp, block.number)
        );
        listing.tradeId = tradeId;
        listing.status = Status.Locked;
        trades[tradeId] = Trade({
            consumer: payable(msg.sender),
            consumerPublicKey: consumerPublicKey,
            lockedFunds: msg.value,
            keyDeadline: block.timestamp + keySubmissionWindow,
            evidenceDeadline: 0
        });

        emit FundLocked(nameHash, tradeId, msg.sender, msg.value);
    }

    function withdrawAfterKeyTimeout(bytes32 nameHash) external {
        Listing storage listing = listings[nameHash];
        Trade storage trade = trades[listing.tradeId];
        require(msg.sender == trade.consumer, "not consumer");
        require(listing.status == Status.Locked, "invalid state");
        require(block.timestamp > trade.keyDeadline, "deadline active");

        uint256 amount = trade.lockedFunds;
        trade.lockedFunds = 0;
        listing.status = Status.Refunded;
        trade.consumer.transfer(amount);

        emit FundWithdrawn(nameHash, listing.tradeId, msg.sender);
    }

    function submitRK(
        bytes32 nameHash,
        bytes calldata temporaryPublicKey,
        bytes calldata reEncryptionKey,
        bytes calldata metadata,
        bytes calldata producerSignature,
        uint256 expiration
    ) external {
        Listing storage listing = listings[nameHash];
        Trade storage trade = trades[listing.tradeId];
        require(msg.sender == listing.producer, "not producer");
        require(listing.status == Status.Locked, "invalid state");
        require(block.timestamp <= trade.keyDeadline, "key deadline passed");
        require(expiration > block.timestamp, "expired submission");

        _verifyMetadata(
            nameHash,
            listing.tradeId,
            trade.consumerPublicKey,
            expiration,
            metadata
        );
        _verifyProducerSignature(
            listing.producer,
            reEncryptionKey,
            temporaryPublicKey,
            metadata,
            producerSignature
        );

        keySubmissions[listing.tradeId] = KeySubmission({
            temporaryPublicKey: temporaryPublicKey,
            reEncryptionKey: reEncryptionKey,
            metadata: metadata,
            producerSignature: producerSignature,
            expiration: expiration
        });
        trade.evidenceDeadline = _min(expiration, block.timestamp + evidenceWindow);
        listing.status = Status.KeySubmitted;

        emit ReEncryptionKeySubmitted(nameHash, listing.tradeId);
    }

    function confirmReceipt(bytes32 nameHash) external {
        Listing storage listing = listings[nameHash];
        Trade storage trade = trades[listing.tradeId];
        require(msg.sender == trade.consumer, "not consumer");
        require(listing.status == Status.KeySubmitted, "invalid state");
        _settle(nameHash, listing, trade);
    }

    function finalizeAfterTimeout(bytes32 nameHash) external {
        Listing storage listing = listings[nameHash];
        Trade storage trade = trades[listing.tradeId];
        require(msg.sender == listing.producer, "not producer");
        require(listing.status == Status.KeySubmitted, "invalid state");
        require(block.timestamp > trade.evidenceDeadline, "evidence window active");
        _settle(nameHash, listing, trade);
    }

    function submitDispute(bytes32 nameHash, bytes calldata evidence) external {
        Listing storage listing = listings[nameHash];
        Trade storage trade = trades[listing.tradeId];
        require(msg.sender == trade.consumer, "not consumer");
        require(listing.status == Status.KeySubmitted, "invalid state");
        require(block.timestamp <= trade.evidenceDeadline, "evidence window closed");
        require(evidence.length > 0, "empty evidence");

        bytes32 evidenceHash = keccak256(evidence);
        disputes[listing.tradeId] = Dispute({
            evidenceHash: evidenceHash,
            submittedAt: block.timestamp
        });
        listing.status = Status.Disputed;

        emit DisputeSubmitted(nameHash, listing.tradeId, evidenceHash);
    }

    function _settle(bytes32 nameHash, Listing storage listing, Trade storage trade) internal {
        uint256 amount = trade.lockedFunds;
        trade.lockedFunds = 0;
        listing.status = Status.Settled;
        listing.producer.transfer(amount);
        emit SettlementComplete(nameHash, listing.tradeId);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _verifyMetadata(
        bytes32 nameHash,
        bytes32 tradeId,
        bytes storage consumerPublicKey,
        uint256 expiration,
        bytes calldata metadata
    ) private view {
        (
            bytes32 boundNameHash,
            bytes32 boundTradeId,
            bytes memory boundConsumerPublicKey,
            uint256 boundExpiration
        ) = abi.decode(metadata, (bytes32, bytes32, bytes, uint256));
        require(boundNameHash == nameHash, "wrong data name");
        require(boundTradeId == tradeId, "wrong trade");
        require(
            keccak256(boundConsumerPublicKey) == keccak256(consumerPublicKey),
            "wrong consumer key"
        );
        require(boundExpiration == expiration, "wrong expiration");
    }

    function _verifyProducerSignature(
        address producer,
        bytes calldata reEncryptionKey,
        bytes calldata temporaryPublicKey,
        bytes calldata metadata,
        bytes calldata producerSignature
    ) private pure {
        bytes32 submissionHash = keccak256(
            abi.encode(reEncryptionKey, temporaryPublicKey, metadata)
        );
        require(
            _recoverSigner(submissionHash, producerSignature) == producer,
            "invalid producer signature"
        );
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature)
        private
        pure
        returns (address)
    {
        require(signature.length == 65, "invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "invalid signature v");

        bytes32 messageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)
        );
        return ecrecover(messageHash, v, r, s);
    }
}
