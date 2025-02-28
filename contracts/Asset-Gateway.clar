;; Asset Gateway Protocol
;; Enables multi-asset transfers with transaction fees

(define-map transfer-records
    { operation-id: (buff 32), asset: principal, quantity: uint, destination: principal }
    { completed: bool, block: uint })

(define-map authorized-assets principal bool)
(define-map executed-operations (buff 32) bool)
(define-map pending-withdrawals {asset: principal, account: principal} uint)
(define-trait asset-trait
    (
        (transfer (uint principal principal (optional (buff 34))) (response bool uint))
        (get-name () (response (string-ascii 32) uint))
        (get-symbol () (response (string-ascii 32) uint))
        (get-decimals () (response uint uint))
        (get-balance (principal) (response uint uint))
        (get-total-supply () (response uint uint))
        (get-token-uri () (response (optional (string-utf8 256)) uint))
    )
)

(define-constant MINIMUM_TRANSFER u100000)
(define-constant WITHDRAWAL_EXPIRY u144)
(define-constant GATEWAY_FEE u100) ;; 1% fee

;; Error codes
(define-constant ERR_NOT_AUTHORIZED (err u1))
(define-constant ERR_BELOW_MINIMUM (err u2))
(define-constant ERR_INSUFFICIENT_FUNDS (err u3))
(define-constant ERR_GATEWAY_LOCKED (err u4))
(define-constant ERR_INVALID_ACTION (err u5))
(define-constant ERR_INVALID_OPERATION (err u6))
(define-constant ERR_ALREADY_WITHDRAWN (err u7))
(define-constant ERR_WITHDRAWAL_TIMEOUT (err u8))
(define-constant ERR_INVALID_DESTINATION (err u9))
(define-constant ERR_INVALID_OPERATION_ID (err u10))
(define-constant ERR_ASSET_NOT_AUTHORIZED (err u11))
(define-constant ERR_FEE_ERROR (err u12))


;; Data Variables and Maps
(define-data-var protocol-admin principal tx-sender)
(define-data-var gateway-locked bool false)
(define-data-var minimum-quantity uint MINIMUM_TRANSFER)
(define-data-var fee-rate uint GATEWAY_FEE)

(define-map liquidity-pools {asset: principal, account: principal} uint)

;; Helper Functions
(define-private (meets-minimum-requirement (quantity uint))
    (>= quantity (var-get minimum-quantity)))

(define-private (is-protocol-admin)
    (is-eq tx-sender (var-get protocol-admin)))

(define-private (check-execution-status (operation-id (buff 32)))
    (default-to false (map-get? executed-operations operation-id)))

(define-private (validate-destination (destination principal))
    (and
        (not (is-eq destination tx-sender))
        (not (is-eq destination (var-get protocol-admin)))))

(define-private (is-asset-authorized (asset principal))
  (default-to false (map-get? authorized-assets asset)))

(define-private (get-liquidity-amount (pool-data {asset: principal, account: principal}))
  (default-to u0 (map-get? liquidity-pools pool-data)))

(define-private (calculate-gateway-fee (quantity uint))
  (let ((fee (/ (* quantity (var-get fee-rate)) u10000)))
    (if (> fee u0)
        (ok fee)
        (err u12))))

(define-private (validate-transfer-data (asset <asset-trait>) (quantity uint))
    (let ((sender tx-sender))
        (asserts! (not (var-get gateway-locked)) ERR_GATEWAY_LOCKED)
        (asserts! (meets-minimum-requirement quantity) ERR_BELOW_MINIMUM)
        (asserts! (is-asset-authorized (contract-of asset)) ERR_ASSET_NOT_AUTHORIZED)
        (asserts! (>= (get-liquidity-amount {asset: (contract-of asset), account: sender}) quantity) ERR_INSUFFICIENT_FUNDS)
        (ok true)))

;; Public Functions
(define-public (initiate-transfer (operation-id (buff 32)) (asset <asset-trait>) (quantity uint) (destination principal))
    (begin
        (asserts! (meets-minimum-requirement quantity) ERR_BELOW_MINIMUM)
        (asserts! (> (len operation-id) u0) ERR_INVALID_OPERATION_ID)
        (asserts! (validate-destination destination) ERR_INVALID_DESTINATION)
        (asserts! (is-asset-authorized (contract-of asset)) ERR_ASSET_NOT_AUTHORIZED)
        (let ((validated (try! (validate-transfer-data asset quantity))))
            (try! (contract-call? asset transfer quantity tx-sender (as-contract tx-sender) none))
            (map-set executed-operations operation-id true)
            (map-set transfer-records
                { operation-id: operation-id, asset: (contract-of asset), quantity: quantity, destination: destination }
                { completed: false, block: block-height })
            (ok true))))

(define-public (finalize-transfer (operation-id (buff 32)) (asset <asset-trait>) (quantity uint) (destination principal))
    (begin
        (asserts! (is-protocol-admin) ERR_NOT_AUTHORIZED)
        (asserts! (meets-minimum-requirement quantity) ERR_BELOW_MINIMUM)
        (asserts! (> (len operation-id) u0) ERR_INVALID_OPERATION_ID)
        (asserts! (validate-destination destination) ERR_INVALID_DESTINATION)
        (asserts! (is-asset-authorized (contract-of asset)) ERR_ASSET_NOT_AUTHORIZED)
        (match (map-get? transfer-records { operation-id: operation-id, asset: (contract-of asset), quantity: quantity, destination: destination })
            record-data (begin
                (asserts! (not (get completed record-data)) ERR_INVALID_ACTION)
                (let ((fee (try! (calculate-gateway-fee quantity)))
                      (net-amount (- quantity fee)))
                    (try! (as-contract (contract-call? asset transfer
                            fee
                            (as-contract tx-sender)
                            (var-get protocol-admin)
                            none)))
                    (try! (as-contract (contract-call? asset transfer
                        net-amount
                        (as-contract tx-sender)
                        destination
                        none)))
                    (ok (map-set transfer-records
                        { operation-id: operation-id, asset: (contract-of asset), quantity: quantity, destination: destination }
                        { completed: true, block: block-height }))))
            ERR_INVALID_ACTION)))

;; Admin function to add authorized assets
(define-public (add-authorized-asset (asset <asset-trait>))
  (begin
    (asserts! (is-protocol-admin) ERR_NOT_AUTHORIZED)
    (asserts! (is-ok (contract-call? asset get-name)) ERR_INVALID_ACTION)
    (ok (map-set authorized-assets (contract-of asset) true))))

;; Admin function to remove authorized assets
(define-public (remove-authorized-asset (asset principal))
  (begin
    (asserts! (is-protocol-admin) ERR_NOT_AUTHORIZED)
    (asserts! (is-asset-authorized asset) ERR_ASSET_NOT_AUTHORIZED)
    (ok (map-delete authorized-assets asset))))

;; Initialize contract (add initial authorized asset - e.g., STX)
(begin
    (map-set authorized-assets .stx true) ;; Example: STX is initially authorized
    (ok true))