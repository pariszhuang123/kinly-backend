---
Domain: Identity
Capability: Personal Directory API
Scope: backend
Artifact-Type: contract
Stability: evolving
Status: draft
Version: v2.0
---

# Personal Directory API v2

Status: Proposed

Scope: Versioned note-write RPCs for Personal Directory. v2 preserves the v1
read model and note semantics, and adds `reference_url` as an explicit write
parameter for note create/update flows.

Audience: Product, design, engineering, AI agents.

Depends on:
- Personal Directory Contract v1
- Personal Directory API v1
- Homes v2

## 1. Compatibility

- `get_member_directory_notes` remains the canonical notes read RPC.
- The notes read payload includes `reference_url` when present.
- `create_member_directory_note` and `update_member_directory_note` remain the
  v1 compatibility path and do not accept `reference_url`.
- Clients that need to write `reference_url` MUST call the v2 note-write RPCs.
- This is a versioned additive change; existing v1 callers continue to work.

## 2. RPC contracts

### 2.1 `create_member_directory_note_v2(p_note_type text, p_label text|null default null, p_custom_title text|null default null, p_contact_name text|null default null, p_phone_number text|null default null, p_details text|null default null, p_reference_url text|null default null, p_photo_path text|null default null) -> jsonb`

Caller: authenticated user.

Behavior:
- creates a new active note owned by the caller
- preserves all v1 note-type validation rules
- if `p_reference_url` is present, it must be a valid `http` or `https` URL
  with max length `2048`
- response returns `reference_url` inside `note`

### 2.2 `update_member_directory_note_v2(p_note_id uuid, p_label text|null default null, p_custom_title text|null default null, p_contact_name text|null default null, p_phone_number text|null default null, p_details text|null default null, p_reference_url text|null default null, p_photo_path text|null default null) -> jsonb`

Caller: authenticated user.

Behavior:
- updates an existing active note owned by the caller
- preserves all v1 note-type validation rules
- the note type remains immutable
- if `p_reference_url` is present, it must be a valid `http` or `https` URL
  with max length `2048`
- response returns `reference_url` inside `note`

## 3. Canonical note payload

The read and write note payloads include:

```json
{
  "id": "uuid",
  "note_type": "text",
  "label": "text|null",
  "custom_title": "text|null",
  "contact_name": "text|null",
  "phone_number": "text|null",
  "details": "text|null",
  "reference_url": "text|null",
  "photo_path": "text|null",
  "created_at": "timestamptz",
  "updated_at": "timestamptz"
}
```

## 4. Required errors

- `MEMBER_DIRECTORY_INVALID_REFERENCE_URL`
- all Personal Directory API v1 note validation errors remain required

## 5. Frontend integration

- To receive `reference_url`, the frontend continues reading from
  `get_member_directory_notes`.
- To create a note with `reference_url`, call
  `create_member_directory_note_v2`.
- To update a note with `reference_url`, call
  `update_member_directory_note_v2`.
- Frontend contracts or generated client mappings should bind note write
  actions to the v2 RPC names and continue using the existing notes read RPC.

## 6. References

- [Personal Directory Contract v1](/home/paris/dev/kinly-backend/docs/contracts/house_directory/personal_directory.md)
- [Personal Directory API v1](/home/paris/dev/kinly-backend/docs/contracts/house_directory/personal_directory_api_v1.md)

```contracts-json
{
  "domain": "personal_directory_api",
  "version": "v2",
  "functions": {
    "personalDirectory.getNotes": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.get_member_directory_notes",
      "args": {
        "p_target_user_id": "uuid|null"
      },
      "returns": "jsonb"
    },
    "personalDirectory.createNote": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.create_member_directory_note_v2",
      "args": {
        "p_note_type": "text",
        "p_label": "text|null",
        "p_custom_title": "text|null",
        "p_contact_name": "text|null",
        "p_phone_number": "text|null",
        "p_details": "text|null",
        "p_reference_url": "text|null",
        "p_photo_path": "text|null"
      },
      "returns": "jsonb"
    },
    "personalDirectory.updateNote": {
      "type": "rpc",
      "caller": "authenticated",
      "impl": "public.update_member_directory_note_v2",
      "args": {
        "p_note_id": "uuid",
        "p_label": "text|null",
        "p_custom_title": "text|null",
        "p_contact_name": "text|null",
        "p_phone_number": "text|null",
        "p_details": "text|null",
        "p_reference_url": "text|null",
        "p_photo_path": "text|null"
      },
      "returns": "jsonb"
    }
  }
}
```
