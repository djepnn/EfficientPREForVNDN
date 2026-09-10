# Protocol-to-Code Mapping

| First-submission algorithm | Current paper phase | Contract function | Purpose |
| --- | --- | --- | --- |
| `SC_DataList` | Phase I | `listData` | Registers the encrypted data name, price, and integrity hashes. |
| `SC_Fund` | Phase II | `deposit` | Locks the consumer's payment and opens a transaction. |
| `SC_Trade` | Phase II | `submitRK` | Records the signed re-encryption key and its transaction metadata. |
| `SC_Trade` | Phase VI | `confirmReceipt` | Releases payment after successful consumer verification. |
| `SC_Trade` | Phase VI | `finalizeAfterTimeout` | Releases payment after an undisputed evidence window. |
| `SC_Dispute` | Phase VI | `submitDispute` | Records authenticated evidence and holds the transaction in dispute. |
| `SC_Fund` | Timeout recovery | `withdrawAfterKeyTimeout` | Refunds the consumer if the producer never submits a key. |

The off-chain NDN forwarding, token verification, PRE transformation, and
consumer decryption steps remain in the ndnSIM and client-side components and
are not implemented by the Solidity contract.

The current implementation intentionally differs from the first-submission
pseudocode where the resubmission corrected the workflow. In particular,
`submitRK` authenticates transaction-bound metadata but does not immediately
release funds. Settlement occurs only after consumer confirmation or expiry of
the evidence window, and a missing key has a separate refund path.
