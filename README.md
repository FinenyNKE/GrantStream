# grant-stream.clar

## Milestone-Gated Grant Disbursement on Stacks

`grant-stream.clar` is a Clarity smart contract that enables transparent,
accountable grant distribution on the Stacks blockchain. A committee of trusted
members approves grant applications and releases funds tranche-by-tranche only
after on-chain milestone reports are submitted and voted through by a majority.

---

## Overview

Traditional grant programs suffer from accountability gaps: funds are disbursed
upfront with little on-chain enforcement of deliverables. `grant-stream` solves
this by locking the full grant amount in the contract at approval time and
releasing each tranche only when:

- The grantee submits a verifiable milestone report (identified by a 32-byte hash).
- A majority of active committee members vote to approve that milestone.

This model aligns incentives between funders, committee members, and grantees,
while keeping every decision auditable on-chain.

---

## Architecture

```
Admin
  └── manages committee membership

Committee Members
  ├── approve-application  → funds locked in contract, grant created
  ├── vote-on-milestone    → cast yes/no after report is submitted
  └── finalize-milestone   → triggers STX transfer if majority reached

Grantee
  └── submit-milestone-report → posts hash of deliverable doc/artifact

Contract (escrow)
  └── holds STX until each tranche is finalized
```

Funds flow: `Committee Member wallet → Contract → Grantee wallet`

The committee member who calls `approve-application` is the one whose wallet
funds the grant. This keeps the treasury management simple and explicit.

---

## Roles

### Admin

The deployer of the contract becomes the initial admin. The admin can:

- Add new committee members (`add-committee-member`)
- Remove (deactivate) existing committee members (`remove-committee-member`)

The admin role is stored in a `define-data-var` and cannot be transferred in
the current version.

### Committee Member

Any principal added by the admin. Committee members can:

- Approve grant applications (and fund them from their own wallet)
- Vote on milestone reports (once per milestone per member)
- Finalize milestones when majority is met
- Freeze or resume active grants

### Grantee

The principal designated in `approve-application`. Grantees can:

- Submit milestone reports for their current milestone tranche

---

## Data Structures

### `committee` map

```
key:   { member: principal }
value: { active: bool, joined-at: uint }
```

Tracks whether a principal is an active committee member and when they joined
(in block height).

### `grant-records` map

```
key:   { gid: uint }
value: {
  grantee: principal,
  total-amount: uint,
  released-amount: uint,
  tranche-count: uint,
  current-milestone: uint,
  status: (string-ascii 12),
  created-at: uint
}
```

Status values: `"active"`, `"frozen"`, `"completed"`.

### `tranche-config` map

```
key:   { gid: uint, tidx: uint }
value: {
  amount: uint,
  description: (string-utf8 120),
  report-hash: (buff 32),
  report-submitted: bool,
  released: bool
}
```

Each grant has exactly 2 tranches (tidx = 1 and tidx = 2).

### `milestone-votes` map

```
key:   { gid: uint, tidx: uint, member: principal }
value: { in-favor: bool }
```

Records each committee member's vote. A member can only vote once per milestone.

### `vote-tallies` map

```
key:   { gid: uint, tidx: uint }
value: { yes-count: uint, no-count: uint }
```

Running totals used by `majority-reached` to determine if finalization is
allowed.

### Data Variables

| Variable              | Type      | Description                                |
|-----------------------|-----------|--------------------------------------------|
| `admin`               | principal | Contract administrator                     |
| `grant-nonce`         | uint      | Auto-incrementing grant ID counter         |
| `active-member-count` | uint      | Count of currently active committee members|

---

## Public Functions

### `add-committee-member (who principal)`

Admin-only. Adds `who` as an active committee member. Increments
`active-member-count`. Fails if `who` is already a member.

### `remove-committee-member (who principal)`

Admin-only. Deactivates a committee member. Decrements `active-member-count`.
Fails if `who` is not an active member.

### `approve-application (grantee, amount-1, desc-1, amount-2, desc-2)`

Committee-only. Creates a 2-tranche grant:

1. Validates caller is a committee member and both amounts are non-zero.
2. Transfers `amount-1 + amount-2` STX from caller to the contract.
3. Initialises `grant-records`, both `tranche-config` entries, and both
   `vote-tallies` entries.
4. Returns the new grant ID (`gid`).

### `submit-milestone-report (gid, tidx, report-hash)`

Grantee-only. Records the 32-byte hash of the off-chain deliverable for the
current milestone. Only the current milestone's tranche can receive a report.
The grant must be `"active"` and the tranche must not already be released.

### `vote-on-milestone (gid, tidx, approve)`

Committee-only. Cast a yes (`true`) or no (`false`) vote on a milestone.
Requires the report to have been submitted. Each member may vote at most once
per milestone.

### `finalize-milestone (gid, tidx)`

Committee-only. Releases the tranche if a simple majority has voted yes:

- Marks tranche as `released: true`.
- Sends the tranche STX to the grantee via `as-contract stx-transfer?`.
- Advances `current-milestone` (or marks the grant `"completed"` if all
  tranches are done).

### `freeze-grant (gid)`

Committee-only. Sets an active grant's status to `"frozen"`, preventing report
submissions, votes, and finalization until resumed.

### `resume-grant (gid)`

Committee-only. Restores a frozen grant to `"active"` status.

---

## Read-Only Functions

### `get-grant (gid)`

Returns the full `grant-records` entry for `gid`, or `ERR-NO-GRANT`.

### `get-tranche (gid, tidx)`

Returns the full `tranche-config` entry, or `ERR-NO-TRANCHE`.

### `milestone-vote-count (gid, tidx)`

Returns `{ yes-count, no-count }` for the given milestone, or `ERR-NO-TRANCHE`.

### `is-committee-member (who)`

Returns `true` if `who` is an active committee member, `false` otherwise.

---

## Error Codes

| Code | Constant              | Meaning                                           |
|------|-----------------------|---------------------------------------------------|
| u70  | ERR-ADMIN-ONLY        | Caller is not the admin                           |
| u71  | ERR-NOT-COMMITTEE     | Caller is not an active committee member          |
| u72  | ERR-ALREADY-MEMBER    | Principal is already a committee member           |
| u73  | ERR-NO-GRANT          | Grant ID does not exist                           |
| u74  | ERR-NO-TRANCHE        | Tranche index does not exist for this grant       |
| u75  | ERR-WRONG-STATUS      | Grant is not in the required status               |
| u76  | ERR-NOT-GRANTEE       | Caller is not the grantee of this grant           |
| u77  | ERR-NO-REPORT         | Milestone report has not been submitted yet       |
| u78  | ERR-ALREADY-VOTED     | Caller has already voted on this milestone        |
| u79  | ERR-MAJORITY-UNMET    | Not enough yes votes to finalize                  |
| u80  | ERR-ALREADY-RELEASED  | This tranche has already been released            |
| u81  | ERR-TRANSFER-FAIL     | STX transfer failed                               |
| u82  | ERR-ZERO-AMOUNT       | A tranche amount of zero is not allowed           |

---

## Grant Lifecycle

```
approve-application
        │
        ▼
   status: "active"
   current-milestone: 1
        │
        ▼
submit-milestone-report (tidx=1)
        │
        ▼
vote-on-milestone (multiple members)
        │
        ▼
finalize-milestone (tidx=1)  ──► STX released to grantee
        │
        ▼
   current-milestone: 2
        │
        ▼
submit-milestone-report (tidx=2)
        │
        ▼
vote-on-milestone (multiple members)
        │
        ▼
finalize-milestone (tidx=2)  ──► STX released to grantee
        │
        ▼
   status: "completed"
```

At any point while `status == "active"`, a committee member may call
`freeze-grant` to pause the process. `resume-grant` restores normal flow.

---

## Voting Mechanism

Majority is defined as: `yes-count * 2 > active-member-count`

This is a strict simple majority (more than half). Examples:

| Committee Size | Votes Needed to Pass |
|---------------|----------------------|
| 1             | 1                    |
| 2             | 2                    |
| 3             | 2                    |
| 4             | 3                    |
| 5             | 3                    |

Votes are irreversible once cast. There is no quorum requirement beyond
majority — abstaining members effectively count against approval since
the denominator is `active-member-count`, not `total-votes-cast`.

---

## Security Considerations

- **Escrow safety**: Funds are held by the contract (`as-contract tx-sender`)
  and can only exit via `finalize-milestone` to the designated grantee.
- **No admin backdoor**: The admin cannot withdraw funds or override votes.
- **One vote per member**: The `milestone-votes` map enforces this with an
  `is-none` check before recording a vote.
- **Milestone ordering**: Grantees can only submit a report for
  `current-milestone`. You cannot skip ahead or re-submit for past milestones.
- **Freeze as a safety valve**: If a grantee goes dark or submits fraudulent
  work, the committee can freeze the grant before any vote is finalized.
- **No re-entrancy risk**: Clarity is not susceptible to re-entrancy by design;
  all state writes complete before the transfer in `finalize-milestone`.

---

## Deployment

1. Deploy the contract to Stacks mainnet or testnet using the Stacks CLI or
   Clarinet:

   ```bash
   clarinet contract publish grant-stream
   ```

2. The deploying address becomes `admin` automatically.

3. Add committee members:

   ```clarity
   (contract-call? .grant-stream add-committee-member 'SP...)
   ```

4. A committee member can now call `approve-application` to create the first
   grant, funding it from their wallet.

---

## Example Walkthrough

```
;; Step 1 – admin adds two committee members
(contract-call? .grant-stream add-committee-member 'SP_ALICE)
(contract-call? .grant-stream add-committee-member 'SP_BOB)

;; Step 2 – Alice approves a grant for Carol (500 + 500 STX)
;; Alice's wallet is debited 1000 STX
(contract-call? .grant-stream approve-application
  'SP_CAROL
  u500000000 u"Deliver prototype and test suite"
  u500000000 u"Ship production release and audit report")
;; Returns (ok u1)  ← grant ID is 1

;; Step 3 – Carol submits her tranche-1 milestone report
(contract-call? .grant-stream submit-milestone-report u1 u1 0xABCD...)

;; Step 4 – Alice and Bob both vote yes
(contract-call? .grant-stream vote-on-milestone u1 u1 true)   ;; Alice
(contract-call? .grant-stream vote-on-milestone u1 u1 true)   ;; Bob

;; Step 5 – Alice finalizes; 500 STX sent to Carol
(contract-call? .grant-stream finalize-milestone u1 u1)
;; Returns (ok u500000000)

;; Repeat steps 3-5 for tranche 2
```

---

## Testing Checklist

- [ ] Non-committee member cannot call `approve-application`
- [ ] Zero-amount tranches are rejected
- [ ] Grantee cannot submit report for wrong milestone index
- [ ] Committee member cannot vote twice on same milestone
- [ ] Minority yes-votes do not allow finalization
- [ ] Finalization sends exact tranche amount to grantee
- [ ] Grant status becomes `"completed"` after tranche 2 finalized
- [ ] Frozen grant blocks report submission and voting
- [ ] Resumed grant allows normal flow to continue
- [ ] Non-admin cannot add or remove committee members

---

## Limitations & Future Work

- **Fixed 2 tranches**: The current design hard-codes `tranche-count: u2`.
  A future version could accept a variable number of tranches.
- **Non-transferable admin**: Admin role cannot be transferred to a multisig
  or DAO address without redeployment.
- **No partial refund**: If a grant is frozen permanently, the escrowed STX
  is locked. A `reclaim-frozen-grant` function could be added with a timelock.
- **No on-chain report storage**: Only a 32-byte hash is stored. The actual
  deliverable is expected to live on IPFS, Gaia, or another decentralised
  storage layer.
- **Single token (STX)**: The contract does not support SIP-010 fungible tokens.
  A token-agnostic version would increase flexibility for DAOs using custom
  governance tokens.
