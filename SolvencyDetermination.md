# SolvencyDetermination — PhlimboV3

How to determine, on-chain, that `PhlimboV3` can honour every claim against it. V3
carries **three reward streams** plus staked principal; each has its own solvency
argument and tooling. All views referenced here are on `PhlimboV3` /
`IPhlimboV3`.

## Token flows at a glance

| Asset | Enters via | Leaves via | Backing |
|---|---|---|---|
| phUSD principal | `stake` | `withdraw`, `pauseWithdraw`, `emergencyTransfer` | held 1:1 in the contract |
| phUSD rewards | minted at claim time | `claim`/`stake`/`withdraw` settlement | phUSD mint privilege (not pre-funded) |
| stable `rewardToken` | `collectReward` | reward settlement, `emergencyTransfer` | pre-funded, capped linear depletion |
| `promoToken` | `startPromotion`, `topUpPromotion` | reward settlement, `batchClaim`, `finalizePromotion` sweep, `emergencyTransfer`, `claimUnclaimablePromo` | pre-funded, capped linear depletion |

## 1. Staked principal (phUSD)

Invariant:

```
phUSD.balanceOf(phlimbo) >= totalStaked
```

Principal only enters via `stake` (exact `safeTransferFrom`) and only leaves via
`withdraw`/`pauseWithdraw`, both of which decrement `totalStaked` by the amount
transferred out. phUSD is never used to pay any reward stream (phUSD rewards are
freshly minted, see §2), so the staked balance is never encumbered.
`emergencyTransfer` is the owner-gated exception that deliberately breaks this
invariant (it drains and pauses the contract; recovery is out-of-band).

## 2. phUSD reward stream (APY-driven mint)

Pending phUSD (`pendingPhUSD(user)`) is **minted on demand** at settlement —
there is no pre-funded pool and therefore no balance-style insolvency. Solvency
condition:

- the contract must hold an active mint privilege on the phUSD token
  (`phUSD.authorizedMinters(phlimbo)` with a current `mintVersion`).

If the mint privilege is revoked, phUSD settlement reverts (stable and promo
streams are unaffected until a claim path touches the mint). Emission is
`totalStaked * desiredAPYBps / 10000 / SECONDS_PER_YEAR`, recomputed on every
stake/withdraw; it cannot exceed what the APY implies.

## 3. Stable reward stream (`rewardToken`, capped linear depletion)

Accounting: `collectReward(amount)` pulls `amount` in and adds it to
`rewardBalance`; `_updatePool` moves value out of `rewardBalance` into
`accStablePerShare` at `rewardPerSecond`, **capped by `rewardBalance`** — the
accumulator can never promise more than was funded. Tokens physically leave only
at settlement, paying `amount * accStablePerShare / PRECISION − stableDebt`.

Invariant:

```
rewardToken.balanceOf(phlimbo) >= rewardBalance + Σ_user pendingStable(user)
```

- `rewardBalance` = not-yet-accrued funding.
- `Σ pendingStable` = accrued but unclaimed. Enumerable exactly in V3:
  `for i in [0, stakerCount()): pendingStable(stakerAt(i))` — only set members can
  have non-zero stake, and pending is a pure function of stake.
- Floor division in accrual and settlement means dust remains in the contract:
  the inequality is `>=`, with the surplus favouring the protocol.
- `pauseWithdraw` realigns debts to the reduced amount, forfeiting the user's
  accrued-unclaimed rewards; forfeits stay in the contract and only grow the
  surplus.

## 4. Promotional stream (`promoToken`, single slot, own window)

Same capped-linear-depletion model as §3 on independent variables
(`promoRewardBalance`, `promoRewardPerSecond`, `accPromoPerShare`,
`promoDepletionDuration`), skipped entirely when `promoToken == address(0)`.

Invariant while a promotion exists (phase Active or Flushing):

```
promoToken.balanceOf(phlimbo) >= promoRewardBalance
                                + Σ_user pendingPromo(user)
                                + totalUnclaimableOf[promoToken]
```

A separate invariant holds for every token `t` ever used as a promo token,
including retired ones (`promoToken == address(0)` or rotated to another token):

```
t.balanceOf(phlimbo) >= totalUnclaimableOf[t]
```

because `finalizePromotion` reserves the bank from its sweep and the only exit
for a banked amount is the user's own `claimUnclaimablePromo` pull, which
decrements `totalUnclaimableOf[t]` by exactly the amount transferred.
(`emergencyTransfer` is the owner-gated exception for the *live* token only —
it sweeps the live token's bank; a retired token's bank is out of its reach.)

Why it holds:

- **Funding is exact.** `startPromotion`/`topUpPromotion` measure the received
  balance delta and revert on shortfall (fee-on-transfer/rebasing tokens are
  rejected by policy), so `promoRewardBalance` is always fully backed on entry.
- **Accrual is capped.** `_updatePool` distributes
  `min(promoRewardPerSecond * dt / PRECISION, promoRewardBalance)`; a depleted
  stream is dormant (accrues zero) until topped up. The accumulator never
  promises unfunded value. The rate is recomputed **only** in `topUpPromotion`
  and `setPromoDepletionDuration`, never inside `_updatePool`.
- **Outflows are debt-gated.** Settlement (stake/withdraw/claim) and
  `batchClaim` both pay exactly `amount * accPromoPerShare / PRECISION −
  promoDebt` and realign the debt. Floor division leaves dust in the contract
  (protocol-favouring, as in §3).
- **Failed transfers stay inside — and stay owed.** A transfer that fails during
  the flush is banked per-user into `unclaimablePromoOf[token][user]` (and into
  the per-token aggregate `totalUnclaimableOf[token]`; event `PromoClaimFailed`)
  with the user's debt still aligned. The tokens never left, so the invariant is
  undisturbed, and the entitlement survives as a pullable liability
  (`claimUnclaimablePromo`) rather than being erased. `pendingPromo` reads 0 for
  a banked user **by design** — the liability lives in the bank views, not in
  pending.

### Rotation solvency (why finalize cannot strand liabilities)

`finalizePromotion` is only reachable when `flushCursor == stakerCount()` over a
set frozen by the pause, i.e. after **every** staker's pending was either paid or
banked and every `promoDebt` aligned to `accPromoPerShare`. At that moment
`Σ pendingPromo == 0`, but banked amounts are still owed to users, so the sweep
sends only the unencumbered portion —
`balanceOf(this) − totalUnclaimableOf[retiredToken]`, saturating at zero so the
finalize can never be bricked by accounting drift — to `leftoverRecipient`
(undistributed remainder + rounding dust + `pauseWithdraw` forfeits, which are
never banked and are legitimately swept). The bank (`unclaimablePromoOf` /
`totalUnclaimableOf`) is **not** cleared: it survives the rotation, fully
backed, until each user pulls it. The slot is cleared (`promoToken`/rate/balance
zeroed) but **`accPromoPerShare` is never reset** — debts are aligned to it, so
pending against the next partner token starts at exactly zero with no
cross-token liability. After finalize the live-slot invariant above is trivially
`0 >= 0`, and the retired-token invariant
`t.balanceOf(phlimbo) >= totalUnclaimableOf[t]` continues to hold.

`abortFlush` is solvency-neutral: `batchClaim` payments were correct early
claims, so returning to Active leaves state consistent.

## 5. Tooling

Per-user views:

- `pendingPhUSD(user)`, `pendingStable(user)`, `pendingPromo(user)` — live
  pending including un-checkpointed accrual since `lastRewardTime`. Note:
  `pendingPromo` deliberately excludes banked failed-transfer amounts.
- `unclaimablePromoOf(token, user)` — the user's banked promo for `token` (set
  when their flush transfer failed), pullable via `claimUnclaimablePromo(token)`.
  Works for retired tokens too.
- `userInfo(user)` → `(amount, phUSDDebt, stableDebt, promoDebt)`.

Aggregate views:

- `stakerCount()` / `stakerAt(i)` — full on-chain enumeration of every address
  with non-zero stake (V2 had no enumeration; this is what makes the Σ-pending
  terms in §3/§4 exactly computable on-chain or by an indexer).
- `getPoolInfo()` → `(totalStaked, accPhUSDPerShare, accStablePerShare,
  phUSDPerSecond, lastRewardTime)`.
- `getPromoInfo()` → `(promoToken, promoRewardBalance, promoRewardPerSecond,
  promoDepletionDuration, promoPhase, flushCursor)` — one call gives the promo
  slot's full funding/rate/rotation state.
- `totalUnclaimableOf(token)` — total banked failed-transfer liabilities for
  `token` (live or retired), reserved from the finalize sweep and outstanding
  until users pull them via `claimUnclaimablePromo`.

Solvency check procedure (any observer, no privileged access):

1. `phUSD.balanceOf(phlimbo) >= totalStaked` (§1).
2. phUSD mint privilege active for the contract (§2).
3. `rewardToken.balanceOf(phlimbo) − rewardBalance − Σ pendingStable >= 0` (§3).
4. If `getPromoInfo().token != 0`:
   `promoToken.balanceOf(phlimbo) − promoRewardBalance − Σ pendingPromo −
   totalUnclaimableOf(promoToken) >= 0` (§4), with the Σ terms enumerated via
   `stakerCount`/`stakerAt`.
5. For every token `t` ever used as a promo token (enumerable off-chain from
   `PromotionStarted` logs), including retired ones where
   `getPromoInfo().token` no longer points at `t`:
   `t.balanceOf(phlimbo) − totalUnclaimableOf(t) >= 0` (§4). A retired token
   with a non-zero bank holds a real liability even while `promoToken == 0`;
   step 4 alone does not cover it.
