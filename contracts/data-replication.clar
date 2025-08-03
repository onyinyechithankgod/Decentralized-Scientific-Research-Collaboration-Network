;; Data Replication Verification Contract
;; Validates that research findings can be reproduced by independent scientists

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-DATASET-NOT-FOUND (err u301))
(define-constant ERR-REPLICATION-NOT-FOUND (err u302))
(define-constant ERR-INVALID-STATUS (err u303))
(define-constant ERR-ALREADY-ATTEMPTED (err u304))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u305))

;; Data Variables
(define-data-var next-dataset-id uint u1)
(define-data-var next-replication-id uint u1)
(define-data-var total-datasets uint u0)
(define-data-var total-replications uint u0)

;; Data Maps
(define-map datasets
  { dataset-id: uint }
  {
    title: (string-ascii 200),
    data-hash: (string-ascii 64),
    methodology-hash: (string-ascii 64),
    description: (string-ascii 500),
    original-researcher: principal,
    institution: (string-ascii 100),
    registration-time: uint,
    replication-attempts: uint,
    successful-replications: uint,
    integrity-score: uint,
    status: (string-ascii 20)
  }
)

(define-map replications
  { replication-id: uint }
  {
    dataset-id: uint,
    replicator: principal,
    replicator-institution: (string-ascii 100),
    result-hash: (string-ascii 64),
    methodology-followed: bool,
    success-status: (string-ascii 20),
    confidence-level: uint,
    submission-time: uint,
    verification-time: (optional uint),
    verified-by: (optional principal),
    notes: (string-ascii 300)
  }
)

(define-map researcher-reputation
  { researcher: principal }
  {
    successful-replications: uint,
    failed-replications: uint,
    datasets-registered: uint,
    reputation-score: uint,
    verified-researcher: bool
  }
)

(define-map dataset-replications
  { dataset-id: uint }
  { replication-ids: (list 50 uint) }
)

(define-map institution-datasets
  { institution: (string-ascii 100) }
  { dataset-ids: (list 100 uint), total-count: uint }
)

;; Authorization checks
(define-private (is-authorized-admin (sender principal))
  (is-eq sender CONTRACT-OWNER))

(define-private (is-dataset-owner (sender principal) (dataset-id uint))
  (match (map-get? datasets { dataset-id: dataset-id })
    dataset (is-eq sender (get original-researcher dataset))
    false))

(define-private (has-sufficient-reputation (researcher principal))
  (match (map-get? researcher-reputation { researcher: researcher })
    reputation (>= (get reputation-score reputation) u50)
    false)) ;; New researchers start with 0, need to build reputation

;; Register a new dataset for replication
(define-public (register-dataset (title (string-ascii 200)) (data-hash (string-ascii 64)) (methodology-hash (string-ascii 64)) (description (string-ascii 500)) (institution (string-ascii 100)))
  (let ((dataset-id (var-get next-dataset-id)))

    (asserts! (> (len title) u0) ERR-NOT-AUTHORIZED)
    (asserts! (> (len data-hash) u0) ERR-NOT-AUTHORIZED)
    (asserts! (> (len methodology-hash) u0) ERR-NOT-AUTHORIZED)

    (map-set datasets
      { dataset-id: dataset-id }
      {
        title: title,
        data-hash: data-hash,
        methodology-hash: methodology-hash,
        description: description,
        original-researcher: tx-sender,
        institution: institution,
        registration-time: block-height,
        replication-attempts: u0,
        successful-replications: u0,
        integrity-score: u100,
        status: "open"
      }
    )

    ;; Initialize replication list
    (map-set dataset-replications
      { dataset-id: dataset-id }
      { replication-ids: (list) }
    )

    ;; Update institution datasets
    (let ((current-institution (default-to { dataset-ids: (list), total-count: u0 }
                                          (map-get? institution-datasets { institution: institution }))))
      (map-set institution-datasets
        { institution: institution }
        {
          dataset-ids: (unwrap! (as-max-len? (append (get dataset-ids current-institution) dataset-id) u100) ERR-NOT-AUTHORIZED),
          total-count: (+ (get total-count current-institution) u1)
        }
      )
    )

    ;; Update researcher reputation
    (let ((reputation (default-to { successful-replications: u0, failed-replications: u0, datasets-registered: u0, reputation-score: u100, verified-researcher: false }
                                 (map-get? researcher-reputation { researcher: tx-sender }))))
      (map-set researcher-reputation
        { researcher: tx-sender }
        (merge reputation {
          datasets-registered: (+ (get datasets-registered reputation) u1),
          reputation-score: (+ (get reputation-score reputation) u20)
        })
      )
    )

    (var-set next-dataset-id (+ dataset-id u1))
    (var-set total-datasets (+ (var-get total-datasets) u1))

    (ok dataset-id)
  )
)

;; Submit a replication attempt
(define-public (submit-replication (dataset-id uint) (replicator-institution (string-ascii 100)) (result-hash (string-ascii 64)) (methodology-followed bool) (success-status (string-ascii 20)) (confidence-level uint) (notes (string-ascii 300)))
  (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND))
        (replication-id (var-get next-replication-id))
        (current-replications (unwrap! (map-get? dataset-replications { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND)))

    (asserts! (not (is-eq tx-sender (get original-researcher dataset))) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status dataset) "open") ERR-INVALID-STATUS)
    (asserts! (and (>= confidence-level u1) (<= confidence-level u100)) ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq success-status "successful")
                  (is-eq success-status "failed")
                  (is-eq success-status "partial")) ERR-INVALID-STATUS)

    ;; Check if researcher has sufficient reputation for independent replication
    (asserts! (or (has-sufficient-reputation tx-sender)
                  (is-authorized-admin tx-sender)) ERR-INSUFFICIENT-REPUTATION)

    (map-set replications
      { replication-id: replication-id }
      {
        dataset-id: dataset-id,
        replicator: tx-sender,
        replicator-institution: replicator-institution,
        result-hash: result-hash,
        methodology-followed: methodology-followed,
        success-status: success-status,
        confidence-level: confidence-level,
        submission-time: block-height,
        verification-time: none,
        verified-by: none,
        notes: notes
      }
    )

    ;; Update dataset replications list
    (map-set dataset-replications
      { dataset-id: dataset-id }
      { replication-ids: (unwrap! (as-max-len? (append (get replication-ids current-replications) replication-id) u50) ERR-NOT-AUTHORIZED) }
    )

    ;; Update dataset statistics
    (let ((new-attempts (+ (get replication-attempts dataset) u1))
          (new-successful (if (is-eq success-status "successful")
                            (+ (get successful-replications dataset) u1)
                            (get successful-replications dataset)))
          (new-integrity-score (if (> new-attempts u0)
                                (/ (* new-successful u100) new-attempts)
                                u100)))
      (map-set datasets
        { dataset-id: dataset-id }
        (merge dataset {
          replication-attempts: new-attempts,
          successful-replications: new-successful,
          integrity-score: new-integrity-score
        })
      )
    )

    (var-set next-replication-id (+ replication-id u1))
    (var-set total-replications (+ (var-get total-replications) u1))

    (ok replication-id)
  )
)

;; Verify a replication attempt (admin or peer verification)
(define-public (verify-replication (replication-id uint) (verified bool))
  (let ((replication (unwrap! (map-get? replications { replication-id: replication-id }) ERR-REPLICATION-NOT-FOUND)))

    (asserts! (or (is-authorized-admin tx-sender)
                  (has-sufficient-reputation tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (get verification-time replication)) ERR-NOT-AUTHORIZED)

    (map-set replications
      { replication-id: replication-id }
      (merge replication {
        verification-time: (some block-height),
        verified-by: (some tx-sender)
      })
    )

    ;; Update replicator reputation
    (let ((reputation (default-to { successful-replications: u0, failed-replications: u0, datasets-registered: u0, reputation-score: u50, verified-researcher: false }
                                 (map-get? researcher-reputation { researcher: (get replicator replication) }))))
      (if (and verified (is-eq (get success-status replication) "successful"))
        (map-set researcher-reputation
          { researcher: (get replicator replication) }
          (merge reputation {
            successful-replications: (+ (get successful-replications reputation) u1),
            reputation-score: (+ (get reputation-score reputation) u15)
          })
        )
        (map-set researcher-reputation
          { researcher: (get replicator replication) }
          (merge reputation {
            failed-replications: (+ (get failed-replications reputation) u1),
            reputation-score: (if (> (get reputation-score reputation) u5)
                               (- (get reputation-score reputation) u5)
                               u0)
          })
        )
      )
    )

    (ok verified)
  )
)

;; Close dataset for replication (when sufficient replications are achieved)
(define-public (close-dataset (dataset-id uint))
  (let ((dataset (unwrap! (map-get? datasets { dataset-id: dataset-id }) ERR-DATASET-NOT-FOUND)))

    (asserts! (or (is-dataset-owner tx-sender dataset-id)
                  (is-authorized-admin tx-sender)) ERR-NOT-AUTHORIZED)
    (asserts! (>= (get replication-attempts dataset) u3) ERR-NOT-AUTHORIZED) ;; Minimum 3 attempts

    (let ((final-status (if (>= (get integrity-score dataset) u70) "verified" "disputed")))
      (map-set datasets
        { dataset-id: dataset-id }
        (merge dataset { status: final-status })
      )

      (ok final-status)
    )
  )
)

;; Read-only functions
(define-read-only (get-dataset (dataset-id uint))
  (map-get? datasets { dataset-id: dataset-id }))

(define-read-only (get-replication (replication-id uint))
  (map-get? replications { replication-id: replication-id }))

(define-read-only (get-researcher-reputation (researcher principal))
  (map-get? researcher-reputation { researcher: researcher }))

(define-read-only (get-dataset-replications (dataset-id uint))
  (map-get? dataset-replications { dataset-id: dataset-id }))

(define-read-only (get-institution-datasets (institution (string-ascii 100)))
  (map-get? institution-datasets { institution: institution }))

(define-read-only (get-system-stats)
  {
    total-datasets: (var-get total-datasets),
    total-replications: (var-get total-replications),
    next-dataset-id: (var-get next-dataset-id),
    next-replication-id: (var-get next-replication-id)
  }
)

;; Calculate dataset reliability score
(define-read-only (get-dataset-reliability (dataset-id uint))
  (match (map-get? datasets { dataset-id: dataset-id })
    dataset (let ((attempts (get replication-attempts dataset))
                  (successful (get successful-replications dataset)))
              (if (> attempts u0)
                (some {
                  integrity-score: (get integrity-score dataset),
                  replication-rate: (/ (* successful u100) attempts),
                  confidence-level: (if (>= attempts u5) u100 (* attempts u20))
                })
                none))
    none))

;; Verify researcher status (admin only)
(define-public (verify-researcher (researcher principal))
  (let ((reputation (unwrap! (map-get? researcher-reputation { researcher: researcher }) ERR-NOT-AUTHORIZED)))
    (asserts! (is-authorized-admin tx-sender) ERR-NOT-AUTHORIZED)

    (map-set researcher-reputation
      { researcher: researcher }
      (merge reputation { verified-researcher: true })
    )

    (ok true)
  )
)
