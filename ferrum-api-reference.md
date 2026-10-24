# Ferrum API Reference

2026-10-20

The `ferum` binary serves the auth, permissions, notifications, files and blogs modules from one Actix Web server at `http://127.0.0.1:8080/api`. This reference covers every route in the archive, and the `blogs` service has its own section.

## Conventions

Every route sits under the `/api` scope. `ferrumec::launch` binds `127.0.0.1:8080`; if the `FRONTEND` env var is set, a static site is served from `/` after the API routes. Bodies are JSON unless a route says otherwise.

Each module is mounted at the namespace chosen in `ferum/src/main.rs`:

| Namespace | Base path | Module | Session middleware |
| --- | --- | --- | --- |
| `auth` | `/api/auth` | `authnz` | Only on `/me/*` |
| `permissions` | `/api/permissions` | `authz` | Whole module |
| `notifications` | `/api/notifications` | `notification` | Whole module |
| `files` | `/api/files` | `s3-upload` | Whole module |
| `blogs` | `/api/blogs` | `blogs` | Post writes and /me/posts only |
| `health` | `/api/health` | `ferrumec` infra check | None |

Paths in the rest of this document are relative to `/api`. The auth module nests its own `/auth` scope, so registration is `POST /api/auth/auth/register`.

Two cookies carry identity. Both are `HttpOnly`, `Secure` and `path=/`:

- `session`: set by every login method (`SameSite=Strict`). A session lasts 1 hour from login.
- `permission`: set by `POST /permissions/claim/{namespace}`; holds a role bitset for one namespace (30 min cache).

IDs are UUIDs and timestamps are RFC 3339 UTC strings.

## How requests are authorized

Two independent checks can apply to a route: the session check (who you are) and the permission check (what you may do).

1. Log in with any method in [Auth](#auth). The response sets the `session` cookie.
2. For routes gated by `permissions.json`, call `POST /permissions/claim/{namespace}` with that session. The response sets the `permission` cookie.
3. Send both cookies on later requests.

**Session check.** `SessionMiddleware` reads the `session` cookie, looks the UUID up in the session cache and rejects missing, malformed, unknown or expired sessions with `401` and a plain-text body (`no session` or `session expired`). It then exposes the caller as an identity with `sub` (user id), `username` and `email`.

**Permission check.** The server loads `permissions.json` from its working directory at startup and panics if the file is missing or invalid. Each entry binds an HTTP method and an Actix route pattern to a bit index (0–127). For a matching entry:

| Condition | Status | Body |
| --- | --- | --- |
| No `permission` cookie | 401 | empty |
| Cookie is not a UUID | 500 | empty |
| Cookie id not in the permission cache (never issued, or older than 30 min) | 403 | empty |
| Role bitset lacks the entry's bit | 403 | empty |

A route with no matching entry is not checked at all: the middleware code comment says "default allow", although the module docs say "default deny". List every sensitive route in `permissions.json`.

## Errors

There is no single error format. Which one you see depends on the module.

| Shape | Used by | Example |
| --- | --- | --- |
| `{"error": "..."}` | Generic CRUD, files, blogs, passkeys | `{"error":"resource not found"}` |
| `{"success": false, "message": "...", "data": null}` | Register, login, password routes | `{"success":false,"message":"Invalid credentials","data":null}` |
| Plain text or empty body | Session and permission middleware, passwordless, permissions, notifications, malformed JSON | `no session` |

Successful `ApiResponse` bodies look like `{"success":true,"message":"...","data":...}`.

5xx responses from generic CRUD always return `{"error":"internal server error"}`; details are logged server-side only.

Generic CRUD status codes:

| Status | Meaning |
| --- | --- |
| 401 | Unauthorized |
| 403 | Permission denied |
| 404 | Resource not found (also a missing database row) |
| 409 | Conflict, or optimistic-lock mismatch |
| 422 | Validation failed, including an unparseable `{id}` |
| 500 | Database or internal error |

## Generic resource endpoints

Several resources are exposed through the `viewset` crate's CRUD layer: users, sessions, grants and notification tags. Each one mounts the same six routes at `{base}` and `{base}/{id}`:

| Method | Path | Success | Notes |
| --- | --- | --- | --- |
| GET | `{base}` | 200 page object | Paginated list |
| POST | `{base}` | 201 resource | Body is the resource's create DTO |
| GET | `{base}/{id}` | 200 resource | |
| PUT, PATCH | `{base}/{id}` | 200 resource | Both run the same handler and take the update DTO |
| DELETE | `{base}/{id}` | 204 | |

List query parameters:

| Parameter | Default | Behavior |
| --- | --- | --- |
| `page` | 1 | 1-based page number |
| `page_size` | 25 | Clamped to 1–200 |
| `sort` | none | Comma-separated columns; prefix `-` for descending; non-sortable columns are ignored |
| `search` | none | Case-insensitive substring match (`ILIKE`) across the resource's searchable columns |
| `<column>=<value>` | none | Equality filter (compared as text) on filterable columns only; other keys are silently ignored |

List response:

```json
{ "items": [], "page": 1, "page_size": 25, "total": 0, "total_pages": 1 }
```

Resources and their columns:

| Resource | Base path | Sortable | Searchable | Filterable | Create / update |
| --- | --- | --- | --- | --- | --- |
| User | `/auth/me/admin/users` | `username`, `email`, `created_at` | `username` | `username`, `email` | Create refused (422, use registration). Update: `username`, `email_confirmed` |
| Session | `/auth/me/admin/sessions` | `created_at` | none | `sub` | Create refused (422, use login). No update DTO: PUT/PATCH always fail |
| Grant | `/permissions/admin/grants` | none | none | `to_id`, `namespace` | Create: `to_id`, `role`, `namespace`. Update: `role` |
| Tag | `/notifications/tags` | none | none | none | Create: `tag`, `user_id`. No update DTO |

Fields per resource:

- **User:** `id`, `username`, `email`, `created_at`, `updated_at`, `email_confirmed`, `password_hash`.
- **Session:** `id`, `created_at`, `sub`, `username`, `email`, `expires_at`, `ip_address`.
- **Grant:** `id`, `to_id`, `role` (a UUID encoding the 128-bit permission bitset), `namespace`.
- **Tag:** `id`, `tag`, `user_id`.

These routes are behind the session check only. Gate them in `permissions.json`, or any logged-in user can read and edit every user, session and grant.

The blogs categories use the same pattern with their own rules; see [Blogs](#blogs).

## Auth

Public routes under `/auth/auth`. They are wrapped in a response equalizer that holds every response for at least 200 ms, to blunt timing attacks. Errors use the `ApiResponse` shape unless noted.

### POST /auth/auth/register

Creates an account.

```json
{ "username": "ada", "email": "ada@example.com", "password": "correct horse battery" }
```

- `username`: 3–30 characters. `email`: valid address. `password`: at least 8 characters and a zxcvbn score of 3 or higher.
- **201** `{"success":true,"message":"User registered successfully","data":null}`. The `auth.user.created` event is not emitted by this route in the code shown; see [Events](#events).
- **400** with a plain-text `Invalid request: ...` body when field validation fails.
- **400** `Password must be at least 6 characters` when the password is too weak. The text is misleading: the real rule is the zxcvbn score.
- **409** `Username already exists`, returned for a duplicate username or email.

### POST /auth/auth/login/email

### POST /auth/auth/login/username

Password login. `identifier` is an email for `/login/email` and a username for `/login/username`.

```json
{ "identifier": "ada@example.com", "password": "correct horse battery" }
```

- **200** with an empty body and a `Set-Cookie: session=<uuid>`.
- **400** `Username and password are required`.
- **401** `Invalid credentials` for an unknown account or a wrong password.

### POST /auth/auth/request_password_reset

```json
{ "email": "ada@example.com" }
```

Always **200** `If the account exists, a reset link has been sent`, whether or not the email exists. When it does, a single-use token valid for 30 minutes is published in the `auth.password_reset.requested` event; delivery is up to a subscriber.

### POST /auth/auth/confirm_password_reset

```json
{ "token": "<token from the email>", "new_password": "a new strong password" }
```

- **200** with an empty body. Every session and refresh token for the user is revoked.
- **400** weak password. **401** `Invalid or expired token`.

### GET /auth/user_id/username/{username}

Public. Returns the user's UUID as plain text (**200**), or **404** with an empty body. It lets anyone map a username to an id.

## Account (/auth/me)

Every route here requires the `session` cookie.

| Method | Path | Success | Description |
| --- | --- | --- | --- |
| GET | `/auth/me/account` | 200 | `{"success":true,"message":"Protected data retrieved successfully","data":{"user_id":"<uuid>","message":"Access granted to protected route"}}` |
| POST | `/auth/me/logout` | 200 | Deletes the session and clears the cookie. Idempotent. Body: `{"success":true,"message":"Logged out successfully","data":null}` |
| POST | `/auth/me/change_password` | 200 | Body `{"current_password","new_password"}`. Revokes all sessions and refresh tokens, then sets a fresh `session` cookie for the caller |
| GET | `/auth/me/sessions` | 200 | Flat JSON array of the caller's sessions (fields as in Generic resource endpoints); returns at most the first 25 |
| DELETE | `/auth/me/delete_session/{id}` | 200 | Deletes one of the caller's sessions. 404 if it does not exist, 403 if it belongs to someone else |
| POST | `/auth/me/jwt` | 200 | Issues a JWT pair for the current session (next section) |

`change_password` errors: 400 weak password, 401 `Invalid credentials` when `current_password` is wrong.

## JWT tokens

For API and service clients that prefer bearer tokens. A token pair looks like:

```json
{
  "success": true,
  "message": "JWT issued successfully",
  "data": { "access_token": "<jwt>", "refresh_token": "<43-char token>", "expires_in": 600 }
}
```

The access token is an HS256 JWT valid for 10 minutes. The refresh token lives 30 days and is stored only as a SHA-256 hash.

| Method | Path | Auth | Body | Result |
| --- | --- | --- | --- | --- |
| POST | `/auth/me/jwt` | session | none | Token pair (above) |
| POST | `/auth/jwt/refresh` | none | `{"refresh_token"}` | New pair; the old refresh token is deleted (rotation). Message `Refresh successful` |
| POST | `/auth/jwt/logout` | none | `{"refresh_token"}` | 200 `Logged out successfully`; unknown tokens also succeed |

Both public routes return an empty **500** for every failure, including an empty, unknown, revoked or expired refresh token.

## Passwordless

Login by email or username with a one-time challenge. These routes are rate-limited to 2 requests per 60 seconds per client IP; set `PROXIES` (comma-separated CIDRs) to trust `X-Forwarded-For` from your proxies. A challenge lives 120 seconds and is single use.

| Method | Path | Body | Success | Errors |
| --- | --- | --- | --- | --- |
| POST | `/auth/passwordless/challenge/email` | `{"email"}` | 201 empty | 404 `User not found` |
| GET | `/auth/passwordless/challenge/username/{username}` | none | 201 empty | 404 `User not found` |
| GET | `/auth/passwordless/confirm_link/{link}` | none | 200 + `session` cookie | 400 `Invalid or expired token` |
| POST | `/auth/passwordless/confirm_token` | `{"token": 123456, "nonce": "<string>"}` | 200 + `session` cookie | 400 `Invalid or expired token` |

The challenge itself is not returned. It is published as an `auth.2fa.challenge.requested` event carrying a 6-digit `token`, a `link` and a `nonce`, and a subscriber (not in this archive) must deliver them. Successful confirmation also marks the account's email as confirmed. The status for an exceeded rate limit comes from the `actixutils` crate and is not in the archive.

## Passkeys

WebAuthn passkeys are an optional feature. They exist only when `authnz` is compiled with its `passkey` feature, and the `ferum` binary does not enable it, so these routes are absent from the stock server. They need `WEBAUTHN_RP_ID` and `WEBAUTHN_RP_ORIGIN` (optionally `WEBAUTHN_RP_NAME`). Ceremony state expires after 5 minutes. Errors use `{"error": "..."}`.

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| POST | `/auth/passkey/register/start` | account | Returns WebAuthn creation options (200). 400 on WebAuthn errors |
| POST | `/auth/passkey/register/finish?label=` | account | Body is the browser's registration credential. 200 `{"status":"success","message":"Passkey registered"}`; 400 if no ceremony is in progress or it expired |
| GET | `/auth/passkey/register` | account | Array of `{id, label, created_at, last_used_at}` |
| DELETE | `/auth/passkey/register/{id}` | account | 200 `{"status":"success"}`; 404 `Passkey not found` |
| POST | `/auth/passkey/login/start` | public | Body `{"username"}`. Returns request options (200); 400 `No passkeys registered for this account` |
| POST | `/auth/passkey/login/finish?username=` | public | Body is the browser's assertion. 200 with a `session` cookie and empty body; 400 otherwise |

As written, the account routes read a `Session<User>` and a `CredsRepo` that the module never registers; see [Gaps and things to verify](#gaps-and-things-to-verify).

## Permissions

The `permissions` module turns a user's grants into the `permission` cookie and lets namespace owners change other users' grants. All routes require the `session` cookie. A grant is a 128-bit role bitset stored per user and namespace; the API shows it as a UUID (`Uuid::from_u128(role)`), so bit 3 is `00000000-0000-0000-0000-000000000008`.

### POST /permissions/claim/{namespace}

`{namespace}` is a UUID. Looks up the caller's role in that namespace (0 if there is no grant) and caches it for 30 minutes.

- **200** with an empty body and `Set-Cookie: permission=<uuid>`.
- **500** on any failure. Any logged-in user may claim any namespace; a user without a grant simply gets role 0.
- Role changes are not seen until the user claims again.

### POST /permissions/grant

### POST /permissions/deny

```json
{ "permission": 3, "target": "<user uuid>" }
```

Sets or clears bit `permission` (0–127) in `target`'s role for the namespace stored in the caller's `permission` cookie. The caller must own that namespace and must hold the same bit. These routes read the cookie's authority, so they must be listed in `permissions.json`, otherwise the handler fails with a 500.

- **200** `{"success":true,"new_role":"<uuid>"}`.
- **403** empty body when the caller does not own the namespace or lacks the bit.
- **400** `{"success":false,"error":"invalid operation"}` (grant) or **406** plain text (deny) when `permission` is above 127.
- **500** for lookup failures, including a deny for a target with no grant row, and a namespace that does not exist.

Namespaces are rows in a namespace table (`id`, `owner`, `name`); no route in this archive creates them.

### Grants admin

CRUD over the `grants` table at `/permissions/admin/grants`, with the behavior in Generic resource endpoints. Gate it in `permissions.json`.

## Files

Upload and download to S3-compatible storage. All routes require the `session` cookie, and files are private to their owner: someone else's file returns 404, the same as a missing one. Add the routes to `permissions.json` if you want them permission-gated.

File object returned by the metadata, list and upload routes:

```json
{ "id": "<uuid>", "filename": "report.pdf", "content_type": "application/pdf", "size_bytes": 48213, "created_at": "2026-10-20T07:10:00Z" }
```

| Method | Path | Success | Description |
| --- | --- | --- | --- |
| PUT | `/files/v1/files?filename=` | 201 file object | Upload. The raw request body is the file |
| GET | `/files/v1/files` | 200 page object | The caller's files |
| GET | `/files/v1/files/{id}` | 200 file object | Metadata |
| GET | `/files/v1/files/{id}/download` | 200 stream | File bytes |
| DELETE | `/files/v1/files/{id}` | 204 | Deletes the object, then the record |

### Upload

- Send the bytes as the body with `Content-Type` set to the file's type (default `application/octet-stream`). `filename` is a display name only; any path is stripped, control characters are removed, it is cut to 180 characters, and it defaults to `upload.bin`.
- The size is limited by `MAX_UPLOAD_BYTES` (default 100 MiB), checked up front from `Content-Length` and again while streaming.
- Objects are stored under a random key; the owner and key are never returned.

### List

Query: `page`, `page_size` (1–200, default 25), `sort` (`created_at`, `filename`, `size_bytes`; prefix `-` for descending) and `content_type` (exact match). `search` and other filters are ignored. The response is the standard page object.

### Download

Sends `Content-Type` as stored, `Content-Disposition: attachment; filename*=UTF-8''<encoded>` and `X-Content-Type-Options: nosniff`.

### Errors

Bodies are `{"error": "..."}`.

| Status | Message | Cause |
| --- | --- | --- |
| 400 | `invalid Content-Length` / `failed to read upload body` | Bad header or broken client stream |
| 404 | `resource not found` / `file not found` | No such file, someone else's file, or the stored object is missing |
| 408 | `timed out waiting for upload data` / `upload took too long` | Idle gap over 30 s or total time over 600 s |
| 413 | `upload exceeds configured size limit` / `upload would exceed your storage quota` | Size limit, or per-user storage quota (default 5 GiB) |
| 429 | `too many concurrent uploads` / `upload quota exceeded` / `download quota exceeded` | Per-user limits; `Retry-After` is set |
| 502 | `storage upload failed` / `storage download failed` / `storage delete failed` | The S3 backend failed |
| 503 | `server is at capacity, try again shortly` | Global concurrency cap reached; `Retry-After: 5` |

Per-user limits are in memory: 2 simultaneous uploads, 1 GiB uploaded and 5 GiB downloaded per hour. They reset on restart and are not shared between instances. Every default can be changed; see [Configuration](#configuration).

## Notifications

The module delivers events to users over three channels: `email`, `push` (WebSocket) and `console` (server log). A user receives an event on a channel only if they have confirmed an address for that event's subject. All routes require the `session` cookie.

### How delivery works

1. Each channel subscribes to the subjects listed in `EMAIL_SUBJECTS`, `PUSH_SUBJECTS` and `CONSOLE_SUBJECTS`.
2. For each entry in an event's `audience` (a user UUID, or a tag resolved through the `tags` resource), the module looks up that user's address for the subject.
3. If one exists, the channel sends the full event JSON to it. Users without a preference are skipped.

### Preferences

The same three routes exist for each channel; replace `{channel}` with `email`, `push` or `console`. Saving an address is a two-step flow so an address cannot be claimed without proving access to it.

| Method | Path | Body or query | Success |
| --- | --- | --- | --- |
| POST | `/notifications/{channel}/preferences/set` | `{"preferences":[{"subject","address"}]}` | 200 `{"nonce":"<16 chars>"}` |
| POST | `/notifications/{channel}/preferences/confirm` | `{"nonce","token": 123456}` | 200 empty |
| GET | `/notifications/{channel}/preferences/get?subject=` | query | 200 JSON string (the address) |

**Set.** Every entry must use the same `address`; `subject` and `address` are 1–64 characters, and each `subject` must be in the channel's allowed list. A 6-digit code is sent to the address through the channel itself (message subject `confirm address`). The pending request is kept for 30 minutes. Errors are plain text: **400** `preferences must not be empty`, **403** for validation failures, mixed addresses or a disallowed subject.

**Confirm.** `token` is the 6-digit code (100000–999999). On success every pending row is saved, replacing an existing address for the same user and subject, and `contact.channel.confirmed` is published. A wrong code, an expired nonce or any other failure returns **500** with a plain-text message.

**Get.** **404** with an empty body when the user has no address for that subject.

### Tags

CRUD at `/notifications/tags` (see Generic resource endpoints). A tag maps a label to one user id, so that events addressed to the tag reach that user. `tag` and `user_id` are required on create.

### WebSocket push

`GET /notifications/ws/ws/` upgrades to a WebSocket; the session cookie identifies the user. The server pings every 5 seconds and closes the connection if no pong or ping arrives within 10 seconds. A user has one live connection; a new one replaces the old.

Server to client, for a delivered event:

```json
{ "id": "<uuid>", "source": "push", "payload": "<the event as a JSON string>" }
```

Client to server, a direct message to another connected user:

```json
{ "type": "private", "to": "<user uuid>", "content": "hello" }
```

The recipient gets `{"from": "<sender uuid>", "content": "hello"}`. Messages to users who are not connected are dropped. There is no check on who may message whom.

## Blogs

Posts, categories and comments, mounted at `/blogs`. Reads are public. Writes are authenticated in three different ways, so check each resource before you gate a route:

- **Posts:** every write route (`POST /blogs/posts`, `PUT`/`PATCH`/`DELETE /blogs/posts/{id}`, publish and unpublish) and the `/blogs/me/posts` routes need the `session` cookie. They do not need a `permissions.json` entry or a namespace claim. A missing, malformed or expired session returns **401** with a plain-text body (`no session` or `session expired`). Only the post's author may change it; admins no longer have an override on posts.
- **Comments:** create and delete read the caller from the `permission` cookie. List them in `permissions.json` and claim a namespace first, otherwise the handler returns **403** `{"error":"permission denied"}`. Deleting needs the comment's author, or admin (role bit 20).
- **Categories:** no caller check and no ownership rule. Writes are open unless you gate them in `permissions.json`.

The author of a post or comment always comes from the caller; any `author_id` in a request body is ignored.

### Resources

| Resource | Fields |
| --- | --- |
| Category | `id`, `name`, `slug`, `description` (nullable), `created_at` |
| Post | `id`, `author_id`, `category_id` (nullable), `title`, `slug`, `excerpt` (nullable), `body`, `status` (`draft` or `published`), `published_at` (nullable), `created_at`, `updated_at` |
| Comment | `id`, `post_id`, `author_id`, `parent_id` (nullable), `body`, `created_at` |

Posts and comments are soft-deleted and never returned afterwards. Lists use the standard page object and the `page`, `page_size` and `sort` parameters from Generic resource endpoints.

### Routes

| Method | Path | Who | Success | Description |
| --- | --- | --- | --- | --- |
| GET | `/blogs/categories` | public | 200 page | Query: `search` (name, description), `sort` (`name`, `created_at`), `slug` |
| POST | `/blogs/categories` | gated | 201 category | Body `{name, slug?, description?}` |
| GET | `/blogs/categories/{id}` | public | 200 category | |
| PUT, PATCH | `/blogs/categories/{id}` | gated | 200 category | Body with any of `name`, `slug`, `description` |
| DELETE | `/blogs/categories/{id}` | gated | 204 | |
| GET | `/blogs/posts/categories/{category_id}/posts` | public | 200 page | Published posts in the category, newest first; `sort` and paging only. The path changed: it was `/blogs/categories/{category_id}/posts` |
| GET | `/blogs/posts` | public | 200 page | Published posts, newest first. Query: `search` (title, excerpt, body), `sort` (`created_at`, `published_at`, `updated_at`, `title`), `slug`; `status` is forced to `published` |
| POST | `/blogs/posts` | session | 201 post | Create |
| GET | `/blogs/posts/by-slug/{slug}` | public | 200 post | Published posts only |
| GET | `/blogs/posts/{id}` | public | 200 post | 404 unless published |
| PUT, PATCH | `/blogs/posts/{id}` | session, author | 200 post | Partial update |
| DELETE | `/blogs/posts/{id}` | session, author | 204 | |
| POST | `/blogs/posts/{id}/publish` | session, author | 200 post | No body |
| POST | `/blogs/posts/{id}/unpublish` | session, author | 200 post | Back to `draft` |
| GET | `/blogs/me/posts` | session | 200 page | The caller's posts, drafts included, newest first; `sort` and paging only |
| GET | `/blogs/me/posts/{id}` | session | 200 post | 404 if it is not the caller's |
| GET | `/blogs/posts/{post_id}/comments` | public | 200 page | Oldest first; `sort` supports `created_at` |
| POST | `/blogs/posts/{post_id}/comments` | permission | 201 comment | Body `{body, parent_id?}` |
| GET | `/blogs/comments/{id}` | public | 200 comment | |
| DELETE | `/blogs/comments/{id}` | permission, author or admin | 204 | |

There is no route to edit a comment. In the Who column, "gated" means the route has no caller check, so protect it with `permissions.json`; "session" means the `session` cookie; "permission" means the `permission` cookie from a namespace claim.

### Posts

```json
{ "title": "Hello", "body": "...", "category_id": "<uuid>", "slug": "hello", "excerpt": "...", "status": "draft" }
```

- `title` is required (1–200 characters) and `body` is required (1–200,000). `slug`, `category_id`, `excerpt` and `status` are optional.
- `slug` is derived from the title when omitted, with a random 8-character suffix if it is taken (`post` if the title yields no letters). A slug you supply must be lowercase letters, digits and hyphens, at most 120 characters, not start or end with a hyphen, and be unused (**409** otherwise).
- `status` is `draft` (default) or `published`. A post created as `published` sets `published_at` and emits `blogs.post.published`.
- `category_id` must exist (**422** `unknown category_id`). Update cannot clear it.
- Update cannot change `status`; use publish and unpublish. Publishing an already published post, or unpublishing a draft, returns the post unchanged with no event.
- `published_at` is set the first time a post is published and kept after unpublishing.

### Comments

- `body` is required, 1–5,000 characters. `post_id` comes from the URL.
- The post must be published and not deleted, otherwise **404**.
- `parent_id`, if given, must be a comment on the same post (**422**).

### Errors

Bodies are `{"error": "..."}`: **403** `permission denied` (not the post's author, not the comment's author or an admin, or no `permission` cookie on a comment write), **404** `resource not found` (also a malformed `{id}` on `DELETE /blogs/posts/{id}`, which the framework rejects before the handler), **409** `conflict: slug ... is already in use`, **422** `validation failed: ...` (including `invalid id: ...` for a malformed UUID on the other routes). Session failures on post writes and `/me/posts` are not JSON: **401** with the plain text `no session` or `session expired`. Blogs no longer returns 401 `unauthorized`.

### Events

Published through the transactional outbox with producer `blogs`, so an event exists only if its database change committed.

| Subject | Payload | When |
| --- | --- | --- |
| `blogs.post.published` | `{post_id, author_id, title, slug, published_at}` | A post is created as published, or published |
| `blogs.post.unpublished` | `{post_id, author_id}` | A published post is unpublished |
| `blogs.post.deleted` | `{post_id}` | A post is deleted |
| `blogs.comment.created` | `{comment_id, post_id, post_author_id, author_id, parent_id}` | A comment is created; the post author is in the event audience |

## Health

`GET /health` is public unless you add it to `permissions.json`. It returns **200** when Postgres, the cache and the event bus all answer within 2 seconds, otherwise **503**, with the same body shape:

```json
{ "db_latency_ms": 3, "cache_latency_ms": 0, "bus_latency_ms": 0 }
```

A value is `null` when that backend failed or timed out. Backends the current infra does not use report `0`.

## Events

Modules talk to each other, and to services outside this archive, through the event stream (in-process by default, NATS on a distributed infra). Every event is an envelope with `metadata` (`event_id`, `event_version` `v1`, `occurred_at`, `producer`, `user_id`, `audience`, plus optional correlation, trace and session ids) and the payload below.

| Subject | Published by | Payload | When |
| --- | --- | --- | --- |
| `auth.password_reset.requested` | auth | `{email, token}` | A reset is requested for an existing account. The raw token appears only here |
| `auth.2fa.challenge.requested` | auth | `{token, link, nonce}` | A passwordless challenge is created |
| `files.uploaded` | files | `{id, owner_id, filename, content_type, size_bytes}` | After a successful upload; producer `files` |
| `files.deleted` | files | `{id, owner_id}` | After a successful delete |
| `contact.channel.confirmed` | notifications | `{user, channel, address}` | A notification address is confirmed; producer `mgk` |

Auth events go through a transactional outbox, so they are published only if the database write commits. File and notification events are best effort: a failed publish is logged and never fails the request.

Blogs events are listed in the [Blogs](#blogs) section.

## Configuration

The server reads a `.env` file at startup (`dotenvy`). Variables the API behavior depends on:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | all | Postgres connection (defaults to a local `postgres` database) |
| `FRONTEND` | launch | Directory of static files served at `/` |
| `signer.secret`, `signer.aud` | auth | HS256 secret and audience for access tokens. The names contain a dot |
| `AUD` | auth | Comma-separated audiences placed in access tokens; required |
| `PROXIES` | passwordless | Comma-separated CIDRs of trusted reverse proxies |
| `WEBAUTHN_RP_ID`, `WEBAUTHN_RP_ORIGIN`, `WEBAUTHN_RP_NAME` | passkeys | Relying-party settings (feature `passkey` only) |
| `OTEL_LOGS_ENDPOINT`, `OTEL_METRICS_ENDPOINT`, `OTEL_TRACES_ENDPOINT` | launch | OTLP/HTTP collectors |
| `S3_BUCKET` (required), `S3_ENDPOINT`, `S3_CREATE_BUCKET`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_CONNECT_TIMEOUT_SECS`, `S3_OP_TIMEOUT_SECS` | files | Storage backend |
| `MAX_UPLOAD_BYTES` (100 MiB), `PART_SIZE_BYTES` (8 MiB, min 5 MiB), `MAX_CONCURRENT_UPLOADS` (8), `MAX_CONCURRENT_DOWNLOADS` (32), `MAX_UPLOADS_PER_USER` (2) | files | Size and concurrency limits |
| `UPLOAD_IDLE_TIMEOUT_SECS` (30), `UPLOAD_TOTAL_TIMEOUT_SECS` (600), `DOWNLOAD_IDLE_TIMEOUT_SECS` (30) | files | Timeouts |
| `USER_STORAGE_QUOTA_BYTES` (5 GiB), `USER_UPLOAD_QUOTA_BYTES` (1 GiB), `USER_DOWNLOAD_QUOTA_BYTES` (5 GiB), `QUOTA_WINDOW_SECS` (3600) | files | Per-user quotas |
| `EMAIL_PROVIDER` (`brevo` or `resend`), the provider's `*_API_KEY` and `*_API_URL`, `EMAIL_FROM_ADDRESS`, `EMAIL_FROM_NAME` | notifications | Email delivery |
| `EMAIL_SUBJECTS`, `PUSH_SUBJECTS`, `CONSOLE_SUBJECTS` | notifications | Required comma-separated lists of event subjects each channel handles and accepts as preference subjects |
| `CACHE_TTL_SECS`, `OTP_TTL_SECS`, `SESSION_COOKIE` | notifications | Optional tunables; see the gaps below |

## Gaps and things to verify

This document describes what the code in the archive does. These are places where that differs from what you may expect, or where a dependency outside the archive decides the answer.

**Not in the archive.** The `viewset-macros` derive, the `actixutils` crate (rate limiter, response equalizer, JWT validation), `permissions.json` and the SQL migrations, including `migrations/001_blogs.sql`, which the blogs module runs at startup. Anything that depends on them is marked above or listed here.

| Finding | Why it matters |
| --- | --- |
| Routes missing from `permissions.json` are not checked (the code says "default allow"; the module docs say "default deny") | `/auth/me/admin/*`, `/permissions/admin/grants`, `/notifications/tags` and the files routes are otherwise open to every logged-in user |
| `User` has no separate response type and includes `password_hash` | If the derive uses the entity as the response, the admin users routes return password hashes. Check the derive output |
| `UpdateUser` serializes unset fields as `null` | Whether `PATCH {"email_confirmed": true}` leaves `username` alone depends on the derive; the `Entity` docs expect `skip_serializing_if` |
| `POST /auth/auth/register` never publishes `auth.user.created` | The event type exists but nothing sends it |
| Weak-password error says "at least 6 characters" | The real rule is length 8 or more and a zxcvbn score of 3 or higher |
| `/auth/jwt/refresh` and `/auth/jwt/logout` return 500 for client errors | Clients cannot tell an expired token from a server fault |
| Passkey account routes use `Session<User>` and `CredsRepo`, neither registered | They would return 500 if the feature were enabled. `login/finish` sets a session cookie although its doc comment promises a token pair |
| Passwordless challenge state is held in process memory | Challenges and the rate limiter do not work across several server instances |
| Account enumeration | `GET /auth/user_id/username/{username}` and the passwordless challenge routes (404) reveal whether a user exists |
| Notification confirm has no attempt limit | A wrong code does not consume the pending entry, so a 6-digit code can be guessed for up to 30 minutes |
| `OTP_TTL_SECS` and `CACHE_TTL_SECS` are parsed but not applied | Pending confirmations always last 30 minutes |
| Anyone logged in can create a tag for any `user_id`, and can WebSocket-message any user id | Both are unrestricted unless gated |
| Generic list with `page=0` | `(page - 1)` underflows in `PaginationParams`: a panic in debug builds, a huge offset in release. The files list clamps `page` to at least 1 |
| Sessions last 1 hour from login | The auth module docs mention sliding expiry; the code does not extend `expires_at` |
| `GET /auth/me/sessions` returns at most 25 sessions | It uses the default page size and no paging parameters |
| Bind address and service name are fixed | `launch` always binds `127.0.0.1:8080` and reports telemetry as `mains` |

Blogs-specific findings:

- Post writes and `/me/posts` check only the `session` cookie, and the author rule is their only access control; `permissions.json` has no effect on them. Comment create and delete still use the `permission` cookie. Clients must handle both mechanisms.
- Admins (role bit 20) can no longer update, delete, publish or unpublish other people's posts. The bit still lets them delete any comment, so there is no moderation path for posts.
- The category posts route is now `GET /blogs/posts/categories/{category_id}/posts` (the `/posts` prefix is applied twice). `GET /blogs/categories/{category_id}/posts` no longer exists. Confirm this is intended.
- The session check reads the shared `sessions_items` cache. If blogs runs against a different cache than the auth module, every post write returns 401.
- A comment write with no `permission` cookie now returns 403 `permission denied`; it used to return 401.
- A malformed UUID returns 404 on `DELETE /blogs/posts/{id}` but 422 `invalid id` on the other routes.
- Category writes have no ownership rule, so any caller allowed through `permissions.json` can edit or delete any category.
- The comment type has an update DTO, but no route edits comments.
- Post update cannot clear `category_id` or `excerpt`, and a category update cannot clear `description`, because unset and null both keep the old value.
- List endpoints do not filter by status or category beyond what the table shows, and `page=0` underflows as in the generic list.
- `blogs.post.deleted` has no author in its payload or metadata.
