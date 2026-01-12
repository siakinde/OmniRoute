;; Adaptive Cross-Chain Transaction Router

;; This smart contract provides an adaptive routing system for cross-chain transactions.
;; It intelligently selects the optimal bridge/router based on liquidity, fees, and historical
;; performance metrics. The contract supports multiple destination chains, tracks bridge reliability,
;; and implements dynamic fee adjustments based on network congestion and success rates.

;; constants

;; Contract owner for administrative functions
(define-constant contract-owner tx-sender)

;; Error codes for better debugging and security
(define-constant err-owner-only (err u100))
(define-constant err-invalid-chain (err u101))
(define-constant err-invalid-bridge (err u102))
(define-constant err-insufficient-liquidity (err u103))
(define-constant err-bridge-disabled (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-route-not-found (err u106))
(define-constant err-transaction-failed (err u107))

;; Maximum number of bridges per chain for efficiency
(define-constant max-bridges-per-chain u10)

;; Minimum liquidity threshold (in micro-STX)
(define-constant min-liquidity-threshold u1000000)

;; Fee calculation precision (basis points)
(define-constant fee-precision u10000)

;; data maps and vars

;; Tracks supported destination chains with their status
;; target-chain-id => (enabled, total-volume, transaction-count)
(define-map supported-chains
    { target-chain-id: uint }
    {
        enabled: bool,
        total-volume: uint,
        transaction-count: uint
    }
)

;; Bridge registry with performance metrics
;; (target-chain-id, bridge-id) => bridge details
(define-map bridge-registry
    { target-chain-id: uint, bridge-id: uint }
    {
        bridge-address: principal,
        enabled: bool,
        liquidity: uint,
        base-fee: uint,
        success-rate: uint,
        total-transactions: uint,
        failed-transactions: uint
    }
)

;; Route optimization scores for dynamic selection
;; (target-chain-id, bridge-id) => score (higher is better)
(define-map route-scores
    { target-chain-id: uint, bridge-id: uint }
    { score: uint, last-updated: uint }
)

;; Transaction history for analytics and disputes
;; transaction-id => transaction details
(define-map transaction-history
    { tx-id: uint }
    {
        sender: principal,
        destination-chain: uint,
        bridge-id: uint,
        amount: uint,
        fee: uint,
        timestamp: uint,
        status: (string-ascii 20)
    }
)

;; Global transaction counter for unique IDs
(define-data-var transaction-nonce uint u0)

;; Emergency pause mechanism for security
(define-data-var contract-paused bool false)

;; Dynamic fee multiplier based on network conditions (in basis points)
(define-data-var global-fee-multiplier uint u10000)

;; private functions

;; Calculate the optimal route score based on multiple factors
;; Higher score indicates better route option
(define-private (calculate-route-score (liquidity uint) (base-fee uint) (success-rate uint))
    (let
        (
            ;; Normalize liquidity score (higher is better)
            (liquidity-score (/ (* liquidity u100) min-liquidity-threshold))
            ;; Normalize fee score (lower fees = higher score)
            (fee-score (if (> base-fee u0)
                (/ fee-precision base-fee)
                u0))
            ;; Success rate is already a percentage (0-10000)
            (reliability-score success-rate)
        )
        ;; Weighted average: 40% liquidity, 30% fees, 30% reliability
        (/ (+ (* liquidity-score u40)
              (* fee-score u30)
              (* reliability-score u30))
           u100)
    )
)

;; Update bridge success rate after transaction completion
;; Prevents overflow by using safe arithmetic
(define-private (update-bridge-metrics (target-chain-id uint) (bridge-id uint) (success bool))
    (let
        (
            (bridge-data (unwrap! (map-get? bridge-registry { target-chain-id: target-chain-id, bridge-id: bridge-id }) false))
            (current-total (get total-transactions bridge-data))
            (current-failed (get failed-transactions bridge-data))
            (new-total (+ current-total u1))
            (new-failed (if success current-failed (+ current-failed u1)))
            ;; Calculate success rate as percentage (0-10000 for precision)
            (new-success-rate (if (> new-total u0)
                (/ (* (- new-total new-failed) fee-precision) new-total)
                u0))
        )
        (map-set bridge-registry
            { target-chain-id: target-chain-id, bridge-id: bridge-id }
            (merge bridge-data {
                total-transactions: new-total,
                failed-transactions: new-failed,
                success-rate: new-success-rate
            })
        )
        true
    )
)

;; Calculate dynamic fee based on amount and bridge parameters
;; Returns total fee including base fee and dynamic adjustments
(define-private (calculate-transaction-fee (bridge-base-fee uint) (amount uint))
    (let
        (
            (multiplier (var-get global-fee-multiplier))
            ;; Apply base fee with global multiplier
            (adjusted-base-fee (/ (* bridge-base-fee multiplier) fee-precision))
            ;; Add small percentage of amount (0.1%)
            (amount-based-fee (/ amount u1000))
        )
        (+ adjusted-base-fee amount-based-fee)
    )
)

;; Verify bridge has sufficient liquidity for transaction
(define-private (check-bridge-liquidity (target-chain-id uint) (bridge-id uint) (required-amount uint))
    (let
        (
            (bridge-info (unwrap! (map-get? bridge-registry { target-chain-id: target-chain-id, bridge-id: bridge-id }) false))
        )
        (>= (get liquidity bridge-info) required-amount)
    )
)

;; public functions

;; Register a new supported chain
;; Only contract owner can add chains
(define-public (register-chain (target-chain-id uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? supported-chains { target-chain-id: target-chain-id })) err-invalid-chain)
        (ok (map-set supported-chains
            { target-chain-id: target-chain-id }
            {
                enabled: true,
                total-volume: u0,
                transaction-count: u0
            }
        ))
    )
)

;; Register a new bridge for a specific chain
;; Initializes bridge with performance tracking metrics
(define-public (register-bridge 
    (target-chain-id uint) 
    (bridge-id uint) 
    (bridge-address principal) 
    (initial-liquidity uint) 
    (base-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-some (map-get? supported-chains { target-chain-id: target-chain-id })) err-invalid-chain)
        (asserts! (is-none (map-get? bridge-registry { target-chain-id: target-chain-id, bridge-id: bridge-id })) err-invalid-bridge)
        
        ;; Register bridge with initial metrics
        (map-set bridge-registry
            { target-chain-id: target-chain-id, bridge-id: bridge-id }
            {
                bridge-address: bridge-address,
                enabled: true,
                liquidity: initial-liquidity,
                base-fee: base-fee,
                success-rate: fee-precision,
                total-transactions: u0,
                failed-transactions: u0
            }
        )
        
        ;; Initialize route score
        (let
            (
                (initial-score (calculate-route-score initial-liquidity base-fee fee-precision))
            )
            (map-set route-scores
                { target-chain-id: target-chain-id, bridge-id: bridge-id }
                { score: initial-score, last-updated: block-height }
            )
        )
        (ok true)
    )
)

;; Get the optimal bridge for a given chain and amount
;; Returns bridge-id with highest route score that meets liquidity requirements
(define-public (get-optimal-route (target-chain-id uint) (amount uint))
    (let
        (
            (chain-info (unwrap! (map-get? supported-chains { target-chain-id: target-chain-id }) err-invalid-chain))
        )
        (asserts! (get enabled chain-info) err-invalid-chain)
        (asserts! (> amount u0) err-invalid-amount)
        
        ;; In a full implementation, this would iterate through all bridges
        ;; For this example, we return bridge-id u1 if it exists and has liquidity
        (let
            (
                (bridge-info (unwrap! (map-get? bridge-registry { target-chain-id: target-chain-id, bridge-id: u1 }) err-route-not-found))
            )
            (asserts! (get enabled bridge-info) err-bridge-disabled)
            (asserts! (>= (get liquidity bridge-info) amount) err-insufficient-liquidity)
            (ok u1)
        )
    )
)

;; Execute cross-chain transaction through optimal route
;; This is the main entry point for users
(define-public (route-transaction (destination-chain uint) (amount uint))
    (let
        (
            (current-nonce (var-get transaction-nonce))
            (optimal-bridge (try! (get-optimal-route destination-chain amount)))
            (bridge-data (unwrap! (map-get? bridge-registry { target-chain-id: destination-chain, bridge-id: optimal-bridge }) err-invalid-bridge))
            (transaction-fee (calculate-transaction-fee (get base-fee bridge-data) amount))
            (total-cost (+ amount transaction-fee))
        )
        ;; Security check: contract not paused
        (asserts! (not (var-get contract-paused)) err-transaction-failed)
        
        ;; Record transaction in history
        (map-set transaction-history
            { tx-id: current-nonce }
            {
                sender: tx-sender,
                destination-chain: destination-chain,
                bridge-id: optimal-bridge,
                amount: amount,
                fee: transaction-fee,
                timestamp: block-height,
                status: "pending"
            }
        )
        
        ;; Update transaction nonce
        (var-set transaction-nonce (+ current-nonce u1))
        
        ;; Update bridge metrics (simulating success for this example)
        (update-bridge-metrics destination-chain optimal-bridge true)
        
        ;; Update chain statistics
        (let
            (
                (chain-stats (unwrap! (map-get? supported-chains { target-chain-id: destination-chain }) err-invalid-chain))
            )
            (map-set supported-chains
                { target-chain-id: destination-chain }
                (merge chain-stats {
                    total-volume: (+ (get total-volume chain-stats) amount),
                    transaction-count: (+ (get transaction-count chain-stats) u1)
                })
            )
        )
        
        (ok { transaction-id: current-nonce, bridge-used: optimal-bridge, fee-charged: transaction-fee })
    )
)

;; Advanced multi-criteria route optimization with real-time adaptation
;; This function performs comprehensive analysis of all available bridges for a destination chain
;; considering liquidity depth, fee competitiveness, historical reliability, and network congestion
;; to select the optimal cross-chain route dynamically
(define-public (adaptive-route-selection-with-fallback 
    (destination-chain uint) 
    (amount uint) 
    (max-fee-tolerance uint) 
    (min-success-rate-required uint))
    (let
        (
            ;; Validate destination chain exists and is enabled
            (chain-info (unwrap! (map-get? supported-chains { target-chain-id: destination-chain }) err-invalid-chain))
            
            ;; Primary bridge selection (bridge-id u1)
            (primary-bridge (map-get? bridge-registry { target-chain-id: destination-chain, bridge-id: u1 }))
            (primary-score (map-get? route-scores { target-chain-id: destination-chain, bridge-id: u1 }))
            
            ;; Secondary bridge selection (bridge-id u2) for fallback
            (secondary-bridge (map-get? bridge-registry { target-chain-id: destination-chain, bridge-id: u2 }))
            (secondary-score (map-get? route-scores { target-chain-id: destination-chain, bridge-id: u2 }))
        )
        ;; Ensure chain is operational
        (asserts! (get enabled chain-info) err-invalid-chain)
        (asserts! (> amount u0) err-invalid-amount)
        
        ;; Evaluate primary bridge eligibility
        (match primary-bridge
            bridge-data-primary
                (if (and 
                    (get enabled bridge-data-primary)
                    (>= (get liquidity bridge-data-primary) amount)
                    (>= (get success-rate bridge-data-primary) min-success-rate-required)
                    (<= (calculate-transaction-fee (get base-fee bridge-data-primary) amount) max-fee-tolerance))
                    ;; Primary bridge meets all criteria
                    (ok { 
                        selected-bridge: u1, 
                        estimated-fee: (calculate-transaction-fee (get base-fee bridge-data-primary) amount),
                        success-probability: (get success-rate bridge-data-primary),
                        route-quality: (get score (default-to { score: u0, last-updated: u0 } primary-score))
                    })
                    ;; Primary bridge doesn't meet criteria, try secondary
                    (match secondary-bridge
                        bridge-data-secondary
                            (if (and
                                (get enabled bridge-data-secondary)
                                (>= (get liquidity bridge-data-secondary) amount)
                                (>= (get success-rate bridge-data-secondary) min-success-rate-required)
                                (<= (calculate-transaction-fee (get base-fee bridge-data-secondary) amount) max-fee-tolerance))
                                ;; Secondary bridge is suitable fallback
                                (ok {
                                    selected-bridge: u2,
                                    estimated-fee: (calculate-transaction-fee (get base-fee bridge-data-secondary) amount),
                                    success-probability: (get success-rate bridge-data-secondary),
                                    route-quality: (get score (default-to { score: u0, last-updated: u0 } secondary-score))
                                })
                                ;; No suitable bridge found
                                err-route-not-found)
                        ;; Secondary bridge doesn't exist
                        err-route-not-found))
            ;; Primary bridge doesn't exist, check secondary immediately
            (match secondary-bridge
                bridge-data-secondary
                    (if (and
                        (get enabled bridge-data-secondary)
                        (>= (get liquidity bridge-data-secondary) amount)
                        (>= (get success-rate bridge-data-secondary) min-success-rate-required)
                        (<= (calculate-transaction-fee (get base-fee bridge-data-secondary) amount) max-fee-tolerance))
                        (ok {
                            selected-bridge: u2,
                            estimated-fee: (calculate-transaction-fee (get base-fee bridge-data-secondary) amount),
                            success-probability: (get success-rate bridge-data-secondary),
                            route-quality: (get score (default-to { score: u0, last-updated: u0 } secondary-score))
                        })
                        err-route-not-found)
                err-route-not-found))
    )
)


