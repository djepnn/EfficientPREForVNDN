import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createHash } from "node:crypto";
import solc from "solc";
import {
  AbiCoder,
  ContractFactory,
  HDNodeWallet,
  JsonRpcProvider,
  NonceManager,
  getBytes,
  keccak256,
  toUtf8Bytes,
} from "ethers";

function parseArgs(argv) {
  const result = {};
  for (const item of argv.slice(2)) {
    if (!item.startsWith("--") || !item.includes("=")) continue;
    const [key, ...parts] = item.slice(2).split("=");
    result[key] = parts.join("=");
  }
  return result;
}

function jsonValue(value) {
  return JSON.stringify(value, (_key, item) =>
    typeof item === "bigint" ? item.toString() : item
  );
}

function deterministicBytes(label, length) {
  const output = new Uint8Array(length);
  let offset = 0;
  let counter = 0;
  while (offset < length) {
    const chunk = getBytes(keccak256(toUtf8Bytes(`${label}:${counter}`)));
    const take = Math.min(chunk.length, length - offset);
    output.set(chunk.slice(0, take), offset);
    offset += take;
    counter += 1;
  }
  return output;
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function sampleStdev(values) {
  if (values.length < 2) return 0;
  const center = mean(values);
  return Math.sqrt(
    values.reduce((sum, value) => sum + (value - center) ** 2, 0) /
      (values.length - 1)
  );
}

function percentile(values, q) {
  const ordered = [...values].sort((a, b) => a - b);
  const position = (ordered.length - 1) * q;
  const lo = Math.floor(position);
  const hi = Math.min(lo + 1, ordered.length - 1);
  const fraction = position - lo;
  return ordered[lo] * (1 - fraction) + ordered[hi] * fraction;
}

async function main() {
  const args = parseArgs(process.argv);
  const sourcePath = path.resolve(args.source);
  const outDir = path.resolve(args["out-dir"]);
  const repetitions = Number(args.repetitions ?? 30);
  const rpcUrl = args.rpc ?? "http://127.0.0.1:8545";
  try {
    await fs.access(outDir);
    throw new Error(`Refusing to overwrite existing output directory: ${outDir}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  await fs.mkdir(path.join(outDir, "receipts"), { recursive: true });
  const source = await fs.readFile(sourcePath, "utf8");
  const compilerInput = {
    language: "Solidity",
    sources: { "VehicularDataTrading.sol": { content: source } },
    settings: {
      optimizer: { enabled: false, runs: 200 },
      outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "metadata"] } },
    },
  };
  const compilerOutput = JSON.parse(solc.compile(JSON.stringify(compilerInput)));
  const fatal = (compilerOutput.errors ?? []).filter((item) => item.severity === "error");
  if (fatal.length) throw new Error(jsonValue(fatal));
  const artifact = compilerOutput.contracts["VehicularDataTrading.sol"].VehicularDataTrading;
  const bytecode = `0x${artifact.evm.bytecode.object}`;
  await fs.writeFile(path.join(outDir, "compiler_input.json"), jsonValue(compilerInput) + "\n");
  await fs.writeFile(path.join(outDir, "compiler_output.json"), jsonValue(compilerOutput) + "\n");

  const provider = new JsonRpcProvider(rpcUrl);
  const network = await provider.getNetwork();
  const mnemonic = "test test test test test test test test test test test junk";
  const producer = new NonceManager(
    HDNodeWallet.fromPhrase(mnemonic, undefined, "m/44'/60'/0'/0/0").connect(provider)
  );
  const consumer = new NonceManager(
    HDNodeWallet.fromPhrase(mnemonic, undefined, "m/44'/60'/0'/0/1").connect(provider)
  );
  const outsider = new NonceManager(
    HDNodeWallet.fromPhrase(mnemonic, undefined, "m/44'/60'/0'/0/2").connect(provider)
  );
  const coder = AbiCoder.defaultAbiCoder();
  const transactionRows = [];
  const receiptLines = [];
  const securityRows = [];

  async function recordTx(workflow, iteration, operation, makeTransaction) {
    const startedAt = new Date().toISOString();
    const start = process.hrtime.bigint();
    const tx = await makeTransaction();
    const receipt = await tx.wait();
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
    const row = {
      workflow,
      iteration,
      operation,
      transaction_hash: receipt.hash,
      block_number: receipt.blockNumber,
      status: Number(receipt.status),
      gas_used: receipt.gasUsed.toString(),
      effective_gas_price: receipt.gasPrice?.toString() ?? "",
      latency_ms: durationMs,
      started_at: startedAt,
      ended_at: new Date().toISOString(),
    };
    transactionRows.push(row);
    receiptLines.push(jsonValue({ workflow, iteration, operation, receipt }));
    return receipt;
  }

  async function deploy(iteration) {
    const factory = new ContractFactory(artifact.abi, bytecode, producer);
    let deployed;
    const receipt = await recordTx("deployment", iteration, "deploy", async () => {
      deployed = await factory.deploy(60, 5);
      return deployed.deploymentTransaction();
    });
    await deployed.waitForDeployment();
    return { contract: deployed, receipt };
  }

  const deployedContracts = [];
  for (let iteration = 1; iteration <= repetitions; iteration += 1) {
    deployedContracts.push((await deploy(iteration)).contract);
  }
  const contract = deployedContracts[0];
  const price = 1_000_000_000_000_000n;

  async function prepareTrade(workflow, iteration, submitKey = true) {
    const label = `${workflow}:${iteration}`;
    const nameHash = keccak256(toUtf8Bytes(`name:${label}`));
    const packetHash = keccak256(toUtf8Bytes(`packet:${label}`));
    const dataHash = keccak256(toUtf8Bytes(`data:${label}`));
    const consumerPublicKey = deterministicBytes(`consumer-key:${label}`, 33);
    await recordTx(workflow, iteration, "listData", () =>
      contract.connect(producer).listData(nameHash, price, packetHash, dataHash)
    );
    await recordTx(workflow, iteration, "deposit", () =>
      contract.connect(consumer).deposit(nameHash, consumerPublicKey, { value: price })
    );
    const listing = await contract.listings(nameHash);
    const tradeId = listing.tradeId;
    let keyMaterial = null;
    if (submitKey) {
      const block = await provider.getBlock("latest");
      const expiration = BigInt(block.timestamp + 120);
      const temporaryPublicKey = deterministicBytes(`temporary-key:${label}`, 33);
      const reEncryptionKey = deterministicBytes(`rk:${label}`, 32);
      const metadata = coder.encode(
        ["bytes32", "bytes32", "bytes", "uint256"],
        [nameHash, tradeId, consumerPublicKey, expiration]
      );
      const submissionHash = keccak256(
        coder.encode(
          ["bytes", "bytes", "bytes"],
          [reEncryptionKey, temporaryPublicKey, metadata]
        )
      );
      const signature = await producer.signMessage(getBytes(submissionHash));
      await recordTx(workflow, iteration, "submitRK", () =>
        contract
          .connect(producer)
          .submitRK(
            nameHash,
            temporaryPublicKey,
            reEncryptionKey,
            metadata,
            signature,
            expiration
          )
      );
      keyMaterial = {
        nameHash,
        tradeId,
        consumerPublicKey,
        expiration,
        temporaryPublicKey,
        reEncryptionKey,
        metadata,
        signature,
      };
    }
    return { nameHash, tradeId, consumerPublicKey, keyMaterial };
  }

  for (let iteration = 1; iteration <= repetitions; iteration += 1) {
    const trade = await prepareTrade("consumer-confirmation", iteration, true);
    await recordTx("consumer-confirmation", iteration, "confirmReceipt", () =>
      contract.connect(consumer).confirmReceipt(trade.nameHash)
    );
  }
  for (let iteration = 1; iteration <= repetitions; iteration += 1) {
    const trade = await prepareTrade("timeout-finalization", iteration, true);
    await provider.send("evm_increaseTime", [6]);
    await provider.send("evm_mine", []);
    await recordTx("timeout-finalization", iteration, "finalizeAfterTimeout", () =>
      contract.connect(producer).finalizeAfterTimeout(trade.nameHash)
    );
  }
  for (let iteration = 1; iteration <= repetitions; iteration += 1) {
    const trade = await prepareTrade("dispute", iteration, true);
    const evidence = deterministicBytes(`evidence:${iteration}`, 96);
    await recordTx("dispute", iteration, "submitDispute", () =>
      contract.connect(consumer).submitDispute(trade.nameHash, evidence)
    );
  }
  for (let iteration = 1; iteration <= repetitions; iteration += 1) {
    const trade = await prepareTrade("key-timeout-refund", iteration, false);
    await provider.send("evm_increaseTime", [61]);
    await provider.send("evm_mine", []);
    await recordTx("key-timeout-refund", iteration, "withdrawAfterKeyTimeout", () =>
      contract.connect(consumer).withdrawAfterKeyTimeout(trade.nameHash)
    );
  }

  async function expectRevert(testName, makeTransaction) {
    let passed = false;
    let errorName = "";
    let errorMessage = "";
    try {
      const tx = await makeTransaction();
      await tx.wait();
    } catch (error) {
      passed = true;
      errorName = error.name ?? "Error";
      errorMessage = String(error.shortMessage ?? error.message ?? error).slice(0, 500);
      // NonceManager reserves a nonce before estimateGas. An expected revert
      // does not consume it on chain, so resynchronize all local signers before
      // the next positive-control transaction.
      producer.reset();
      consumer.reset();
      outsider.reset();
    }
    securityRows.push({ test: testName, expected: "revert", passed, error_name: errorName, error_message: errorMessage });
    if (!passed) throw new Error(`Negative workflow test did not revert: ${testName}`);
  }

  const negative = await prepareTrade("security-negative", 1, false);
  const block = await provider.getBlock("latest");
  const expiration = BigInt(block.timestamp + 120);
  const temporaryPublicKey = deterministicBytes("negative:temporary", 33);
  const reEncryptionKey = deterministicBytes("negative:rk", 32);
  const validMetadata = coder.encode(
    ["bytes32", "bytes32", "bytes", "uint256"],
    [negative.nameHash, negative.tradeId, negative.consumerPublicKey, expiration]
  );
  const digest = keccak256(coder.encode(["bytes", "bytes", "bytes"], [reEncryptionKey, temporaryPublicKey, validMetadata]));
  const validSignature = await producer.signMessage(getBytes(digest));
  const wrongName = keccak256(toUtf8Bytes("wrong-name"));
  const wrongNameMetadata = coder.encode(
    ["bytes32", "bytes32", "bytes", "uint256"],
    [wrongName, negative.tradeId, negative.consumerPublicKey, expiration]
  );
  await expectRevert("wrong-data-name-binding", () =>
    contract.connect(producer).submitRK(negative.nameHash, temporaryPublicKey, reEncryptionKey, wrongNameMetadata, validSignature, expiration)
  );
  await expectRevert("non-producer-key-submission", () =>
    contract.connect(outsider).submitRK(negative.nameHash, temporaryPublicKey, reEncryptionKey, validMetadata, validSignature, expiration)
  );
  const badSignature = await outsider.signMessage(getBytes(digest));
  await expectRevert("invalid-producer-signature", () =>
    contract.connect(producer).submitRK(negative.nameHash, temporaryPublicKey, reEncryptionKey, validMetadata, badSignature, expiration)
  );
  await recordTx("security-negative", 1, "submitRK-valid-control", () =>
    contract.connect(producer).submitRK(negative.nameHash, temporaryPublicKey, reEncryptionKey, validMetadata, validSignature, expiration)
  );
  await expectRevert("replayed-key-submission", () =>
    contract.connect(producer).submitRK(negative.nameHash, temporaryPublicKey, reEncryptionKey, validMetadata, validSignature, expiration)
  );
  await expectRevert("unauthorized-confirmation", () =>
    contract.connect(outsider).confirmReceipt(negative.nameHash)
  );
  await expectRevert("empty-dispute-evidence", () =>
    contract.connect(consumer).submitDispute(negative.nameHash, "0x")
  );
  await expectRevert("early-timeout-finalization", () =>
    contract.connect(producer).finalizeAfterTimeout(negative.nameHash)
  );

  const txFields = [
    "workflow", "iteration", "operation", "transaction_hash", "block_number", "status",
    "gas_used", "effective_gas_price", "latency_ms", "started_at", "ended_at",
  ];
  const csvEscape = (value) => {
    const text = String(value ?? "");
    return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
  };
  const toCsv = (rows, fields) => [fields.join(","), ...rows.map((row) => fields.map((field) => csvEscape(row[field])).join(","))].join("\n") + "\n";
  await fs.writeFile(path.join(outDir, "transactions_raw.csv"), toCsv(transactionRows, txFields));
  await fs.writeFile(path.join(outDir, "receipts", "receipts.jsonl"), receiptLines.join("\n") + "\n");
  const securityFields = ["test", "expected", "passed", "error_name", "error_message"];
  await fs.writeFile(path.join(outDir, "security_workflow_tests.csv"), toCsv(securityRows, securityFields));

  const groups = new Map();
  for (const row of transactionRows) {
    const key = `${row.workflow}|${row.operation}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  const summaryRows = [];
  for (const [key, rows] of [...groups.entries()].sort()) {
    const [workflow, operation] = key.split("|");
    const gas = rows.map((row) => Number(row.gas_used));
    const latency = rows.map((row) => Number(row.latency_ms));
    summaryRows.push({
      workflow,
      operation,
      n: rows.length,
      gas_mean: mean(gas),
      gas_stdev: sampleStdev(gas),
      gas_min: Math.min(...gas),
      gas_max: Math.max(...gas),
      latency_mean_ms: mean(latency),
      latency_stdev_ms: sampleStdev(latency),
      latency_median_ms: percentile(latency, 0.5),
      latency_p95_ms: percentile(latency, 0.95),
      latency_p99_ms: percentile(latency, 0.99),
    });
  }
  const summaryFields = Object.keys(summaryRows[0]);
  await fs.writeFile(path.join(outDir, "summary.csv"), toCsv(summaryRows, summaryFields));
  const metadata = {
    started_at: transactionRows[0]?.started_at,
    ended_at: new Date().toISOString(),
    repetitions,
    rpc_url: rpcUrl,
    chain_id: network.chainId.toString(),
    ganache: "7.9.2",
    node: process.version,
    ethers: "6.17.0",
    solc: solc.version(),
    optimizer_enabled: false,
    contract_source: sourcePath,
    contract_source_sha256: createHash("sha256").update(source).digest("hex"),
    deployment_count: repetitions,
    negative_tests: securityRows.length,
    negative_tests_passed: securityRows.filter((row) => row.passed).length,
  };
  await fs.writeFile(path.join(outDir, "metadata.json"), jsonValue(metadata) + "\n");
  console.log(jsonValue({ output: outDir, transactions: transactionRows.length, security_tests: securityRows.length }));
}

await main();
