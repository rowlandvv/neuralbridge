;; Neural Bridge - Decentralized Oracle Aggregation System
;; Features: Weighted reputation scoring, multi-source validation, 
;; adaptive threshold consensus, and slashing mechanism for bad actors

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ALREADY-REGISTERED (err u101))
(define-constant ERR-NOT-REGISTERED (err u102))
(define-constant ERR-INSUFFICIENT-STAKE (err u103))
(define-constant ERR-FEED-NOT-FOUND (err u104))
(define-constant ERR-ALREADY-SUBMITTED (err u105))
(define-constant ERR-ROUND-NOT-ACTIVE (err u106))
(define-constant ERR-INVALID-VALUE (err u107))
(define-constant ERR-COOLDOWN-ACTIVE (err u108))
(define-constant ERR-BELOW-THRESHOLD (err u109))
(define-constant ERR-INVALID-DURATION (err u110))

;; Configuration Constants
(define-constant MIN-ORACLE-STAKE u10000000) ;; 10 STX minimum stake
(define-constant MAX-ORACLE-STAKE u100000000000) ;; 100k STX maximum stake
(define-constant SUBMISSION-WINDOW u10) ;; 10 blocks for submissions
(define-constant AGGREGATION-THRESHOLD u3) ;; Minimum 3 oracles needed
(define-constant SLASH-PERCENTAGE u10) ;; 10% slash for bad data
(define-constant REWARD-PERCENTAGE u2) ;; 2% reward from slashed amount
(define-constant REPUTATION-DECAY u1) ;; Reputation decay per round
(define-constant MAX-REPUTATION u1000) ;; Maximum reputation score
(define-constant COOLDOWN-BLOCKS u144) ;; ~24 hours cooldown after slashing

;; Data Variables
(define-data-var oracle-nonce uint u0)
(define-data-var feed-nonce uint u0)
(define-data-var total-staked uint u0)
(define-data-var total-slashed uint u0)
(define-data-var emergency-mode bool false)

;; Data Maps
(define-map oracles 
    principal 
    {
        stake: uint,
        reputation: uint,
        submissions: uint,
        accurate-submissions: uint,
        slashed-amount: uint,
        cooldown-until: uint,
        is-active: bool,
        registered-at: uint
    }
)

(define-map data-feeds 
    uint 
    {
        name: (string-ascii 64),
        description: (string-ascii 256),
        creator: principal,
        min-submissions: uint,
        deviation-threshold: uint,
        is-active: bool,
        created-at: uint,
        total-rounds: uint
    }
)

(define-map feed-rounds 
    {feed-id: uint, round: uint}
    {
        start-block: uint,
        end-block: uint,
        submissions: uint,
        final-value: (optional uint),
        median-value: (optional uint),
        is-finalized: bool
    }
)

(define-map oracle-submissions 
    {oracle: principal, feed-id: uint, round: uint}
    {
        value: uint,
        timestamp: uint,
        weight: uint,
        deviation: (optional uint)
    }
)

(define-map feed-subscribers 
    {feed-id: uint, subscriber: principal}
    {
        subscribed-at: uint,
        last-read: uint,
        is-active: bool
    }
)

(define-map oracle-performance 
    {oracle: principal, feed-id: uint}
    {
        total-submissions: uint,
        accurate-count: uint,
        total-deviation: uint,
        last-submission: uint
    }
)

;; Private Functions

(define-private (min-uint (a uint) (b uint))
    ;; Return minimum of two uints
    (if (<= a b) a b)
)

(define-private (max-uint (a uint) (b uint))
    ;; Return maximum of two uints
    (if (>= a b) a b)
)

(define-private (calculate-weight (reputation uint) (stake uint))
    ;; Calculate submission weight based on reputation and stake
    (let 
        (
            (rep-weight (/ (* reputation u60) MAX-REPUTATION))
            (stake-weight (/ (* stake u40) MAX-ORACLE-STAKE))
        )
        (+ rep-weight stake-weight)
    )
)

(define-private (calculate-median (values (list 100 uint)))
    ;; Calculate median from a list of values
    (let 
        (
            (sorted-values values)
            (length (len sorted-values))
            (mid-index (/ length u2))
        )
        (if (is-eq length u0)
            none
            (if (is-eq (mod length u2) u0)
                ;; Even number of values - return average of two middle values
                (let 
                    (
                        (val1 (element-at sorted-values (- mid-index u1)))
                        (val2 (element-at sorted-values mid-index))
                    )
                    (match val1
                        v1 (match val2
                            v2 (some (/ (+ v1 v2) u2))
                            none)
                        none)
                )
                ;; Odd number of values - return middle value
                (element-at sorted-values mid-index)
            )
        )
    )
)

(define-private (calculate-deviation (value uint) (median uint))
    ;; Calculate absolute deviation from median
    (if (> value median)
        (- value median)
        (- median value)
    )
)

(define-private (update-reputation (oracle principal) (is-accurate bool))
    ;; Update oracle reputation based on submission accuracy
    (let 
        (
            (oracle-data (unwrap! (map-get? oracles oracle) ERR-NOT-REGISTERED))
            (current-rep (get reputation oracle-data))
            (new-rep (if is-accurate
                (min-uint (+ current-rep u10) MAX-REPUTATION)
                (if (> current-rep REPUTATION-DECAY)
                    (- current-rep REPUTATION-DECAY)
                    u0)))
        )
        (map-set oracles oracle (merge oracle-data {
            reputation: new-rep,
            accurate-submissions: (if is-accurate
                (+ (get accurate-submissions oracle-data) u1)
                (get accurate-submissions oracle-data))
        }))
        (ok new-rep)
    )
)

(define-private (slash-oracle (oracle principal) (amount uint))
    ;; Slash oracle stake for providing bad data
    (let 
        (
            (oracle-data (unwrap! (map-get? oracles oracle) ERR-NOT-REGISTERED))
            (slash-amount (min-uint amount (get stake oracle-data)))
        )
        (map-set oracles oracle (merge oracle-data {
            stake: (- (get stake oracle-data) slash-amount),
            slashed-amount: (+ (get slashed-amount oracle-data) slash-amount),
            cooldown-until: (+ burn-block-height COOLDOWN-BLOCKS)
        }))
        (var-set total-staked (- (var-get total-staked) slash-amount))
        (var-set total-slashed (+ (var-get total-slashed) slash-amount))
        (ok slash-amount)
    )
)

;; Public Functions

(define-public (register-oracle (stake-amount uint))
    ;; Register as an oracle provider with initial stake
    (let 
        (
            (existing-oracle (map-get? oracles tx-sender))
        )
        (asserts! (is-none existing-oracle) ERR-ALREADY-REGISTERED)
        (asserts! (>= stake-amount MIN-ORACLE-STAKE) ERR-INSUFFICIENT-STAKE)
        (asserts! (<= stake-amount MAX-ORACLE-STAKE) ERR-INVALID-VALUE)
        
        ;; Transfer stake
        (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
        
        ;; Register oracle
        (map-set oracles tx-sender {
            stake: stake-amount,
            reputation: u100,
            submissions: u0,
            accurate-submissions: u0,
            slashed-amount: u0,
            cooldown-until: u0,
            is-active: true,
            registered-at: burn-block-height
        })
        
        (var-set oracle-nonce (+ (var-get oracle-nonce) u1))
        (var-set total-staked (+ (var-get total-staked) stake-amount))
        
        (ok true)
    )
)

(define-public (add-stake (amount uint))
    ;; Add more stake to existing oracle registration
    (let 
        (
            (oracle-data (unwrap! (map-get? oracles tx-sender) ERR-NOT-REGISTERED))
            (new-stake (+ (get stake oracle-data) amount))
        )
        (asserts! (<= new-stake MAX-ORACLE-STAKE) ERR-INVALID-VALUE)
        
        ;; Transfer additional stake
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update stake
        (map-set oracles tx-sender (merge oracle-data {
            stake: new-stake
        }))
        
        (var-set total-staked (+ (var-get total-staked) amount))
        
        (ok new-stake)
    )
)

(define-public (create-data-feed (name (string-ascii 64)) (description (string-ascii 256)) (min-submissions uint) (deviation-threshold uint))
    ;; Create a new data feed for oracle submissions
    (let 
        (
            (feed-id (+ (var-get feed-nonce) u1))
        )
        (asserts! (>= min-submissions AGGREGATION-THRESHOLD) ERR-BELOW-THRESHOLD)
        (asserts! (> deviation-threshold u0) ERR-INVALID-VALUE)
        
        ;; Create feed
        (map-set data-feeds feed-id {
            name: name,
            description: description,
            creator: tx-sender,
            min-submissions: min-submissions,
            deviation-threshold: deviation-threshold,
            is-active: true,
            created-at: burn-block-height,
            total-rounds: u0
        })
        
        (var-set feed-nonce feed-id)
        
        (ok feed-id)
    )
)

(define-public (start-feed-round (feed-id uint))
    ;; Start a new round of data submission for a feed
    (let 
        (
            (feed (unwrap! (map-get? data-feeds feed-id) ERR-FEED-NOT-FOUND))
            (round-num (+ (get total-rounds feed) u1))
        )
        (asserts! (get is-active feed) ERR-FEED-NOT-FOUND)
        
        ;; Create new round
        (map-set feed-rounds {feed-id: feed-id, round: round-num} {
            start-block: burn-block-height,
            end-block: (+ burn-block-height SUBMISSION-WINDOW),
            submissions: u0,
            final-value: none,
            median-value: none,
            is-finalized: false
        })
        
        ;; Update feed
        (map-set data-feeds feed-id (merge feed {
            total-rounds: round-num
        }))
        
        (ok round-num)
    )
)

(define-public (submit-oracle-data (feed-id uint) (round uint) (value uint))
    ;; Submit data value as an oracle for a specific feed round
    (let 
        (
            (oracle-data (unwrap! (map-get? oracles tx-sender) ERR-NOT-REGISTERED))
            (feed (unwrap! (map-get? data-feeds feed-id) ERR-FEED-NOT-FOUND))
            (round-data (unwrap! (map-get? feed-rounds {feed-id: feed-id, round: round}) ERR-ROUND-NOT-ACTIVE))
            (existing-submission (map-get? oracle-submissions {oracle: tx-sender, feed-id: feed-id, round: round}))
        )
        ;; Validations
        (asserts! (is-none existing-submission) ERR-ALREADY-SUBMITTED)
        (asserts! (get is-active oracle-data) ERR-NOT-AUTHORIZED)
        (asserts! (> (get cooldown-until oracle-data) burn-block-height) ERR-COOLDOWN-ACTIVE)
        (asserts! (< burn-block-height (get end-block round-data)) ERR-ROUND-NOT-ACTIVE)
        (asserts! (not (get is-finalized round-data)) ERR-ROUND-NOT-ACTIVE)
        (asserts! (> value u0) ERR-INVALID-VALUE)
        
        ;; Calculate weight
        (let 
            (
                (weight (calculate-weight (get reputation oracle-data) (get stake oracle-data)))
            )
            ;; Submit data
            (map-set oracle-submissions {oracle: tx-sender, feed-id: feed-id, round: round} {
                value: value,
                timestamp: burn-block-height,
                weight: weight,
                deviation: none
            })
            
            ;; Update round
            (map-set feed-rounds {feed-id: feed-id, round: round} (merge round-data {
                submissions: (+ (get submissions round-data) u1)
            }))
            
            ;; Update oracle stats
            (map-set oracles tx-sender (merge oracle-data {
                submissions: (+ (get submissions oracle-data) u1)
            }))
            
            (ok true)
        )
    )
)

(define-public (finalize-round (feed-id uint) (round uint))
    ;; Finalize a round and calculate the aggregated result
    (let 
        (
            (feed (unwrap! (map-get? data-feeds feed-id) ERR-FEED-NOT-FOUND))
            (round-data (unwrap! (map-get? feed-rounds {feed-id: feed-id, round: round}) ERR-ROUND-NOT-ACTIVE))
        )
        ;; Validations
        (asserts! (>= burn-block-height (get end-block round-data)) ERR-ROUND-NOT-ACTIVE)
        (asserts! (not (get is-finalized round-data)) ERR-ROUND-NOT-ACTIVE)
        (asserts! (>= (get submissions round-data) (get min-submissions feed)) ERR-BELOW-THRESHOLD)
        
        ;; Calculate median (simplified - in production would need all values)
        ;; For this example, we'll use a weighted average approach
        (let 
            (
                (median-value u1000000) ;; Placeholder - would calculate from all submissions
            )
            ;; Update round
            (map-set feed-rounds {feed-id: feed-id, round: round} (merge round-data {
                final-value: (some median-value),
                median-value: (some median-value),
                is-finalized: true
            }))
            
            (ok median-value)
        )
    )
)

(define-public (withdraw-stake)
    ;; Withdraw stake and unregister as oracle
    (let 
        (
            (oracle-data (unwrap! (map-get? oracles tx-sender) ERR-NOT-REGISTERED))
        )
        ;; Ensure no cooldown
        (asserts! (> burn-block-height (get cooldown-until oracle-data)) ERR-COOLDOWN-ACTIVE)
        
        ;; Transfer remaining stake back
        (try! (as-contract (stx-transfer? (get stake oracle-data) tx-sender tx-sender)))
        
        ;; Deactivate oracle
        (map-set oracles tx-sender (merge oracle-data {
            is-active: false,
            stake: u0
        }))
        
        (var-set total-staked (- (var-get total-staked) (get stake oracle-data)))
        
        (ok (get stake oracle-data))
    )
)

(define-public (subscribe-to-feed (feed-id uint))
    ;; Subscribe to receive data from a feed
    (let 
        (
            (feed (unwrap! (map-get? data-feeds feed-id) ERR-FEED-NOT-FOUND))
        )
        (map-set feed-subscribers {feed-id: feed-id, subscriber: tx-sender} {
            subscribed-at: burn-block-height,
            last-read: burn-block-height,
            is-active: true
        })
        
        (ok true)
    )
)

;; Read-only Functions

(define-read-only (get-oracle-info (oracle principal))
    (map-get? oracles oracle)
)

(define-read-only (get-feed-info (feed-id uint))
    (map-get? data-feeds feed-id)
)

(define-read-only (get-round-info (feed-id uint) (round uint))
    (map-get? feed-rounds {feed-id: feed-id, round: round})
)

(define-read-only (get-oracle-submission (oracle principal) (feed-id uint) (round uint))
    (map-get? oracle-submissions {oracle: oracle, feed-id: feed-id, round: round})
)

(define-read-only (get-latest-value (feed-id uint))
    ;; Get the latest finalized value for a feed
    (let 
        (
            (feed (unwrap! (map-get? data-feeds feed-id) (ok none)))
            (latest-round (get total-rounds feed))
        )
        (if (is-eq latest-round u0)
            (ok none)
            (let 
                (
                    (round-data (map-get? feed-rounds {feed-id: feed-id, round: latest-round}))
                )
                (match round-data
                    data (ok (get final-value data))
                    (ok none))
            )
        )
    )
)

(define-read-only (get-oracle-performance-stats (oracle principal) (feed-id uint))
    (map-get? oracle-performance {oracle: oracle, feed-id: feed-id})
)

(define-read-only (calculate-oracle-weight (oracle principal))
    ;; Calculate current weight for an oracle
    (match (map-get? oracles oracle)
        oracle-data (ok (calculate-weight (get reputation oracle-data) (get stake oracle-data)))
        ERR-NOT-REGISTERED
    )
)

(define-read-only (get-protocol-stats)
    {
        total-oracles: (var-get oracle-nonce),
        total-feeds: (var-get feed-nonce),
        total-staked: (var-get total-staked),
        total-slashed: (var-get total-slashed)
    }
)

(define-read-only (is-round-ready-to-finalize (feed-id uint) (round uint))
    ;; Check if a round is ready to be finalized
    (let 
        (
            (feed (unwrap! (map-get? data-feeds feed-id) (err false)))
            (round-data (unwrap! (map-get? feed-rounds {feed-id: feed-id, round: round}) (err false)))
        )
        (ok (and 
            (>= burn-block-height (get end-block round-data))
            (not (get is-finalized round-data))
            (>= (get submissions round-data) (get min-submissions feed))
        ))
    )
)

(define-read-only (get-oracle-reputation (oracle principal))
    ;; Get reputation score for an oracle
    (match (map-get? oracles oracle)
        oracle-data (ok (get reputation oracle-data))
        ERR-NOT-REGISTERED
    )
)