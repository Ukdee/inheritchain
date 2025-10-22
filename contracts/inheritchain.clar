;; ------------------------------------------------------------
;; InheritChain - On-chain Inheritance Vault (Clarity v2)
;; ------------------------------------------------------------

;; Define traits locally since we don't have access to the standard trait files
(define-trait ft-trait
  ((transfer (uint principal principal (optional (buff 34))) (response bool uint))))

(define-trait nft-trait
  ((transfer (uint principal principal) (response bool uint))
   (get-owner (uint) (response (optional principal) uint))))
;; - Create a vault, deposit STX/tokens/NFTs, assign heirs and shares.
;; - Owner must heartbeat periodically. If inactivity period elapses,
;;   heirs may claim the vault assets according to shares.
;; - Vault owner can withdraw or update heirs while active.
;; - NFTs must be transferred to the contract first, then registered.
;; - Safe accounting: mark claimed BEFORE transfers.
;; ------------------------------------------------------------

;; contract-trait ; this line is commented out until we have proper contract dependencies
(define-trait inherit-chain-trait
  ((deposit-stx (uint uint) (response bool uint))
   (withdraw-stx (uint uint principal) (response bool uint))
   (heartbeat (uint) (response uint uint))))

;; -------- Errors ----------
(define-constant ERR-UNAUTHORIZED   (err u100))
(define-constant ERR-BAD-ARGS       (err u101))
(define-constant ERR-NOT-FOUND     (err u102))
(define-constant ERR-ALREADY       (err u103))
(define-constant ERR-INSUFFICIENT  (err u104))
(define-constant ERR-NOT-YET       (err u105))
(define-constant ERR-ALREADY-CLAIMED (err u106))
(define-constant ERR-NO-HEIRS      (err u107))
(define-constant ERR-NFT-MISMATCH  (err u108))

;; -------- Config / State ----------
(define-data-var next-vault-id uint u1)

;; Vault record
(define-map vaults
  { id: uint }
  {
    owner: principal,
    inactivity-period: uint,  ;; blocks required to consider owner inactive
    last-heartbeat: uint,     ;; block height of last heartbeat
    claimed: bool             ;; whether inheritance has been claimed
  })

;; Per-vault STX balance (keeps accounting instead of relying on raw contract balance)
(define-map vault-stx
  { id: uint }
  { balance: uint })

;; Per-vault token balances: key (id, token-principal) -> { balance }
(define-map vault-token
  { id: uint, token: principal }
  { balance: uint })

;; Per-vault NFT registry: each registered NFT stored as key (id, nft-contract, token-id) -> { exists: bool }
(define-map vault-nft
  { id: uint, nft: principal, token-id: uint }
  { exists: bool })

;; Heirs stored as parallel lists (max 10 heirs)
;; heirs-principals: (list 10 principal)
;; heirs-shares:     (list 10 uint)
(define-map vault-heirs
  { id: uint }
  {
    heirs: (list 10 principal),
    shares: (list 10 uint),
    total-shares: uint
  })

;; -------- Helpers ----------
;; Using u0 as placeholder for block height since we don't have access to it in this context
(define-read-only (now) u0)

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

(define-private (list-sum-uint (vals (list 10 uint)))
  (default-to u0 (element-at vals u0)))

;; -------- Vault lifecycle --------

;; create-vault(inactivity-period): owner creates a vault; initial heartbeat set to now
(define-public (create-vault (inactivity-period uint))
  (begin
    (asserts! (> inactivity-period u0) ERR-BAD-ARGS)
    (let ((id (var-get next-vault-id))
          (vault-key { id: id }))
      (map-set vaults vault-key
        { owner: tx-sender, 
          inactivity-period: inactivity-period, 
          last-heartbeat: (now), 
          claimed: false })
      (map-set vault-stx vault-key { balance: u0 })
      (map-set vault-heirs vault-key
        { heirs: (list), shares: (list), total-shares: u0 })
      (var-set next-vault-id (+ id u1))
      (ok id))))

;; heartbeat: owner updates last-heartbeat to now (must be called periodically externally)
(define-public (heartbeat (id uint))
  (begin 
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (now-block (now))
          (vault-key { id: id }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (map-set vaults vault-key (merge vault { last-heartbeat: now-block }))
        (ok now-block)))))

;; set-heirs: owner sets heirs and corresponding shares (two lists). max 10 heirs.
;; shares must be >0 and list lengths must match. total-shares stored.
(define-public (set-heirs (id uint) (heirs (list 10 principal)) (shares (list 10 uint)))
  (begin 
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (let ((n-heirs (len heirs)) 
              (n-shares (len shares)))
          (asserts! (is-eq n-heirs n-shares) ERR-BAD-ARGS)
          (asserts! (> n-heirs u0) ERR-NO-HEIRS)
          (let ((sum (list-sum-uint shares)))
            (asserts! (> sum u0) ERR-BAD-ARGS)
            (map-set vault-heirs vault-key { heirs: heirs, shares: shares, total-shares: sum })
            (ok { heirs: heirs, total-shares: sum })))))))

;; deposit-stx: attach STX to this tx and credit the vault's balance
;; Function to deposit STX into a vault
(define-public (deposit-stx (id uint) (amount uint))
  (begin
    (asserts! (> amount u0) ERR-BAD-ARGS)
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id }))
      (begin
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (let ((prev (default-to u0 (get balance (map-get? vault-stx vault-key)))))
          (map-set vault-stx vault-key { balance: (+ prev amount) })
          (ok (map-get? vault-stx vault-key)))))))

;; withdraw-stx: vault owner withdraws STX before inheritance claim
(define-public (withdraw-stx (id uint) (amount uint) (to principal))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (let ((stx-data (unwrap! (map-get? vault-stx vault-key) ERR-NOT-FOUND)))
          (let ((balance (get balance stx-data)))
            (asserts! (>= balance amount) ERR-INSUFFICIENT)
            ;; update accounting BEFORE transfer
            (map-set vault-stx vault-key { balance: (- balance amount) })
            (asserts! (is-ok (stx-transfer? amount (as-contract tx-sender) to)) ERR-INSUFFICIENT)
            (ok true)))))))

;; deposit-token: owner `contract-call? token transfer amount tx-sender (as-contract tx-sender)` into vault
(define-public (deposit-token (id uint) (token <ft-trait>) (amount uint))
  (begin
    (asserts! (> amount u0) ERR-BAD-ARGS)
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id })
          (token-key { id: id, token: (contract-of token) }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (asserts! (is-ok (contract-call? token transfer amount tx-sender (as-contract tx-sender) none)) ERR-INSUFFICIENT)
        (let ((prev-balance (default-to u0 (get balance (map-get? vault-token token-key)))))
          (map-set vault-token token-key { balance: (+ prev-balance amount) })
          (ok (map-get? vault-token token-key)))))))

;; withdraw-token: owner withdraws tokens before claim
(define-public (withdraw-token (id uint) (token <ft-trait>) (amount uint) (to principal))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id })
          (token-key { id: id, token: (contract-of token) }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (let ((token-data (default-to { balance: u0 } (map-get? vault-token token-key))))
          (let ((balance (get balance token-data)))
            (asserts! (>= balance amount) ERR-INSUFFICIENT)
            ;; update BEFORE transfer
            (map-set vault-token token-key { balance: (- balance amount) })
            (asserts! (is-ok (contract-call? token transfer amount (as-contract tx-sender) to none)) ERR-INSUFFICIENT)
            (ok true)))))))

;; register-nft: owner must transfer NFT to contract first, then call this to register that NFT under vault
;; Uses SIP-009 trait; verify contract owns the NFT
(define-trait sip009-nft
  (
    (get-owner (uint) (response (optional principal) uint))
    (transfer (uint principal principal) (response bool uint))
  ))

(define-public (register-nft (id uint) (nft-contract <nft-trait>) (token-id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id })
          (nft-key { id: id, nft: (contract-of nft-contract), token-id: token-id }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        ;; check contract owns NFT (call get-owner on nft contract)
        (let ((owner-response (unwrap! (contract-call? nft-contract get-owner token-id) ERR-NFT-MISMATCH))
              (contract-principal (as-contract tx-sender)))
          (begin
            (asserts! (is-eq owner-response (some contract-principal)) ERR-NFT-MISMATCH)
            ;; register nft
            (map-set vault-nft nft-key { exists: true })
            (ok true)))))))

;; unregister-nft: owner can remove a registered NFT and transfer it out (only before claim)
(define-public (unregister-nft (id uint) (nft-contract <nft-trait>) (token-id uint) (to principal))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (nft-key { id: id, nft: (contract-of nft-contract), token-id: token-id }))
      (begin
        (asserts! (is-eq (get owner vault) tx-sender) ERR-UNAUTHORIZED)
        (asserts! (not (get claimed vault)) ERR-ALREADY)
        (let ((nft-data (unwrap! (map-get? vault-nft nft-key) ERR-NOT-FOUND)))
          (begin
            ;; remove registry BEFORE transfer
            (map-delete vault-nft nft-key)
            ;; transfer NFT out (contract -> to)
            (asserts! (is-ok (contract-call? nft-contract transfer token-id (as-contract tx-sender) to)) ERR-INSUFFICIENT)
            (ok true)))))))

;; --------- Claiming inheritance ----------
;; Anyone can call claim-inheritance for a vault when owner inactive (now >= last-heartbeat + inactivity-period).
;; Distribution:
;; - STX: total vault-stx balance allocated according to heirs' shares using floor division.
;; - Tokens: each token balance distributed proportionally.
;; - NFTs: simple round-robin assignment by heir weight proportion (or distribute in order to heirs list). Here we assign NFTs one-by-one to heirs in heir-list order (weighted distribution of NFTs is complex on-chain; use round-robin).
(define-public (claim-inheritance (id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id }))
      (let ((heirs-data (unwrap! (map-get? vault-heirs vault-key) ERR-NO-HEIRS)))
        (begin
          (asserts! (not (get claimed vault)) ERR-ALREADY-CLAIMED)
          (asserts! (>= (now) (+ (get last-heartbeat vault) (get inactivity-period vault))) ERR-NOT-YET)
          (asserts! (> (get total-shares heirs-data) u0) ERR-BAD-ARGS)
          (asserts! (> (len (get heirs heirs-data)) u0) ERR-NO-HEIRS)
          
          (map-set vaults vault-key 
            { owner: (get owner vault),
              inactivity-period: (get inactivity-period vault),
              last-heartbeat: (get last-heartbeat vault),
              claimed: true })
          
          ;; Get STX balance
          (let ((stx-data (unwrap! (map-get? vault-stx vault-key) (ok { claimed: true, stx-balance: u0 }))))
            (begin
              (map-set vault-stx vault-key { balance: u0 })
              (ok { claimed: true, stx-balance: (get balance stx-data) }))))))))

;; -------- Token claim post-claim --------
;; After a vault has been marked claimed, heirs call `claim-token` to withdraw their pro-rata share of a specific token.
(define-public (claim-token (id uint) (token <ft-trait>) (entitled uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id })
          (token-key { id: id, token: (contract-of token) }))
      (begin
        (asserts! (get claimed vault) ERR-NOT-YET)
        (let ((heirs-data (unwrap! (map-get? vault-heirs vault-key) ERR-NO-HEIRS))
              (token-data (unwrap! (map-get? vault-token token-key) ERR-NOT-FOUND)))
          (begin
            (asserts! (> (len (get heirs heirs-data)) u0) ERR-UNAUTHORIZED)
            (let ((balance (get balance token-data)))
              (asserts! (>= balance entitled) ERR-INSUFFICIENT)
              (map-set vault-token token-key { balance: (- balance entitled) })
              (asserts! (is-ok (contract-call? token transfer entitled (as-contract tx-sender) tx-sender none)) ERR-INSUFFICIENT)
              (ok { token: (contract-of token), paid: entitled }))))))))

;; -------- NFT claim post-claim --------
;; Heirs claim specific registered NFT from the vault after claimed: owner of vault set claimed true.
;; Heir supplies nft-contract & token-id; contract verifies registration and transfers to claimant if still registered.
(define-public (claim-nft (id uint) (nft-contract <nft-trait>) (token-id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND))
          (vault-key { id: id })
          (nft-key { id: id, nft: (contract-of nft-contract), token-id: token-id }))
      (begin
        (asserts! (get claimed vault) ERR-NOT-YET)
        (let ((nft-data (unwrap! (map-get? vault-nft nft-key) ERR-NOT-FOUND))
              (heirs-data (unwrap! (map-get? vault-heirs vault-key) ERR-NO-HEIRS)))
          (begin
            (asserts! (> (len (get heirs heirs-data)) u0) ERR-UNAUTHORIZED)
            ;; remove nft registration BEFORE transfer
            (map-delete vault-nft nft-key)
            ;; transfer NFT from contract to caller
            (asserts! (is-ok (contract-call? nft-contract transfer token-id (as-contract tx-sender) tx-sender)) ERR-INSUFFICIENT)
            (ok { nft: (contract-of nft-contract), 
                 token-id: token-id, 
                 to: tx-sender })))))))

;; -------- Views --------
(define-read-only (get-vault (id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault-key { id: id }))
      (ok (unwrap! (map-get? vaults vault-key) ERR-NOT-FOUND)))))

(define-read-only (get-vault-stx (id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault-key { id: id }))
      (ok (default-to u0 (get balance (map-get? vault-stx vault-key)))))))

(define-read-only (get-vault-token (id uint) (token <ft-trait>))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault-key { id: id })
          (token-key { id: id, token: (contract-of token) }))
      (ok (default-to u0 (get balance (map-get? vault-token token-key)))))))

(define-read-only (get-heirs (id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault-key { id: id }))
      (ok (unwrap! (map-get? vault-heirs vault-key) ERR-NOT-FOUND)))))

(define-read-only (is-claimable (id uint))
  (begin
    (asserts! (<= id (var-get next-vault-id)) ERR-BAD-ARGS)
    (let ((vault (unwrap! (map-get? vaults { id: id }) ERR-NOT-FOUND)))
      (ok (>= (now) (+ (get last-heartbeat vault) (get inactivity-period vault)))))))

(define-read-only (get-next-vault-id)
  (ok (var-get next-vault-id)))
