-- Namespaces: an isolated scope in which roles are granted.
-- Maps to `admin::Namespace` (id, owner, name).
-- NOTE: Namespace has no `#[entity(table = ...)]` attribute, so the table name
-- comes from the derive macro's default. `namespaces` is assumed; if the macro
-- derives a different name, either rename here or add
-- `#[entity(table = "namespaces")]` to the struct.

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid() on PG < 13

CREATE TABLE namespaces (
    id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner UUID NOT NULL,
    name  TEXT NOT NULL CHECK (length(btrim(name)) > 0)
);

-- Namespace names are unique per owner.
CREATE UNIQUE INDEX namespaces_owner_name_key ON namespaces (owner, name);
