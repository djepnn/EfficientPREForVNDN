# Algorithm-to-code mapping

The four algorithm families follow the first manuscript's organization. Their implementations below use the revised transaction-specific escrow and dispute workflow rather than immediate settlement on key submission.

| Algorithm family | Implemented functions | Role in the revised workflow |
| --- | --- | --- |
| SC_DataList | `listData` | Register producer, price, plaintext hash and packet commitment. Reject duplicate listings and empty commitments. |
| SC_Fund | `deposit` | Accept exact payment and bind a separate purchase ID to the listing, consumer and recipient key. |
| SC_Fund | `withdrawAfterKeyTimeout` | Credit a refund when a funded purchase receives no key before its deadline. |
| SC_Fund | `withdrawCredit` | Withdraw accumulated credit with a re-entry guard. Crediting and withdrawal are separate operations. |
| SC_Trade | `submissionDigest`, `submitRK` | Bind the key bytes, listing, consumer, recipient key, purchase ID, expiry, chain and contract. Authenticate submission and keep payment locked. |
| SC_Trade | `confirmReceipt`, `finalizeAfterTimeout` | Create producer credit following consumer confirmation or an unchallenged evidence-window expiry. |
| SC_Dispute | `submitDispute` | Record the consumer's evidence commitment within the evidence window and freeze ordinary settlement. |
| SC_Dispute | `adjudicate` | Apply the trusted adjudicator's recorded payment/refund decision within the arbitration window. |
| SC_Dispute | `refundAfterArbitrationTimeout` | Credit a consumer refund if arbitration times out. |
| Shared bookkeeping | `finish` | Clear the escrowed amount, record the terminal state and credit exactly one recipient. Entry-point guards control which transitions may call it. |
| Initialization | constructor | Set the adjudicator and the key, evidence and arbitration windows. |

`name` identifies a listing. `id` identifies a purchase, so concurrent purchases of one listing do not share an escrow entry. `consumerKey` is the purchase's recipient PRE public key, not the off-chain request-signing credential. `rk` stores serialized key material. Signature authentication does not establish its decryption correctness.

The `recover` hook must implement the measured contract's signed-message recovery semantics and canonical-signature checks. Its implementation is not part of this excerpt. The source contains no mock signer or bypass of the `submitRK` identity check.

The contract records an evidence hash and a decision hash, not the confidential adjudication computation. A timeout is a settlement rule, not proof of delivery. The excerpt does not implement public PRE verification or unconditional atomic exchange.

## Implementation boundary

The source compiles with Solidity 0.8.24 as an **abstract contract**. It does not produce deployable creation bytecode by itself. The `recover` signature-recovery function is an explicit integration hook, not an empty implementation or a permissive signature check. Its required behavior is documented in the source. The original service-facing getters are also omitted.

The package does not include deployment/account configuration, the trusted adjudicator's off-chain evidence processing, PRE generation or transformation clients, RSU/CN request handling, networking strategies, simulations, or experiment drivers. It is an algorithm excerpt, not a complete trading application or independently runnable reproduction bundle.

## Validated environment

- Ubuntu 20.04.6 LTS
- Node.js 20.20.2 and npm 10.8.2
- Ganache 7.9.2, local chain ID 1337
- Solidity compiler 0.8.24, optimizer disabled
- ethers 6.17.0
- 
