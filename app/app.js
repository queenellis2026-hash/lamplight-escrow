// Lamplight Escrow — front-end wiring (Arc mainnet / testnet).
// No private keys anywhere in this file. The user connects their own wallet
// (MetaMask / Rabby); signing happens in the wallet, never here.
// Amounts are native USDC on Arc. Arc docs describe native USDC as 18
// decimals; the UI formats with 18 decimals and flags that as a display
// assumption — the contract itself is decimal-agnostic (it moves msg.value).
"use strict";

const ABI = [{"type":"receive","stateMutability":"payable"},{"type":"function","name":"ARBITER_TIMEOUT","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"CHALLENGE_PERIOD","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"MAX_DEADLINE_EXTENSION","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"REJECT_CURE_PERIOD","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"REVIEW_PERIOD","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"createEscrow","inputs":[{"name":"payee","type":"address","internalType":"address"},{"name":"deadline","type":"uint256","internalType":"uint256"},{"name":"arbiter","type":"address","internalType":"address"},{"name":"backupArbiter","type":"address","internalType":"address"},{"name":"bondAmount","type":"uint96","internalType":"uint96"}],"outputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"stateMutability":"payable"},{"type":"function","name":"createEscrow","inputs":[{"name":"payee","type":"address","internalType":"address"},{"name":"deadline","type":"uint256","internalType":"uint256"}],"outputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"stateMutability":"payable"},{"type":"function","name":"createEscrow","inputs":[{"name":"payee","type":"address","internalType":"address"},{"name":"deadline","type":"uint256","internalType":"uint256"},{"name":"arbiter","type":"address","internalType":"address"}],"outputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"stateMutability":"payable"},{"type":"function","name":"deliver","inputs":[{"name":"id","type":"uint256","internalType":"uint256"},{"name":"workHash","type":"bytes32","internalType":"bytes32"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"escalateDispute","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"extendDeadline","inputs":[{"name":"id","type":"uint256","internalType":"uint256"},{"name":"extraSeconds","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"finalizeResolution","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"getEscrow","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[{"name":"","type":"tuple","internalType":"struct LamplightEscrow.Escrow","components":[{"name":"payer","type":"address","internalType":"address"},{"name":"payee","type":"address","internalType":"address"},{"name":"amount","type":"uint96","internalType":"uint96"},{"name":"deadline","type":"uint40","internalType":"uint40"},{"name":"deliveredAt","type":"uint40","internalType":"uint40"},{"name":"rejectedAt","type":"uint40","internalType":"uint40"},{"name":"settled","type":"bool","internalType":"bool"},{"name":"rejectedOnce","type":"bool","internalType":"bool"},{"name":"deadlineExtended","type":"bool","internalType":"bool"},{"name":"escalated","type":"bool","internalType":"bool"},{"name":"challengeOpen","type":"bool","internalType":"bool"},{"name":"workHash","type":"bytes32","internalType":"bytes32"},{"name":"arbiter","type":"address","internalType":"address"},{"name":"backupArbiter","type":"address","internalType":"address"},{"name":"bondAmount","type":"uint96","internalType":"uint96"},{"name":"escalatedAt","type":"uint40","internalType":"uint40"},{"name":"resolvedAt","type":"uint40","internalType":"uint40"},{"name":"resolvedToPayee","type":"bool","internalType":"bool"},{"name":"bondStaked","type":"bool","internalType":"bool"},{"name":"challenged","type":"bool","internalType":"bool"}]}],"stateMutability":"view"},{"type":"function","name":"lifecycleStatus","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[{"name":"","type":"uint8","internalType":"enum LamplightEscrow.Lifecycle"}],"stateMutability":"view"},{"type":"function","name":"nextEscrowId","inputs":[],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"pendingWithdrawals","inputs":[{"name":"","type":"address","internalType":"address"}],"outputs":[{"name":"","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"reEscalate","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"refund","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"refundAfterRejection","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"rejectDelivery","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"release","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"resolveDispute","inputs":[{"name":"id","type":"uint256","internalType":"uint256"},{"name":"releaseToPayee","type":"bool","internalType":"bool"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"resolveDisputeTimeout","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"reviewWindows","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[{"name":"reviewEnd","type":"uint256","internalType":"uint256"},{"name":"cureEnd","type":"uint256","internalType":"uint256"}],"stateMutability":"view"},{"type":"function","name":"splitPayment","inputs":[{"name":"recipients","type":"address[]","internalType":"address[]"},{"name":"sharesBps","type":"uint256[]","internalType":"uint256[]"}],"outputs":[],"stateMutability":"payable"},{"type":"function","name":"stakeBond","inputs":[{"name":"id","type":"uint256","internalType":"uint256"}],"outputs":[],"stateMutability":"payable"},{"type":"function","name":"withdraw","inputs":[],"outputs":[],"stateMutability":"nonpayable"},{"type":"function","name":"withdrawTo","inputs":[{"name":"to","type":"address","internalType":"address"}],"outputs":[],"stateMutability":"nonpayable"},{"type":"event","name":"BondForfeited","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"BondReturned","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"arbiter","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"BondStaked","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"arbiter","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"Credited","inputs":[{"name":"account","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"DeadlineExtended","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"newDeadline","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"Delivered","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"workHash","type":"bytes32","indexed":false,"internalType":"bytes32"}],"anonymous":false},{"type":"event","name":"DeliveryRejected","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"rejectedWorkHash","type":"bytes32","indexed":false,"internalType":"bytes32"}],"anonymous":false},{"type":"event","name":"DisputeChallenged","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"challenger","type":"address","indexed":true,"internalType":"address"},{"name":"backupArbiter","type":"address","indexed":true,"internalType":"address"}],"anonymous":false},{"type":"event","name":"DisputeEscalated","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"arbiter","type":"address","indexed":true,"internalType":"address"}],"anonymous":false},{"type":"event","name":"DisputeResolved","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"arbiter","type":"address","indexed":true,"internalType":"address"},{"name":"releasedToPayee","type":"bool","indexed":false,"internalType":"bool"}],"anonymous":false},{"type":"event","name":"DisputeTimedOut","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"caller","type":"address","indexed":true,"internalType":"address"}],"anonymous":false},{"type":"event","name":"EscrowCreated","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"payee","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"},{"name":"deadline","type":"uint256","indexed":false,"internalType":"uint256"},{"name":"arbiter","type":"address","indexed":false,"internalType":"address"},{"name":"backupArbiter","type":"address","indexed":false,"internalType":"address"},{"name":"bondAmount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"Refunded","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"Released","inputs":[{"name":"id","type":"uint256","indexed":true,"internalType":"uint256"},{"name":"payee","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"SplitPaid","inputs":[{"name":"payer","type":"address","indexed":true,"internalType":"address"},{"name":"total","type":"uint256","indexed":false,"internalType":"uint256"},{"name":"recipientCount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false},{"type":"event","name":"Withdrawn","inputs":[{"name":"account","type":"address","indexed":true,"internalType":"address"},{"name":"amount","type":"uint256","indexed":false,"internalType":"uint256"}],"anonymous":false}];

const NETWORKS = {
  mainnet: {
    chainId: 5042,
    chainIdHex: "0x13b2",
    name: "Arc Mainnet",
    rpc: "https://rpc.mainnet.arc.io",
    explorer: "https://explorer.arc.io",
    currency: "USDC",
  },
  testnet: {
    chainId: 5042002,
    chainIdHex: "0x4cef52",
    name: "Arc Testnet",
    rpc: "https://rpc.testnet.arc.io",
    explorer: "https://explorer.testnet.arc.io",
    currency: "USDC",
  },
};

let provider = null;
let signer = null;
let account = null;

const $ = (id) => document.getElementById(id);

function net() {
  return NETWORKS[$("network").value];
}

function contract() {
  const addr = $("contract").value.trim();
  if (!ethers.isAddress(addr)) throw new Error("Set a valid contract address first.");
  if (!signer) throw new Error("Connect your wallet first.");
  return new ethers.Contract(addr, ABI, signer);
}

function setLine(id, msg, ok) {
  const el = $(id);
  el.innerHTML = msg;
  el.className = "status " + (ok === true ? "ok" : ok === false ? "bad" : "");
}

async function txDone(promise, lineId, label) {
  setLine(lineId, label + " — waiting for confirmation…");
  const tx = await promise;
  setLine(lineId, label + " sent: <span class='mono'>" + tx.hash + "</span> — waiting…");
  const rc = await tx.wait();
  setLine(
    lineId,
    label + " confirmed in block " + rc.blockNumber +
      " — <a target='_blank' rel='noopener' href='" + net().explorer + "/tx/" + tx.hash + "'>view on explorer</a>",
    true
  );
  return rc;
}

$("connect").addEventListener("click", async () => {
  try {
    if (!window.ethereum) throw new Error("No wallet found in this browser. Install MetaMask or Rabby, then reload.");
    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);
    const want = net();
    const cur = await provider.getNetwork();
    if (Number(cur.chainId) !== want.chainId) {
      try {
        await provider.send("wallet_switchEthereumChain", [{ chainId: want.chainIdHex }]);
      } catch (e) {
        if (e.code !== 4902) throw e;
        await $("addnet").click();
      }
    }
    signer = await provider.getSigner();
    account = await signer.getAddress();
    const bal = await provider.getBalance(account);
    $("walletline").innerHTML =
      "Connected as <span class='mono'>" + account + "</span> on " + want.name +
      " — balance " + ethers.formatUnits(bal, 18) + " USDC.";
    setLine("netstatus", "Connected to " + want.name + " (chain " + want.chainId + ").", true);
  } catch (e) {
    setLine("netstatus", "Connection failed: " + e.message, false);
  }
});

$("addnet").addEventListener("click", async () => {
  try {
    if (!window.ethereum) throw new Error("No wallet found in this browser.");
    const w = net();
    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [{
        chainId: w.chainIdHex, chainName: w.name,
        rpcUrls: [w.rpc], blockExplorerUrls: [w.explorer],
        nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
      }],
    });
    setLine("netstatus", w.name + " added to your wallet.", true);
  } catch (e) {
    setLine("netstatus", "Could not add network: " + e.message, false);
  }
});

$("network").addEventListener("change", () => {
  setLine("netstatus", "Network set to " + net().name + ". Reconnect your wallet to switch chains.");
  provider = null; signer = null; account = null;
  $("walletline").textContent = "";
});

$("create").addEventListener("click", async () => {
  try {
    const c = contract();
    const payee = $("payee").value.trim();
    if (!ethers.isAddress(payee)) throw new Error("Enter a valid payee address.");
    const amount = ethers.parseUnits($("amount").value || "0", 18);
    if (amount === 0n) throw new Error("Enter an amount greater than 0.");
    const days = parseInt($("days").value || "7", 10);
    const deadline = Math.floor(Date.now() / 1000) + days * 86400;
    await txDone(c.createEscrow(payee, deadline, { value: amount }), "createline", "Escrow created");
  } catch (e) {
    setLine("createline", "Failed: " + (e.reason || e.message), false);
  }
});

function escrowId() {
  const id = parseInt($("escrowId").value || "0", 10);
  if (isNaN(id) || id < 0) throw new Error("Enter a valid escrow ID.");
  return id;
}

$("deliver").addEventListener("click", async () => {
  try {
    const c = contract();
    let h = $("workhash").value.trim();
    if (!h) throw new Error("Enter a work hash or some text to hash.");
    if (!/^0x[0-9a-fA-F]{64}$/.test(h)) h = ethers.keccak256(ethers.toUtf8Bytes(h));
    await txDone(c.deliver(escrowId(), h), "actionline", "Delivery marked");
  } catch (e) {
    setLine("actionline", "Failed: " + (e.reason || e.message), false);
  }
});

$("release").addEventListener("click", async () => {
  try {
    await txDone(contract().release(escrowId()), "actionline", "Released to payee");
  } catch (e) {
    setLine("actionline", "Failed: " + (e.reason || e.message), false);
  }
});

$("refund").addEventListener("click", async () => {
  try {
    await txDone(contract().refund(escrowId()), "actionline", "Refunded to payer");
  } catch (e) {
    setLine("actionline", "Failed: " + (e.reason || e.message), false);
  }
});

$("lookup").addEventListener("click", async () => {
  try {
    const c = contract();
    const e = await c.getEscrow(escrowId());
    $("escrowout").innerHTML =
      "payer: " + e.payer + "<br>payee: " + e.payee +
      "<br>amount: " + ethers.formatUnits(e.amount, 18) + " USDC" +
      "<br>deadline: " + new Date(Number(e.deadline) * 1000).toLocaleString() +
      "<br>workHash: " + e.workHash +
      "<br>delivered: " + e.delivered + " · settled: " + e.settled;
    setLine("actionline", "Escrow found.", true);
  } catch (err) {
    setLine("actionline", "Lookup failed: " + (err.reason || err.message), false);
  }
});

$("split").addEventListener("click", async () => {
  try {
    const c = contract();
    const addrs = $("splitAddrs").value.split("\n").map((s) => s.trim()).filter(Boolean);
    const shares = $("splitShares").value.split("\n").map((s) => parseInt(s.trim(), 10)).filter((n) => !isNaN(n));
    if (addrs.length === 0 || addrs.length !== shares.length) throw new Error("Recipients and shares must line up, one per line.");
    if (addrs.some((a) => !ethers.isAddress(a))) throw new Error("One of the recipient addresses is invalid.");
    if (shares.reduce((a, b) => a + b, 0) !== 10000) throw new Error("Shares must sum to exactly 10000 basis points.");
    const amount = ethers.parseUnits($("splitAmount").value || "0", 18);
    if (amount === 0n) throw new Error("Enter an amount greater than 0.");
    await txDone(c.splitPayment(addrs, shares, { value: amount }), "splitline", "Split payment sent");
  } catch (e) {
    setLine("splitline", "Failed: " + (e.reason || e.message), false);
  }
});

$("rundemo").addEventListener("click", () => {
  const steps = [["d1", "✓ Escrow 0 created — 0.27 USDC locked"], ["d2", "✓ Work hash committed on-chain"], ["d3", "✓ 0.27 USDC released to the agent"], ["d4", "✓ 0.10 USDC split 0.05 / 0.05"]];
  steps.forEach(([id, text], i) => {
    setTimeout(() => { $(id).textContent = text; }, 350 * (i + 1));
  });
});
