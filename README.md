# EfficientPREForVNDN: Blockchain Reference Implementation

This artifact contains the Solidity implementation of the on-chain procedures
described in *Proactive Key Distribution for Efficient Data Trading in
NDN-based Vehicular Networks*.

The code covers the procedures represented by the smart-contract algorithms in
the first-submission manuscript: data listing, fund locking, signed
re-encryption-key submission, consumer confirmation, timeout settlement,
key-timeout refund, and dispute recording. The current manuscript describes the
same workflow in prose rather than retaining the pseudocode blocks.

## Repository contents

- `contracts/VehicularDataTrading.sol`: the measured Solidity contract.
- `scripts/contract_benchmark_v1.mjs`: the exact benchmark and negative-test
  driver used for the reported Ganache campaign.
- `docs/protocol-mapping.md`: mapping from paper phases to contract functions.
- `results/`: the retained transaction table, local-chain receipts, security
  test outcomes, summaries, and independent validation record.
- `package.json` and `package-lock.json`: exact JavaScript dependencies used by
  the benchmark driver.

The SHA-256 digest of the contract used in the validated run is
`9831334c06a4cd2aed0c8ce4c670340f7d86b187d62f8c428d978331c674c52c`.

## Scope and limitations

This is real research code, not production software. It has not undergone a
production security audit. The contract authenticates and records an ordinary,
single-hop, unidirectional PRE key submission; it does not implement VPRE,
`ProofGen`, or `VerifyRK`, and it does not claim public verification of PRE-key
correctness.

The artifact is deliberately dependency-bound, not deliberately broken. It
does not bundle an Ubuntu virtual machine, a blockchain node, credentials,
private keys, or a turnkey container. Re-execution requires the documented
Node.js, Solidity, ethers, and Ganache environment. The mnemonic in the
benchmark is Ganache's public deterministic development mnemonic and must never
be used on a public network or for real funds.

## Validated environment

- Ubuntu 20.04.6 LTS
- Node.js 20.20.2 and npm 10.8.2
- Ganache 7.9.2, local chain ID 1337
- Solidity compiler 0.8.24, optimizer disabled
- ethers 6.17.0

## Re-running the contract campaign

Install the locked JavaScript dependencies:

```bash
npm ci
```

Start a local Ganache instance in one terminal:

```bash
ganache --server.host 127.0.0.1 --server.port 8545 \
  --wallet.mnemonic "test test test test test test test test test test test junk" \
  --chain.chainId 1337 --miner.instamine eager
```

Run the measured contract workflow in another terminal. Choose a new output
directory because the driver refuses to overwrite existing evidence:

```bash
node scripts/contract_benchmark_v1.mjs \
  --source=contracts/VehicularDataTrading.sol \
  --out-dir=run_001 --repetitions=30 \
  --rpc=http://127.0.0.1:8545
```

Gas usage is an EVM execution measure. Local Ganache wall-clock receipt latency
is not a public-chain confirmation or finality estimate.

See `UPLOAD_TO_GITHUB.md` for publication steps.
