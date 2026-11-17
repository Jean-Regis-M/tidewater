import { useCallback, useEffect, useState } from 'react'
import { createWalletClient, custom, parseUnits, type Hash } from 'viem'
import {
  addr, baseClient, baseSepolia, fmt, isDeployed, lasnaClient, logClient, reactiveAbi, short, tokenAbi, vaultAbi,
} from './chain'
import './App.css'

type Ticket = { id: number; owner: `0x${string}`; amount: bigint; filled: bigint; queuedAt: number; cancelled: boolean }
type Loop = { liquidityTx: Hash; settledTx: Hash; seconds: number; paid: bigint; tickets: number }
type Snap = {
  liquidity: bigint; pending: bigint; head: bigint; count: bigint
  claims: bigint; balance: bigint; allowance: bigint; isOwner: boolean
  rx: { pending: bigint; liquidity: bigint; callbacks: bigint; ignored: bigint } | null
  tickets: Ticket[]; loops: Loop[]
}

const eth = () => (window as unknown as { ethereum?: any }).ethereum

export default function App() {
  const [account, setAccount] = useState<`0x${string}` | null>(null)
  const [snap, setSnap] = useState<Snap | null>(null)
  const [amount, setAmount] = useState('100')
  const [busy, setBusy] = useState<string | null>(null)
  const [log, setLog] = useState<{ ok: boolean; text: string; hash?: Hash }[]>([])

  const note = (ok: boolean, text: string, hash?: Hash) => setLog((l) => [{ ok, text, hash }, ...l].slice(0, 6))

  const refresh = useCallback(async () => {
    if (!isDeployed) return
    const v = addr.vault as `0x${string}`
    const who = account ?? '0x0000000000000000000000000000000000000000'
    try {
      const [liquidity, pending, head, count, claims, balance, allowance, owner] = await Promise.all([
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'liquidity' }),
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'pending' }),
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'queueLength' }),
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'ticketCount' }),
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'claims', args: [who] }),
        baseClient.readContract({ address: addr.token as `0x${string}`, abi: tokenAbi, functionName: 'balanceOf', args: [who] }),
        baseClient.readContract({ address: addr.token as `0x${string}`, abi: tokenAbi, functionName: 'allowance', args: [who, v] }),
        baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'owner' }),
      ])
      const start = Number(count) > 40 ? Number(count) - 40 : 0
      const tickets: Ticket[] = []
      for (let i = Number(count) - 1; i >= start; i--) {
        const t = await baseClient.readContract({ address: v, abi: vaultAbi, functionName: 'tickets', args: [BigInt(i)] })
        tickets.push({ id: i, owner: t[0], amount: t[1], filled: t[2], queuedAt: Number(t[3]), cancelled: !t[4] && t[2] < t[1] })
      }
      let rx: Snap['rx'] = null
      try {
        const r = addr.reactive as `0x${string}`
        const [p, l, c, ig] = await Promise.all([
          lasnaClient.readContract({ address: r, abi: reactiveAbi, functionName: 'pending' }),
          lasnaClient.readContract({ address: r, abi: reactiveAbi, functionName: 'liquidity' }),
          lasnaClient.readContract({ address: r, abi: reactiveAbi, functionName: 'callbacksRequested' }),
          lasnaClient.readContract({ address: r, abi: reactiveAbi, functionName: 'eventsIgnored' }),
        ])
        rx = { pending: p, liquidity: l, callbacks: c, ignored: ig }
      } catch { /* Lasna RPC hiccup: leave null */ }

      // latency: pair each Settled with the latest preceding LiquidityAdded that had a queue
      // scan back from head in 5,000-block windows (≈17 min each), newest first, until we have enough loops
      let loops: Loop[] | null = null
      try {
      const headBlock = await logClient.getBlockNumber()
      let adds: Awaited<ReturnType<typeof logClient.getContractEvents<typeof vaultAbi, 'LiquidityAdded'>>> = []
      let settles: Awaited<ReturnType<typeof logClient.getContractEvents<typeof vaultAbi, 'Settled'>>> = []
      for (let w = 0; w < 6 && settles.length < 6; w++) {
        const to = headBlock - BigInt(w * 5000)
        const from = to - 4999n > BigInt(addr.deployBlock) ? to - 4999n : BigInt(addr.deployBlock)
        const [a, s] = await Promise.all([
          logClient.getContractEvents({ address: v, abi: vaultAbi, eventName: 'LiquidityAdded', fromBlock: from, toBlock: to }),
          logClient.getContractEvents({ address: v, abi: vaultAbi, eventName: 'Settled', fromBlock: from, toBlock: to }),
        ])
        adds = [...a, ...adds]; settles = [...s, ...settles]
        if (from <= BigInt(addr.deployBlock)) break
      }
      const found: Loop[] = []
      for (const s of settles.slice(-6)) {
        if (!s.args.processed) continue
        const trig = [...adds].reverse().find((a) => a.blockNumber! <= s.blockNumber! && (a.args.pendingNow ?? 0n) > 0n)
        if (!trig) continue
        const [b1, b2] = await Promise.all([
          logClient.getBlock({ blockNumber: trig.blockNumber! }),
          logClient.getBlock({ blockNumber: s.blockNumber! }),
        ])
        found.push({
          liquidityTx: trig.transactionHash!, settledTx: s.transactionHash!,
          seconds: Number(b2.timestamp - b1.timestamp), paid: s.args.paid ?? 0n, tickets: Number(s.args.processed),
        })
      }
      loops = found.reverse()
      } catch { /* log node hiccup: keep the previous loops table */ }
      setSnap((prev) => ({ liquidity, pending, head, count, claims, balance, allowance, isOwner: !!account && owner.toLowerCase() === account.toLowerCase(), rx, tickets, loops: loops ?? prev?.loops ?? [] }))
    } catch (e) { note(false, `Read failed: ${(e as Error).message.slice(0, 120)}`) }
  }, [account])

  useEffect(() => { refresh(); const t = setInterval(refresh, 2500); return () => clearInterval(t) }, [refresh])

  async function connect() {
    if (!eth()) return note(false, 'No wallet found. Install MetaMask or Coinbase Wallet.')
    const [a] = await eth().request({ method: 'eth_requestAccounts' })
    try { await eth().request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x14a34' }] }) }
    catch { await eth().request({ method: 'wallet_addEthereumChain', params: [{ chainId: '0x14a34', chainName: 'Base Sepolia', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: ['https://sepolia.base.org'], blockExplorerUrls: ['https://sepolia.basescan.org'] }] }) }
    setAccount(a)
  }

  async function send(label: string, address: `0x${string}`, abi: any, fn: string, args: unknown[] = []) {
    if (!account) return note(false, 'Connect a wallet first.')
    setBusy(label)
    try {
      const wc = createWalletClient({ account, chain: baseSepolia, transport: custom(eth()) })
      const hash = await wc.writeContract({ address, abi, functionName: fn, args } as any)
      await baseClient.waitForTransactionReceipt({ hash })
      note(true, label, hash)
    } catch (e) { note(false, `${label} failed: ${(e as Error).message.split('\n')[0].slice(0, 110)}`) }
    setBusy(null); refresh()
  }

  const amt = (() => { try { return parseUnits(amount || '0', 6) } catch { return 0n } })()
  const V = addr.vault as `0x${string}`, T = addr.token as `0x${string}`
  const needsApproval = snap ? snap.allowance < amt : false

  return (
    <div className="app">
      <header>
        <div className="brand"><span className="mark" />Tidewater<small>withdrawal queue · Reactive Omni</small></div>
        <button className="btn primary" onClick={connect}>{account ? short(account) : 'Connect wallet'}</button>
      </header>

      <section className="hero">
        <h1>Queue once. Paid the moment liquidity returns.</h1>
        <p>When the vault is illiquid, withdrawals wait in a first-in-first-out queue. A reactive contract watches the vault, and the second funds come back it triggers settlement on Base Sepolia. No keeper, no server.</p>
      </section>

      {!isDeployed && (
        <div className="banner">Contracts are not deployed yet. Addresses will appear in <code>src/deployments.json</code> after deployment, and this page goes live automatically.</div>
      )}

      <section className="grid stats">
        <Stat label="Vault liquidity" value={snap ? fmt(snap.liquidity) : '–'} unit="tUSD" tone={snap && snap.liquidity === 0n ? 'warn' : 'ok'} />
        <Stat label="Queued withdrawals" value={snap ? fmt(snap.pending) : '–'} unit="tUSD" tone={snap && snap.pending > 0n ? 'warn' : 'ok'} />
        <Stat label="Tickets waiting" value={snap ? String(Number(snap.head)) : '–'} unit="" />
        <Stat label="Reactive callbacks" value={snap?.rx ? String(snap.rx.callbacks) : '–'} unit="requested" />
      </section>

      <section className="grid two">
        <div className="card">
          <h2>Your position</h2>
          <div className="kv"><span>Wallet tUSD</span><b>{snap ? fmt(snap.balance) : '–'}</b></div>
          <div className="kv"><span>Vault claim</span><b>{snap ? fmt(snap.claims) : '–'}</b></div>
          <label>Amount (tUSD)</label>
          <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
          <div className="row">
            <button className="btn" disabled={!!busy || !isDeployed} onClick={() => send('Claim test tUSD', T, tokenAbi, 'faucet')}>Get test tUSD</button>
            {needsApproval
              ? <button className="btn" disabled={!!busy || !isDeployed} onClick={() => send('Approve tUSD', T, tokenAbi, 'approve', [V, 2n ** 256n - 1n])}>Approve</button>
              : <button className="btn" disabled={!!busy || !isDeployed || amt === 0n} onClick={() => send('Deposit', V, vaultAbi, 'deposit', [amt])}>Deposit</button>}
            <button className="btn primary" disabled={!!busy || !isDeployed || amt === 0n} onClick={() => send('Request withdrawal', V, vaultAbi, 'requestWithdraw', [amt])}>Withdraw</button>
          </div>
          <p className="hint">Withdraw pays instantly if the vault is liquid and nobody is ahead of you. Otherwise you get a queue ticket.</p>
        </div>

        <div className="card">
          <h2>Strategy desk <span className="tag">demo controls</span></h2>
          <p className="hint">The vault lends idle funds to a strategy. These controls simulate that, so you can create a queue and then watch Reactive clear it.</p>
          <div className="row">
            <button className="btn" disabled={!!busy || !isDeployed || !snap?.isOwner || amt === 0n} onClick={() => send('Lend to strategy', V, vaultAbi, 'lend', [amt])}>Lend out (owner)</button>
            <button className="btn primary" disabled={!!busy || !isDeployed || amt === 0n} onClick={() => send('Return liquidity', V, vaultAbi, 'repay', [amt])}>Return liquidity</button>
          </div>
          <p className="hint">Returning liquidity needs tUSD approved to the vault. Everything on this page reads live contract state.</p>
          {busy && <div className="pulse">Confirming: {busy}…</div>}
          <ul className="log">{log.map((l, i) => (
            <li key={i} className={l.ok ? 'ok' : 'bad'}>{l.text}{l.hash && <> · <a href={`https://sepolia.basescan.org/tx/${l.hash}`} target="_blank" rel="noreferrer">{short(l.hash)}</a></>}</li>
          ))}</ul>
        </div>
      </section>

      <section className="card">
        <h2>Withdrawal queue</h2>
        {!snap || snap.tickets.length === 0 ? <p className="empty">No tickets yet. Lend out the vault's funds, then request a withdrawal.</p> : (
          <table><thead><tr><th>#</th><th>Owner</th><th>Amount</th><th>Filled</th><th>Status</th></tr></thead><tbody>
            {snap.tickets.map((t) => {
              const done = t.filled === t.amount
              return <tr key={t.id}><td>{t.id}</td><td>{short(t.owner)}</td><td>{fmt(t.amount)}</td><td>{fmt(t.filled)}</td>
                <td><span className={`pill ${t.cancelled ? 'grey' : done ? 'green' : 'amber'}`}>{t.cancelled ? 'cancelled' : done ? 'settled' : t.filled > 0n ? 'partial' : 'waiting'}</span>
                  {!done && !t.cancelled && account?.toLowerCase() === t.owner.toLowerCase() && <button className="link" onClick={() => send('Cancel ticket', V, vaultAbi, 'cancelTicket', [BigInt(t.id)])}>cancel</button>}</td></tr>
            })}
          </tbody></table>)}
      </section>

      <section className="grid two">
        <div className="card">
          <h2>Reactive contract (Lasna)</h2>
          <div className="kv"><span>Mirrored pending</span><b>{snap?.rx ? fmt(snap.rx.pending) : '–'}</b></div>
          <div className="kv"><span>Mirrored liquidity</span><b>{snap?.rx ? fmt(snap.rx.liquidity) : '–'}</b></div>
          <div className="kv"><span>Callbacks requested</span><b>{snap?.rx ? String(snap.rx.callbacks) : '–'}</b></div>
          <div className="kv"><span>Events ignored (duplicate/stale)</span><b>{snap?.rx ? String(snap.rx.ignored) : '–'}</b></div>
          {isDeployed && <p className="hint">Contract <a href={`https://lasna.reactscan.net/address/${addr.reactive}`} target="_blank" rel="noreferrer">{short(addr.reactive)}</a> · Vault <a href={`https://sepolia.basescan.org/address/${addr.vault}`} target="_blank" rel="noreferrer">{short(addr.vault)}</a></p>}
        </div>
        <div className="card">
          <h2>Measured settlement loops</h2>
          {!snap || snap.loops.length === 0 ? <p className="empty">No completed loops yet.</p> : (
            <table><thead><tr><th>Origin tx</th><th>Settle tx</th><th>Paid</th><th>Seconds</th></tr></thead><tbody>
              {snap.loops.map((l) => <tr key={l.settledTx}>
                <td><a href={`https://sepolia.basescan.org/tx/${l.liquidityTx}`} target="_blank" rel="noreferrer">{short(l.liquidityTx)}</a></td>
                <td><a href={`https://sepolia.basescan.org/tx/${l.settledTx}`} target="_blank" rel="noreferrer">{short(l.settledTx)}</a></td>
                <td>{fmt(l.paid)}</td><td>{l.seconds}s</td></tr>)}
            </tbody></table>)}
          <p className="hint">Block timestamps on Base are whole seconds, so these are coarse. Precise sub-second timings are in the repository's measurement report.</p>
        </div>
      </section>

      <footer>Test tokens only · Base Sepolia + Reactive Lasna · Built for the Reactive Omni Buildathon 2026</footer>
    </div>
  )
}

function Stat({ label, value, unit, tone }: { label: string; value: string; unit: string; tone?: 'ok' | 'warn' }) {
  return <div className={`card stat ${tone ?? ''}`}><span>{label}</span><b>{value}</b><em>{unit}</em></div>
}
