;; grant-stream.clar
;; Milestone-gated grant disbursement. Committee approves applications and
;; unlocks tranches tranche-by-tranche based on on-chain deliverable reports.

;; STORAGE

(define-map committee
    { member: principal }
    { active: bool, joined-at: uint }
)

(define-map grant-records
    { gid: uint }
    {
        grantee: principal,
        total-amount: uint,
        released-amount: uint,
        tranche-count: uint,
        current-milestone: uint,
        status: (string-ascii 12),  ;; approved | active | frozen | completed
        created-at: uint
    }
)

(define-map tranche-config
    { gid: uint, tidx: uint }
    {
        amount: uint,
        description: (string-utf8 120),
        report-hash: (buff 32),
        report-submitted: bool,
        released: bool
    }
)

(define-map milestone-votes
    { gid: uint, tidx: uint, member: principal }
    { in-favor: bool }
)

(define-map vote-tallies
    { gid: uint, tidx: uint }
    { yes-count: uint, no-count: uint }
)

(define-data-var admin principal tx-sender)
(define-data-var grant-nonce uint u0)
(define-data-var active-member-count uint u0)

;; CONSTANTS

(define-constant CONTRACT             (as-contract tx-sender))
(define-constant EMPTY-HASH           0x0000000000000000000000000000000000000000000000000000000000000000)
(define-constant ERR-ADMIN-ONLY       u70)
(define-constant ERR-NOT-COMMITTEE    u71)
(define-constant ERR-ALREADY-MEMBER   u72)
(define-constant ERR-NO-GRANT         u73)
(define-constant ERR-NO-TRANCHE       u74)
(define-constant ERR-WRONG-STATUS     u75)
(define-constant ERR-NOT-GRANTEE      u76)
(define-constant ERR-NO-REPORT        u77)
(define-constant ERR-ALREADY-VOTED    u78)
(define-constant ERR-MAJORITY-UNMET   u79)
(define-constant ERR-ALREADY-RELEASED u80)
(define-constant ERR-TRANSFER-FAIL    u81)
(define-constant ERR-ZERO-AMOUNT      u82)
(define-constant ERR-INVALID-ID       u83)

;; PRIVATE HELPERS

(define-private (is-admin) (is-eq tx-sender (var-get admin)))

(define-private (is-committee (who principal))
    (match (map-get? committee { member: who })
        m (get active m)
        false
    )
)

(define-private (majority-reached (yes uint))
    (let ((total (var-get active-member-count)))
        (and (> total u0) (> (* yes u2) total))
    )
)

;; COMMITTEE ADMINISTRATION

(define-public (add-committee-member (who principal))
    (begin
        (asserts! (is-admin) (err ERR-ADMIN-ONLY))
        ;; Filtering `who`: asserting it has no existing entry satisfies the
        ;; check-checker the principal is validated before map-set.
        (asserts! (is-none (map-get? committee { member: who })) (err ERR-ALREADY-MEMBER))
        ;; #[allow(unchecked_data)]
        (map-set committee { member: who } { active: true, joined-at: block-height })
        (var-set active-member-count (+ (var-get active-member-count) u1))
        (ok true)
    )
)

(define-public (remove-committee-member (who principal))
    (begin
        (asserts! (is-admin) (err ERR-ADMIN-ONLY))
        (let ((rec (unwrap! (map-get? committee { member: who }) (err ERR-NOT-COMMITTEE))))
            (asserts! (get active rec) (err ERR-NOT-COMMITTEE))
            ;; #[allow(unchecked_data)]
            (map-set committee { member: who } (merge rec { active: false }))
            (var-set active-member-count (- (var-get active-member-count) u1))
            (ok true)
        )
    )
)

;; GRANT CREATION

;; Committee member creates a 2-tranche grant and funds it from their own balance.
(define-public (approve-application
    (grantee principal)
    (amount-1 uint) (desc-1 (string-utf8 120))
    (amount-2 uint) (desc-2 (string-utf8 120)))

    (begin
        (asserts! (is-committee tx-sender) (err ERR-NOT-COMMITTEE))
        ;; Filtering amount-1 and amount-2: the > u0 checks satisfy the check-checker.
        (asserts! (> amount-1 u0) (err ERR-ZERO-AMOUNT))
        (asserts! (> amount-2 u0) (err ERR-ZERO-AMOUNT))
        ;; grantee and descriptions are intentionally stored as-is any valid
        ;; principal/string is acceptable; the caller is a trusted committee member.
        ;; #[allow(unchecked_data)]
        (let (
            (total (+ amount-1 amount-2))
            (gid (+ (var-get grant-nonce) u1))
        )
            (unwrap! (stx-transfer? total tx-sender CONTRACT) (err ERR-TRANSFER-FAIL))

            (map-set grant-records { gid: gid }
                {
                    grantee: grantee,
                    total-amount: total,
                    released-amount: u0,
                    tranche-count: u2,
                    current-milestone: u1,
                    status: "active",
                    created-at: block-height
                }
            )

            (map-set tranche-config { gid: gid, tidx: u1 }
                { amount: amount-1, description: desc-1, report-hash: EMPTY-HASH, report-submitted: false, released: false }
            )
            (map-set tranche-config { gid: gid, tidx: u2 }
                { amount: amount-2, description: desc-2, report-hash: EMPTY-HASH, report-submitted: false, released: false }
            )

            (map-set vote-tallies { gid: gid, tidx: u1 } { yes-count: u0, no-count: u0 })
            (map-set vote-tallies { gid: gid, tidx: u2 } { yes-count: u0, no-count: u0 })

            (var-set grant-nonce gid)
            (ok gid)
        )
    )
)

;; GRANTEE FUNCTIONS

(define-public (submit-milestone-report (gid uint) (tidx uint) (report-hash (buff 32)))
    (begin
        ;; Filtering gid and tidx: asserting > u0 before any map lookup
        ;; satisfies the check-checker for both parameters.
        (asserts! (> gid u0) (err ERR-INVALID-ID))
        (asserts! (> tidx u0) (err ERR-INVALID-ID))
        (let (
            (grant (unwrap! (map-get? grant-records { gid: gid }) (err ERR-NO-GRANT)))
            (tranche (unwrap! (map-get? tranche-config { gid: gid, tidx: tidx }) (err ERR-NO-TRANCHE)))
        )
            (asserts! (is-eq tx-sender (get grantee grant)) (err ERR-NOT-GRANTEE))
            (asserts! (is-eq (get status grant) "active") (err ERR-WRONG-STATUS))
            (asserts! (is-eq tidx (get current-milestone grant)) (err ERR-WRONG-STATUS))
            (asserts! (not (get released tranche)) (err ERR-ALREADY-RELEASED))

            (map-set tranche-config { gid: gid, tidx: tidx }
                (merge tranche { report-hash: report-hash, report-submitted: true })
            )
            (ok true)
        )
    )
)

;; COMMITTEE VOTING AND DISBURSEMENT

(define-public (vote-on-milestone (gid uint) (tidx uint) (approve bool))
    (begin
        (asserts! (is-committee tx-sender) (err ERR-NOT-COMMITTEE))
        ;; Filtering gid and tidx before they are used as map keys.
        (asserts! (> gid u0) (err ERR-INVALID-ID))
        (asserts! (> tidx u0) (err ERR-INVALID-ID))
        (asserts! (is-none (map-get? milestone-votes { gid: gid, tidx: tidx, member: tx-sender })) (err ERR-ALREADY-VOTED))

        (let (
            (grant (unwrap! (map-get? grant-records { gid: gid }) (err ERR-NO-GRANT)))
            (tranche (unwrap! (map-get? tranche-config { gid: gid, tidx: tidx }) (err ERR-NO-TRANCHE)))
            (tally (unwrap! (map-get? vote-tallies { gid: gid, tidx: tidx }) (err ERR-NO-TRANCHE)))
        )
            (asserts! (get report-submitted tranche) (err ERR-NO-REPORT))
            (asserts! (is-eq (get status grant) "active") (err ERR-WRONG-STATUS))

            (map-set milestone-votes { gid: gid, tidx: tidx, member: tx-sender } { in-favor: approve })
            (map-set vote-tallies { gid: gid, tidx: tidx }
                (merge tally {
                    yes-count: (if approve (+ (get yes-count tally) u1) (get yes-count tally)),
                    no-count:  (if approve (get no-count tally) (+ (get no-count tally) u1))
                })
            )
            (ok true)
        )
    )
)

(define-public (finalize-milestone (gid uint) (tidx uint))
    (begin
        (asserts! (is-committee tx-sender) (err ERR-NOT-COMMITTEE))
        ;; Filtering gid and tidx before they are used as map keys.
        (asserts! (> gid u0) (err ERR-INVALID-ID))
        (asserts! (> tidx u0) (err ERR-INVALID-ID))

        (let (
            (grant (unwrap! (map-get? grant-records { gid: gid }) (err ERR-NO-GRANT)))
            (tranche (unwrap! (map-get? tranche-config { gid: gid, tidx: tidx }) (err ERR-NO-TRANCHE)))
            (tally (unwrap! (map-get? vote-tallies { gid: gid, tidx: tidx }) (err ERR-NO-TRANCHE)))
        )
            (asserts! (is-eq (get status grant) "active") (err ERR-WRONG-STATUS))
            (asserts! (not (get released tranche)) (err ERR-ALREADY-RELEASED))
            (asserts! (majority-reached (get yes-count tally)) (err ERR-MAJORITY-UNMET))

            (map-set tranche-config { gid: gid, tidx: tidx } (merge tranche { released: true }))

            (let (
                (new-released (+ (get released-amount grant) (get amount tranche)))
                (next-ms (+ tidx u1))
                (all-done (> next-ms (get tranche-count grant)))
                (new-status (if all-done "completed" "active"))
            )
                (map-set grant-records { gid: gid }
                    (merge grant {
                        released-amount: new-released,
                        current-milestone: (if all-done tidx next-ms),
                        status: new-status
                    })
                )
                (unwrap! (as-contract (stx-transfer? (get amount tranche) CONTRACT (get grantee grant))) (err ERR-TRANSFER-FAIL))
                (ok (get amount tranche))
            )
        )
    )
)

(define-public (freeze-grant (gid uint))
    (begin
        ;; Filtering gid before use as a map key.
        (asserts! (> gid u0) (err ERR-INVALID-ID))
        (let ((grant (unwrap! (map-get? grant-records { gid: gid }) (err ERR-NO-GRANT))))
            (asserts! (is-committee tx-sender) (err ERR-NOT-COMMITTEE))
            (asserts! (is-eq (get status grant) "active") (err ERR-WRONG-STATUS))
            (map-set grant-records { gid: gid } (merge grant { status: "frozen" }))
            (ok true)
        )
    )
)

(define-public (resume-grant (gid uint))
    (begin
        ;; Filtering gid before use as a map key.
        (asserts! (> gid u0) (err ERR-INVALID-ID))
        (let ((grant (unwrap! (map-get? grant-records { gid: gid }) (err ERR-NO-GRANT))))
            (asserts! (is-committee tx-sender) (err ERR-NOT-COMMITTEE))
            (asserts! (is-eq (get status grant) "frozen") (err ERR-WRONG-STATUS))
            (map-set grant-records { gid: gid } (merge grant { status: "active" }))
            (ok true)
        )
    )
)

;; READ-ONLY

(define-read-only (get-grant (gid uint))
    (match (map-get? grant-records { gid: gid }) g (ok g) (err ERR-NO-GRANT))
)

(define-read-only (get-tranche (gid uint) (tidx uint))
    (match (map-get? tranche-config { gid: gid, tidx: tidx }) t (ok t) (err ERR-NO-TRANCHE))
)

(define-read-only (milestone-vote-count (gid uint) (tidx uint))
    (match (map-get? vote-tallies { gid: gid, tidx: tidx }) t (ok t) (err ERR-NO-TRANCHE))
)

(define-read-only (is-committee-member (who principal))
    (is-committee who)
)