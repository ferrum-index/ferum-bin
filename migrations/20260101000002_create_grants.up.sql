-- Grants: absolute role per (user, namespace).
-- Maps to `admin::Absolute` (id, to_id, role, namespace).
-- `role` is a UUID that carries a u128 permission bitmap (bit n = permission n,
-- n in 0..=127), as read/written via Uuid::as_u128 / Uuid::from_u128.
-- A role of all-zero (nil UUID) means "no permissions" and is valid
-- (deny() can clear the last bit).

CREATE TABLE grants (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sub     UUID NOT NULL,
    role      UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
    namespace UUID NOT NULL REFERENCES namespaces (id) ON DELETE CASCADE
);

-- One grant row per user per namespace: the service's list_one(to_id, namespace)
-- and grant/deny read-modify-write logic assume this.
CREATE UNIQUE INDEX grants_to_id_namespace_key ON grants (sub, namespace);

-- Lookups/listing by namespace (e.g. admin viewset filtering).
CREATE INDEX grants_namespace_idx ON grants (namespace);
