# FreightGuard — Privacy‑Preserving Logistics SLA 📦🔒

A single‑page dApp + Solidity smart contract to manage encrypted shipment metadata and verify SLA compliance entirely
on‑chain with Zama FHEVM. Cargo/route/deadline stay private; only the final result (delivered on time or not) can be
made publicly decryptable.

---

## ✨ Features

- 🔐 **Private metadata** — shipper encrypts `cargoTag`, `routeTag`, `deadlineTs` and submits them as external inputs;
  data never appears in plaintext on chain.
- 🧮 **On‑chain FHE checks** — contract computes `onTime = (deliveredAt ≤ deadlineTs)` using Zama FHEVM (`FHE.le`,
  `FHE.asEuint64`) without revealing timestamps.
- 🧑‍🤝‍🧑 **Parties** — shipper (msg.sender), carrier, consignee; any party can add encrypted meta, mark delivery, and grant
  viewers.
- 🪪 **Granular ACL** — uses `FHE.allow`, `FHE.allowThis`, and `FHE.makePubliclyDecryptable` for safe access;
  per‑address viewing via Relayer **userDecrypt**.
- 🖥️ **Polished SPA** — MetaMask connect, network auto‑switch to Sepolia, animated “encryption scan”, live logs &
  results.
- 🔔 **Event handles** — emits `MetaIngested` and `DeliveryMarked` with decryptable handles so frontends can fetch &
  (re)decrypt.

---

## 🛠️ Tech Stack

- **Solidity** `^0.8.24`
- **Zama FHEVM** `@fhevm/solidity/lib/FHE.sol` (+ `SepoliaConfig`)
- **Relayer SDK (JS)** `@zama-fhe/relayer-sdk` (CDN)
- **Ethers** v6.15.0 (ESM)
- **Network** Sepolia testnet (`11155111`)
- **Relayer** `https://relayer.testnet.zama.cloud`
- **KMS (Sepolia)** `0x1364cBBf2cDF5032C47d8226a6f6FBD2AFCDacAC`

> ⚠️ Only **official** Zama libraries/SDK are used. No deprecated packages (e.g. `@fhevm-js/relayer`), no unsupported
> methods.

---

## 🚀 Quick Start

### Prerequisites

- Node.js 18+
- MetaMask (Sepolia + test ETH)
- Any static dev server **with COOP/COEP** headers (for WASM workers)

### Install & Compile

```bash
npm install
npx hardhat compile
```

### Deploy (example: Sepolia)

```bash
npx hardhat run scripts/deploy.ts --network sepolia
```

Copy the deployed contract address and update `CONTRACT_ADDRESS` inside `index.html`.

### Run Frontend (with COOP/COEP)

```bash
node server.js
# open http://localhost:3000
```

> The SPA is a single `index.html` (ESM module) using CDN builds of Relayer SDK & Ethers.

---

## 🧩 Usage

1. **Connect** MetaMask → auto‑prompts to switch to Sepolia if needed.
2. **Create shipment** — provide `shipmentId`, `carrier`, `consignee`.
3. **Ingest encrypted metadata** — enter `cargoTag`, `routeTag` (as opaque numbers/ids), `deadlineTs` (UNIX seconds).
   Frontend packs & encrypts via Relayer `createEncryptedInput(...)`, sends raw handles + proof to contract.
4. **Mark delivery** — any party confirms delivery; contract records encrypted `deliveredAt` and computes encrypted
   `slaOk = (deliveredAt ≤ deadlineTs)`; `slaOk` is marked **publicly decryptable**.
5. **Grant viewer (optional)** — allow an external address to decrypt metadata/results.
6. **View details** — SPA calls `getParticipants`, `getEncryptedMetaHandles`, `getResultHandles` and uses
   **userDecrypt** (EIP‑712) to decrypt allowed values client‑side.

---

## 🔌 Frontend Flow (Relayer SDK)

- **Init**: `await initSDK(); const relayer = await createInstance({...SepoliaConfig, relayerUrl})`.
- **Encrypt input**:
  `const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, user); buf.add256(cargoTag); buf.add256(routeTag); buf.add64(deadlineTs); const { handles, inputProof } = await buf.encrypt();`
- **Contract call**:
  `ingestEncryptedMeta(shipmentId, handles[0], inputProof, handles[1], inputProof, handles[2], inputProof)`.
- **User decryption**: generate ephemeral keypair, create EIP‑712 token over `{publicKey, contracts, start, validDays}`,
  sign via wallet, then `relayer.userDecrypt([{ handle, contractAddress }], ...)` → plaintexts for UI only.
- **Public decryption**: the contract uses `FHE.makePubliclyDecryptable(onTime)` so anyone may query final SLA boolean
  via handle.

---

## 🧠 Smart Contract Overview

**File:** `contracts/PrivateLogisticsSLA.sol`

- **State** per `shipmentId`:
  - Parties: `shipper`, `carrier`, `consignee`
  - Encrypted meta: `euint256 cargoTag`, `euint256 routeTag`, `euint64 deadlineTs` (after `fromExternal`)
  - Results: `bool deliveredFlag`, `euint64 deliveredAt`, `ebool slaOk`
  - Flags: `haveMeta`, `exists`

- **FHE ops used**
  - Construction: `FHE.fromExternal(externalEuint*, proof)`
  - Casting: `FHE.asEuint64(uint64(block.timestamp))`
  - Compare: `FHE.le(deliveredAt, deadlineTs)`
  - ACL: `FHE.allow`, `FHE.allowThis`
  - Public result: `FHE.makePubliclyDecryptable(onTime)`

> ℹ️ `euint256` is used as an **opaque tag** (no arithmetic). In FHEVM, `euint256` & `eaddress` only support
> equality/bitwise ops — avoid `add/sub/mul/div` on them.

### Public API

```solidity
function version() external pure returns (string memory);
function createShipment(uint256 shipmentId, address carrier, address consignee) external;
function ingestEncryptedMeta(
  uint256 shipmentId,
  bytes32 cargoTagExtRaw,
  bytes calldata cargoProof,
  bytes32 routeTagExtRaw,
  bytes calldata routeProof,
  bytes32 deadlineTsExtRaw,
  bytes calldata deadlineProof
) external;
function markDelivered(uint256 shipmentId) external;
function grantViewer(uint256 shipmentId, address viewer) external;
function getParticipants(
  uint256 shipmentId
) external view returns (address shipper, address carrier, address consignee, bool delivered, bool haveMeta);
function getEncryptedMetaHandles(
  uint256 shipmentId
) external view returns (bytes32 cargoTagH, bytes32 routeTagH, bytes32 deadlineTsH);
function getResultHandles(
  uint256 shipmentId
) external view returns (bool delivered, bytes32 deliveredAtH, bytes32 slaOkH);
```

### Events

- `ShipmentCreated(shipmentId, shipper, carrier, consignee)`
- `MetaIngested(shipmentId, cargoTagHandle, routeTagHandle, deadlineHandle)`
- `DeliveryMarked(shipmentId, deliveredAtHandle, slaOkHandle)`
- `ViewerGranted(shipmentId, viewer)`

---

## 🧪 Test & Dev Tips

- Use small integer tags for `cargoTag/routeTag` during testing (e.g., `12345`, `67890`).
- If **userDecrypt** fails with “Handle not found”, ensure:
  - Metadata was ingested and events confirmed.
  - Your address was granted via `FHE.allow(...)` (party or viewer).
  - You signed a fresh EIP‑712 token that includes the **contract address** and hasn’t expired (`validDays`).

- COOP/COEP headers are **required** for the Relayer WASM workers.

---

## 📁 Project Structure

```bash
.
├─ index.html                    # Full SPA (frontend)
├─ contracts/
│  └─ PrivateLogisticsSLA.sol   # FHEVM smart contract
├─ server.js                     # Dev server with COOP/COEP headers
├─ scripts/, tasks/, test/       # Optional Hardhat helpers
├─ package.json
└─ README.md
```

---

## 🔒 Security Notes

- Encrypted fields are never revealed; only the final `slaOk` can be made publicly decryptable.
- Access is enforced with FHE ACL primitives (`allow`, `allowThis`).
- This is a **demo**; not audited. Don’t use on mainnet.
- Never commit private keys or mnemonics.

---

## 🔧 Config Constants (in `index.html`)

- `CONTRACT_ADDRESS` — your deployed `PrivateLogisticsSLA`
- `RELAYER_URL` — e.g., `https://relayer.testnet.zama.cloud`
- `KMS_ADDRESS` — Sepolia KMS address (`0x1364...cAC`)
- Chain ID is enforced to **Sepolia (11155111)** in the UI

---

## 📚 References

- Zama **FHEVM Solidity** Library
- Zama **Relayer SDK** Guides
- Zama **Protocol & Whitepaper**
- Ethers v6 (ESM) docs

> Tip: See Zama docs for `externalEuintX` inputs, ACL patterns, and `userDecrypt` EIP‑712 flow.

---
