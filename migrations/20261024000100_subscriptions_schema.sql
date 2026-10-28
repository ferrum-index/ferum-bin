-- Subscriptions service schema. (`outbox_events` is created by ferrumec's `Outbox::new`.)

CREATE TABLE IF NOT EXISTS plans (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT        NOT NULL CHECK (length(btrim(name)) > 0),
    description   TEXT        NOT NULL DEFAULT '',
    -- u128 permission bitmap carried in a UUID (bit n = permission n), same
    -- convention as authz's `grants.role`.
    role          UUID        NOT NULL,
    price         BIGINT      NOT NULL CHECK (price >= 0),
    duration_days INT         NOT NULL CHECK (duration_days > 0),
    active        BOOLEAN     NOT NULL DEFAULT true,
    created       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS plans_name_key ON plans (lower(name));

-- status: pending_payment -> granting -> active -> revoking -> expired | cancelled
--         pending_payment -> failed
-- Terms (role, amount, duration) are copied from the plan at subscribe time, so
-- later plan edits never change what an existing subscriber paid for.
CREATE TABLE IF NOT EXISTS subscriptions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        NOT NULL,
    plan_id         UUID        NOT NULL REFERENCES plans (id),
    status          TEXT        NOT NULL CHECK (status IN
                        ('pending_payment','granting','active','revoking','expired','cancelled','failed')),
    end_reason      TEXT        CHECK (end_reason IN ('expired','cancelled')),
    failure_reason  TEXT,
    role            UUID        NOT NULL,
    amount          BIGINT      NOT NULL CHECK (amount >= 0),
    duration_days   INT         NOT NULL CHECK (duration_days > 0),
    debit_id        UUID        NOT NULL UNIQUE,
    starts_at       TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    -- worker bookkeeping
    attempts        INT         NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error      TEXT,
    created         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- At most one live subscription per user per plan.
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_live_key
    ON subscriptions (user_id, plan_id)
    WHERE status IN ('pending_payment','granting','active','revoking');

CREATE INDEX IF NOT EXISTS subscriptions_user_idx ON subscriptions (user_id, created DESC);
-- Worker scan.
CREATE INDEX IF NOT EXISTS subscriptions_work_idx
    ON subscriptions (status, next_attempt_at, expires_at)
    WHERE status IN ('pending_payment','granting','active','revoking');
