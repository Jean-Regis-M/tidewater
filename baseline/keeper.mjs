// Polling keeper baseline for Tidewater.
//
// This is what you would run INSTEAD of the Reactive contract: an off-chain bot that polls the vault
// and sends settle() when there is a queue and liquidity. It targets the baseline vault (same
// TidewaterVault code, but the keeper address is the authorised caller).
//
// Usage: KEEPER_PRIVATE_KEY=0x... node keeper.mjs <vault> <pollMs> [rpcUrl]
// It is a reasonably tuned keeper (fixed gas limit, 100 ms receipt polling), not an adversarially fast one.
import { createPublicClient, createWalletClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { baseSepolia } from 'viem/chains';

const [vault, pollArg, rpcArg] = process.argv.slice(2);
if (!vault || !pollArg || !process.env.KEEPER_PRIVATE_KEY) {
  console.error('usage: KEEPER_PRIVATE_KEY=0x.. node keeper.mjs <vault> <pollMs> [rpcUrl]');
  process.exit(1);
}
const pollMs = Number(pollArg);
const rpc = rpcArg ?? 'https://sepolia.base.org';
const account = privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY);
const pub = createPublicClient({ chain: baseSepolia, transport: http(rpc) });
const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(rpc) });
const abi = parseAbi([
  'function pending() view returns (uint256)',
  'function liquidity() view returns (uint256)',
  'function settle(address reactive_, uint256 maxTickets)',
]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(new Date().toISOString(), ...a);

log(`keeper ${account.address} polling ${vault} every ${pollMs} ms via ${rpc}`);
let busy = false;
let polls = 0;
for (;;) {
  const t0 = Date.now();
  try {
    polls++;
    const [pending, liquidity] = await Promise.all([
      pub.readContract({ address: vault, abi, functionName: 'pending' }),
      pub.readContract({ address: vault, abi, functionName: 'liquidity' }),
    ]);
    if (pending > 0n && liquidity > 0n && !busy) {
      busy = true;
      const hash = await wallet.writeContract({
        address: vault, abi, functionName: 'settle', args: [account.address, 10n], gas: 600000n,
      });
      log(`detected pending=${pending} liquidity=${liquidity}; settle sent ${hash} (poll #${polls})`);
      const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 100 });
      log(`settle mined in block ${r.blockNumber} status=${r.status}`);
      busy = false;
    }
  } catch (e) {
    busy = false;
    log('error:', String(e.shortMessage ?? e.message).slice(0, 140));
  }
  await sleep(Math.max(0, pollMs - (Date.now() - t0)));
}
