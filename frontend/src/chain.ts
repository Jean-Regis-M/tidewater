import { createPublicClient, defineChain, http, parseAbi } from 'viem'
import { baseSepolia } from 'viem/chains'
import deployments from './deployments.json'

export const lasna = defineChain({
  id: 5318007,
  name: 'Reactive Lasna',
  nativeCurrency: { name: 'lREACT', symbol: 'lREACT', decimals: 18 },
  rpcUrls: { default: { http: ['https://lasna-rpc.rnk.dev/'] } },
  blockExplorers: { default: { name: 'ReactScan', url: 'https://lasna.reactscan.net' } },
})

export { baseSepolia }

// Event reads use a node that allows wide eth_getLogs windows (sepolia.base.org caps at 200 blocks).
export const logClient = createPublicClient({ chain: baseSepolia, transport: http('https://base-sepolia-rpc.publicnode.com') })

export const baseClient =createPublicClient({ chain: baseSepolia, transport: http('https://sepolia.base.org') })
export const lasnaClient = createPublicClient({ chain: lasna, transport: http('https://lasna-rpc.rnk.dev/') })

export const addr = deployments as {
  token: `0x${string}` | ''
  vault: `0x${string}` | ''
  reactive: `0x${string}` | ''
  strategy: `0x${string}` | ''
  deployBlock: number
}
export const isDeployed = !!(addr.token && addr.vault && addr.reactive)

export const tokenAbi = parseAbi([
  'function faucet()',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function transfer(address,uint256) returns (bool)',
])

export const vaultAbi = parseAbi([
  'function liquidity() view returns (uint256)',
  'function pending() view returns (uint256)',
  'function queueLength() view returns (uint256)',
  'function minTicket() view returns (uint256)',
  'function ticketCount() view returns (uint256)',
  'function claims(address) view returns (uint256)',
  'function owner() view returns (address)',
  'function tickets(uint256) view returns (address owner, uint128 amount, uint128 filled, uint64 queuedAt, bool active, uint256 prev, uint256 next)',
  'function deposit(uint256)',
  'function requestWithdraw(uint256) returns (uint256)',
  'function cancelTicket(uint256)',
  'function lend(uint256)',
  'function repay(uint256)',
  'event WithdrawQueued(uint256 indexed id, address indexed user, uint256 amount, uint256 pendingAfter)',
  'event TicketCancelled(uint256 indexed id, address indexed user, uint256 remaining, uint256 pendingAfter)',
  'event TicketFilled(uint256 indexed id, address indexed user, uint256 paid, bool done)',
  'event LiquidityAdded(address indexed from, uint256 amount, uint256 liquidityAfter, uint256 pendingNow)',
  'event Settled(uint256 processed, uint256 paid, uint256 pendingAfter, uint256 liquidityAfter, uint256 timestamp)',
  'event Withdrawn(address indexed user, uint256 amount, uint256 liquidityAfter)',
])

export const reactiveAbi = parseAbi([
  'function pending() view returns (uint256)',
  'function liquidity() view returns (uint256)',
  'function callbacksRequested() view returns (uint256)',
  'function eventsIgnored() view returns (uint256)',
  'function minTrigger() view returns (uint256)',
  'function maxTickets() view returns (uint256)',
  'event TriggerDecision(bool fire, string reason, uint256 pending, uint256 liquidity)',
])

export const fmt = (v: bigint) => (Number(v) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 2 })
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`
