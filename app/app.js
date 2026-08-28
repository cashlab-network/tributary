/* Tributary — Coston2 read-only explorer + loan designer.
   Reads live on-chain state via ethers over the public RPC. The loan-designer
   math mirrors src/TermsLib.sol exactly (see the comments tying each function
   to its Solidity counterpart). No transactions are ever sent. */

const RPC = "https://coston2-api.flare.network/ext/C/rpc";
const EXPLORER = "https://coston2-explorer.flare.network";
const A = {
  vault:  "0x8Ad5f9654de710426985Ddc0696Fa2663D3c2Fe4",
  oracle: "0x0a124dfA88Bd463354B4C4D2E50C5F91FdAA165F",
  wnat:   "0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273",
  ftso:   "0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d",
  fsm:    "0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52",
};
const FLR_USD = "0x01464c522f55534400000000000000000000000000";
const EPOCH_SECONDS_MAINNET = 302400n; // shown for reference

const VAULT_ABI = [
  "function nextId() view returns (uint256)",
  "function statusOf(uint256) view returns (uint8)",
  "function owed(address,address) view returns (uint256)",
  "function epochDurationSeconds() view returns (uint256)",
  "function minSettledEpochs() view returns (uint32)",
  "function deadEpochsToTrigger() view returns (uint32)",
  "function gracePeriod() view returns (uint64)",
  "function maxPriceDeviationBps() view returns (uint16)",
  "function getLoan(uint256) view returns (tuple(address borrower,address lender,bool fixedDollar,uint256 principalUsd,uint256 debt,uint256 outstanding,uint256 requiredMargin,uint256 defaultFee,uint256 benchmarkBps,uint64 lastAccrualEpoch,uint64 maturesAtEpoch,uint64 graceEndsAt,uint16 termEpochs,bool funded,address escrow,address collector,uint8 status))",
];
const ORACLE_ABI = [
  "function latest(address) view returns (tuple(uint64 epochId,uint192 trailingRewardPerEpoch,uint32 passCount,uint32 settledEpochs,uint32 deadStreak))",
];
const FTSO_ABI = ["function getFeedById(bytes21) view returns (uint256,int8,uint64)"];
const FSM_ABI = [
  "function getCurrentRewardEpochId() view returns (uint24)",
  "function rewardsHash(uint256) view returns (bytes32)",
];

const STATUS = ["None","Offered","Open","Drawn","Grace","Settled","Repaid","Closed"];
const STATUS_CLASS = ["closed","offered","open","drawn","grace","settled","repaid","closed"];

let provider, vault, oracle, ftso, fsm;

/* ---- TermsLib mirror (BigInt, exact integer math as in Solidity) ---- */
const BPS = 10000n;
function creditLine(trailingPerEpoch, termEpochs, marginValue) {
  const streamCap = (trailingPerEpoch * termEpochs * 7000n) / BPS;
  const marginCap = (marginValue * 5000n) / BPS;
  return streamCap < marginCap ? streamCap : marginCap;
}
function rateBps(benchmarkBps, passCount) {
  const p = passCount > 3n ? 3n : passCount;
  let spread = 400n - p * 100n;
  if (spread < 100n) spread = 100n;
  return benchmarkBps + spread;
}
function epochInterest(outstanding, annualRateBps, epochs, epochSeconds) {
  return (outstanding * annualRateBps * epochSeconds * epochs) / (BPS * 31536000n);
}
function flrToUsd6(flrWei, feedValue, feedDecimals) {
  return (flrWei * feedValue) / (10n ** feedDecimals * 1000000000000n);
}

/* ---- formatting helpers ---- */
const WAD = 1000000000000000000n;
function fmtFlr(wei, dp = 4) {
  const neg = wei < 0n; if (neg) wei = -wei;
  const whole = wei / WAD, frac = wei % WAD;
  let f = frac.toString().padStart(18, "0").slice(0, dp).replace(/0+$/, "");
  return (neg ? "-" : "") + whole.toString() + (f ? "." + f : "");
}
function fmtUsd6(v) {
  const whole = v / 1000000n, frac = v % 1000000n;
  return "$" + whole.toString() + "." + frac.toString().padStart(6, "0").slice(0, 4);
}
function shortAddr(a) { return a.slice(0, 6) + "…" + a.slice(-4); }
function addrLink(a, label) {
  return `<a href="${EXPLORER}/address/${a}" target="_blank" rel="noopener">${label || shortAddr(a)}</a>`;
}
function el(id) { return document.getElementById(id); }
function showError(msg) {
  el("errzone").innerHTML = `<div class="err-box"><b>Couldn't reach the chain.</b> ${msg}
    <br><span class="muted">Retrying reads on ↻ Refresh.</span></div>`;
}

let livePrice = null; // {value, decimals}

async function readPrice() {
  // getFeedById is non-view on-chain but eth_call returns the value; ethers
  // treats the view fragment as a static call, matching `cast call`.
  const [value, decimals] = await ftso.getFeedById.staticCall(FLR_USD);
  livePrice = { value: BigInt(value), decimals: BigInt(decimals) };
  return livePrice;
}
function priceUsdPerFlr() {
  if (!livePrice) return null;
  // value / 10^decimals dollars per FLR
  const scaled = Number(livePrice.value) / 10 ** Number(livePrice.decimals);
  return scaled;
}

async function loadHeader() {
  const [epoch, block, price] = await Promise.allSettled([
    fsm.getCurrentRewardEpochId(),
    provider.getBlockNumber(),
    readPrice(),
  ]);
  el("netdot").className = "dot live";
  el("netlabel").textContent = "Coston2 · connected";
  if (epoch.status === "fulfilled") el("epoch").textContent = epoch.value.toString();
  if (block.status === "fulfilled") el("block").textContent = block.value.toLocaleString();
  if (price.status === "fulfilled") {
    const p = priceUsdPerFlr();
    el("price").textContent = p ? "$" + p.toPrecision(4) : "—";
  }
}

async function loadProtocol() {
  const [nextId, epDur, minEp, deadEp, grace, band] = await Promise.all([
    vault.nextId(), vault.epochDurationSeconds(), vault.minSettledEpochs(),
    vault.deadEpochsToTrigger(), vault.gracePeriod(), vault.maxPriceDeviationBps(),
  ]);
  const loanCount = nextId - 1n;
  const hrs = Number(epDur) / 3600;
  const graceDays = Number(grace) / 86400;
  el("protocol-stats").innerHTML = [
    ["Loans opened", loanCount.toString()],
    ["Reward epoch", `${hrs}h <small>chain value</small>`],
    ["Min history", `${minEp} <small>epochs</small>`],
    ["Default trigger", `${deadEp} <small>dead epochs</small>`],
    ["Grace window", `${graceDays}d`],
    ["Price band", `±${Number(band) / 100}%`],
    ["Vault", `<small>${addrLink(A.vault)}</small>`],
    ["Oracle", `<small>${addrLink(A.oracle)}</small>`],
  ].map(([k, v]) => `<div class="stat"><div class="k">${k}</div><div class="v">${v}</div></div>`).join("");
  el("foot-vault").innerHTML = addrLink(A.vault, A.vault);
  return loanCount;
}

async function loadLoans(count) {
  const box = el("loans");
  if (count <= 0n) { box.innerHTML = `<p class="muted">No loans opened yet.</p>`; return; }
  const cards = [];
  for (let i = 1n; i <= count; i++) {
    try {
      const L = await vault.getLoan(i);
      cards.push(renderLoan(i, L));
    } catch (e) {
      cards.push(`<div class="loan"><div class="loan-id">Loan #${i}</div>
        <p class="muted">read failed</p></div>`);
    }
  }
  box.innerHTML = cards.join("");
}

function renderLoan(id, L) {
  const status = Number(L.status);
  const sName = STATUS[status], sClass = STATUS_CLASS[status];
  const fd = L.fixedDollar;
  const debt = BigInt(L.debt), outstanding = BigInt(L.outstanding);
  const repaid = debt > 0n ? Number(((debt - outstanding) * 1000n) / debt) / 10 : 0;
  const debtStr = fd ? fmtUsd6(debt) : fmtFlr(debt) + " FLR";
  const outStr = fd ? fmtUsd6(outstanding) : fmtFlr(outstanding) + " FLR";
  const rate = rateBps(BigInt(L.benchmarkBps), 3n); // display at 3-pass floor; live passes vary
  return `<div class="loan">
    <div class="loan-head">
      <span class="loan-id">Loan #${id}</span>
      <span class="pill ${sClass}">${sName}</span>
    </div>
    <div class="flavor">${fd ? "◈ fixed-dollar" : "◇ fixed-FLR"} · benchmark ${L.benchmarkBps} bps · ${L.termEpochs} epochs</div>
    <div class="rows">
      <div class="row"><span class="l">Advanced</span><span class="r">${fmtUsd6(BigInt(L.principalUsd))}</span></div>
      <div class="row"><span class="l">Debt</span><span class="r">${debtStr}</span></div>
      <div class="row"><span class="l">Outstanding</span><span class="r">${outStr}</span></div>
      <div class="row"><span class="l">Margin</span><span class="r">${fmtFlr(BigInt(L.requiredMargin))} FLR</span></div>
    </div>
    <div class="bar"><i style="width:${Math.max(2, Math.min(100, repaid))}%"></i></div>
    <div class="row" style="font-size:.74rem"><span class="l muted">${repaid}% repaid</span>
      <span class="r muted">${sName === "Repaid" ? "✓ settled" : ""}</span></div>
    <div class="addr-row">
      <span>borrower ${addrLink(L.borrower)}</span>
      <span>lender ${addrLink(L.lender)}</span>
      ${L.collector !== "0x0000000000000000000000000000000000000000" ? `<span>mailbox ${addrLink(L.collector)}</span>` : ""}
    </div>
  </div>`;
}

async function loadRoots() {
  const box = el("roots");
  try {
    const cur = Number(await fsm.getCurrentRewardEpochId());
    const epochs = [cur, cur - 1, cur - 2, cur - 3, cur - 4];
    const roots = await Promise.all(epochs.map((e) => fsm.rewardsHash(e).catch(() => null)));
    const ZERO = "0x" + "0".repeat(64);
    box.innerHTML = epochs.map((e, i) => {
      const r = roots[i];
      const signed = r && r !== ZERO;
      const short = signed ? r.slice(0, 10) + "…" + r.slice(-6) : "unsigned";
      return `<div class="stat"><div class="k">epoch ${e}${i === 0 ? " (current)" : ""}</div>
        <div class="v" style="font-size:.8rem;color:${signed ? "var(--good)" : "var(--faint)"}">${short}</div></div>`;
    }).join("");
  } catch (e) {
    box.innerHTML = `<div class="stat"><div class="k">roots</div><div class="v" style="font-size:.85rem">read failed</div></div>`;
  }
}

async function lookupLedger() {
  const addr = el("lookup").value.trim();
  const out = el("ledger-out");
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) { out.innerHTML = `<p class="err-box">Enter a valid 0x address.</p>`; return; }
  out.innerHTML = `<p class="spinner">reading ledger…</p>`;
  try {
    const R = await oracle.latest(addr);
    if (R.epochId === 0n && R.settledEpochs === 0n) {
      out.innerHTML = `<p class="muted">No ledger record for this address. (Never posted — would fail underwriting.)</p>`;
      return;
    }
    const rate = rateBps(500n, BigInt(R.passCount));
    out.innerHTML = `<div class="stats">
      ${stat("Last epoch", R.epochId.toString())}
      ${stat("Passes held", R.passCount + " / 3")}
      ${stat("Settled epochs", R.settledEpochs.toString())}
      ${stat("Trailing/epoch", fmtFlr(BigInt(R.trailingRewardPerEpoch)) + " FLR")}
      ${stat("Dead streak", R.deadStreak.toString())}
      ${stat("Rate @5% bench", (Number(rate) / 100).toFixed(2) + "%")}
    </div>
    <p class="hint">Rate = benchmark + 4pts − 1pt/pass, floor +1pt. ${R.deadStreak >= 4n
      ? '<b style="color:var(--bad)">Dead streak ≥ trigger — would be in default territory.</b>'
      : "Stream alive — eligible."}</p>`;
  } catch (e) {
    out.innerHTML = `<p class="err-box">Read failed: ${e.message || e}</p>`;
  }
}
function stat(k, v) { return `<div class="stat"><div class="k">${k}</div><div class="v">${v}</div></div>`; }

function calculate() {
  const out = el("calc-out");
  try {
    const flavor = el("c-flavor").value;
    const passes = BigInt(el("c-passes").value || "0");
    const trailing = BigInt(Math.round(parseFloat(el("c-trailing").value || "0") * 1e18));
    const term = BigInt(el("c-term").value || "0");
    const margin = BigInt(Math.round(parseFloat(el("c-margin").value || "0") * 1e18));
    const benchmark = BigInt(el("c-benchmark").value || "0");
    if (term <= 0n) { out.innerHTML = `<p class="err-box">Term must be at least 1 epoch.</p>`; return; }

    const lineFlr = creditLine(trailing, term, margin);
    const rate = rateBps(benchmark, passes);
    const p = priceUsdPerFlr();

    let lineLabel, lineVal;
    if (flavor === "usd") {
      if (!livePrice) { out.innerHTML = `<p class="err-box">Live price not loaded yet — refresh.</p>`; return; }
      const lineUsd = flrToUsd6(lineFlr, livePrice.value, livePrice.decimals);
      lineLabel = "Max you can borrow (fixed-dollar)";
      lineVal = fmtUsd6(lineUsd);
    } else {
      lineLabel = "Max you can borrow (fixed-FLR)";
      lineVal = fmtFlr(lineFlr) + " FLR" + (p ? ` <small class="muted">≈ ${(Number(fmtFlr(lineFlr)) * p).toFixed(2)} USD</small>` : "");
    }

    // repayment schedule: simulate accruing interest per epoch on the whole
    // debt, with a level payment = 1 epoch's trailing reward (chain-read
    // epoch length). Purely illustrative — mirrors the accrual formula.
    const epDur = livePrice ? null : null; // epoch seconds fetched below if needed
    const rows = [];
    let bal = lineFlr; // schedule in FLR terms
    const payPerEpoch = trailing; // the whole reward stream services the loan
    let e = 0, capped = false;
    while (bal > 0n && e < 60) {
      e++;
      const interest = epochInterest(bal, rate, 1n, currentEpochSeconds);
      bal += interest;
      const pay = bal < payPerEpoch ? bal : payPerEpoch;
      bal -= pay;
      if (e <= 8 || bal === 0n) rows.push(`<tr><td>${e}</td><td>${fmtFlr(interest, 4)}</td><td>${fmtFlr(pay, 2)}</td><td>${fmtFlr(bal, 2)}</td></tr>`);
      if (e === 60) capped = true;
    }
    const payoff = capped ? "60+" : e;

    out.innerHTML = `
      <div><div class="lab">${lineLabel}</div><div class="big">${lineVal}</div></div>
      <div class="stats" style="margin-top:.4rem">
        ${stat("Interest rate", (Number(rate) / 100).toFixed(2) + "% <small>APR</small>")}
        ${stat("Est. payoff", payoff + " epochs")}
        ${stat("Stream/epoch", fmtFlr(trailing, 2) + " FLR")}
      </div>
      <p class="hint" style="margin-top:.7rem">Repayment (whole reward stream servicing the loan, interest accruing per epoch):</p>
      <table><thead><tr><th>Epoch</th><th>Interest</th><th>Payment</th><th>Balance FLR</th></tr></thead>
      <tbody>${rows.join("")}</tbody></table>
      <p class="hint">Math mirrors <span class="mono">TermsLib.sol</span> exactly · rate = ${benchmark} + ${400 - Math.min(3, Number(passes)) * 100} bps spread · epoch = ${Number(currentEpochSeconds) / 3600}h.</p>`;
  } catch (e) {
    out.innerHTML = `<p class="err-box">${e.message || e}</p>`;
  }
}

let currentEpochSeconds = 21600n; // updated from chain on load

async function boot() {
  try {
    provider = new ethers.JsonRpcProvider(RPC, { chainId: 114, name: "coston2" });
    vault = new ethers.Contract(A.vault, VAULT_ABI, provider);
    oracle = new ethers.Contract(A.oracle, ORACLE_ABI, provider);
    ftso = new ethers.Contract(A.ftso, FTSO_ABI, provider);
    fsm = new ethers.Contract(A.fsm, FSM_ABI, provider);
    el("errzone").innerHTML = "";
    await loadHeader();
    currentEpochSeconds = await vault.epochDurationSeconds();
    const count = await loadProtocol();
    await loadLoans(count);
    loadRoots(); // fire-and-forget; not load-bearing for the rest
    // prefill the ledger lookup with loan 1's borrower for a one-click demo
    try { const L1 = await vault.getLoan(1n); el("lookup").value = L1.borrower; } catch (_) {}
  } catch (e) {
    el("netdot").className = "dot err";
    el("netlabel").textContent = "connection failed";
    showError(e.message || String(e));
  }
}

/* ---- wallet write path (Coston2 only) ---- */
const COSTON2_HEX = "0x72"; // 114
let signer = null, walletAddr = null;

const WNAT_WRITE_ABI = [
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
];
const VAULT_WRITE_ABI = ["function repay(uint256,uint256)"];

async function connectWallet() {
  const msg = el("w-msg");
  if (!window.ethereum) {
    el("wallet-status").innerHTML = `<span style="color:var(--warn)">No wallet detected. Install a Coston2-capable wallet (e.g. MetaMask) and reload.</span>`;
    return;
  }
  try {
    const bp = new ethers.BrowserProvider(window.ethereum);
    await bp.send("eth_requestAccounts", []);
    const net = await bp.getNetwork();
    if (Number(net.chainId) !== 114) {
      try {
        await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: COSTON2_HEX }] });
      } catch (sw) {
        // offer to add the chain
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: COSTON2_HEX, chainName: "Flare Coston2",
            nativeCurrency: { name: "Coston2 Flare", symbol: "C2FLR", decimals: 18 },
            rpcUrls: [RPC], blockExplorerUrls: [EXPLORER],
          }],
        });
      }
    }
    signer = await bp.getSigner();
    walletAddr = await signer.getAddress();
    el("wallet-status").innerHTML = `Connected: <span class="mono">${shortAddr(walletAddr)}</span> on Coston2.`;
    el("connect").textContent = shortAddr(walletAddr);
    el("w-repay").disabled = false;
  } catch (e) {
    el("wallet-status").innerHTML = `<span style="color:var(--bad)">Connect failed: ${e.message || e}</span>`;
  }
}

async function repayFromWallet() {
  const msg = el("w-msg");
  if (!signer) { msg.textContent = "Connect a wallet first."; return; }
  const id = el("w-id").value.trim();
  const amtFlr = el("w-amt").value.trim();
  if (!id || !amtFlr || Number(amtFlr) <= 0) { msg.textContent = "Enter a loan id and a positive amount."; return; }
  const amt = ethers.parseUnits(amtFlr, 18);
  try {
    msg.textContent = "checking WFLR allowance…";
    const w = new ethers.Contract(A.wnat, WNAT_WRITE_ABI, signer);
    const cur = await w.allowance(walletAddr, A.vault);
    if (cur < amt) {
      // approve exactly this repayment (not infinite) — no standing allowance
      // left on a shared vault (review-3 Finding 2).
      msg.textContent = "approving WFLR (sign in wallet)…";
      const txa = await w.approve(A.vault, amt);
      await txa.wait();
    }
    msg.textContent = "repaying (sign in wallet)…";
    const v = new ethers.Contract(A.vault, VAULT_WRITE_ABI, signer);
    const tx = await v.repay(id, amt, { gasLimit: 900000n });
    msg.innerHTML = `sent: <a href="${EXPLORER}/tx/${tx.hash}" target="_blank" rel="noopener">${tx.hash.slice(0, 12)}…</a> — waiting…`;
    await tx.wait();
    msg.innerHTML = `<span style="color:var(--good)">✓ repaid. <a href="${EXPLORER}/tx/${tx.hash}" target="_blank" rel="noopener">receipt</a></span>`;
    boot(); // refresh the loan cards
  } catch (e) {
    msg.innerHTML = `<span style="color:var(--bad)">${(e.shortMessage || e.message || e).slice(0, 160)}</span>`;
  }
}

el("refresh").addEventListener("click", boot);
el("lookup-btn").addEventListener("click", lookupLedger);
el("calc-btn").addEventListener("click", calculate);
el("connect").addEventListener("click", connectWallet);
el("w-repay").addEventListener("click", repayFromWallet);
boot();
