---
Domain: product
Capability: app_store_review
Scope: frontend
Artifact-Type: contract
Stability: evolving
Status: active
Version: v1.1
---

# Contract: Reviewer Demo Access (Hidden Entry → Email/Password → Normal Auth)

## 1. Purpose

Enable app store reviewers to authenticate **without Google or Apple OAuth prompts** by providing a deterministic, hidden **email/password login path** that results in a **normal authenticated session**.

This contract defines **frontend behavior only**.  
After successful login, the reviewer is treated exactly like a normal user.

---

## 2. Entry Point Contract

### C1 — Hidden access trigger

**Location**
- Welcome screen where Google Sign-In and Apple Sign-In buttons are displayed.

**Trigger**
- User taps the **Kinly logo** exactly **7 times** within a single screen session.

**Effect**
- App navigates to a dedicated screen: **Demo Access**.

---

### C2 — Progressive tap counter disclosure

To avoid confusion while keeping the entry hidden, the frontend MUST implement a progressive tap counter.

#### C2.1 — Silent taps (1–2)
- No visual or textual feedback.
- Taps are counted internally.

#### C2.2 — Counter revealed (3–6)
- On the **3rd tap**, the app MUST reveal a subtle indicator that:
  - Confirms a hidden action exists
  - Shows progress toward activation

**Allowed indicator formats (choose one):**
- Toast
- Snackbar
- Small inline text near the logo
- Lightweight overlay

**Indicator content**
- Localized via `S.of(context)`
- Must communicate progress, e.g.:
  - `S.of(context).demoAccessTapHint(remainingCount)`
  - Example English:  
    > “Demo access: 3 of 7 taps”  
    > “Demo access: 4 taps remaining”

**Behavior**
- Indicator updates on each subsequent tap.
- Indicator disappears automatically after a short duration (e.g. 1–2 seconds).

#### C2.3 — Activation (7th tap)
- On the **7th tap**:
  - The indicator (if visible) is dismissed.
  - Navigation to **Demo Access** screen occurs immediately.

#### C2.4 — Counter reset
The tap counter MUST reset to zero if the user navigates away from the Welcome screen.

---

## 3. Demo Access Screen Contract

### C3 — Screen identity

**Screen title**
- `S.of(context).demoAccess`

### C4 — Required UI elements

The screen MUST contain:

1. **Username / Email input**
   - Label via localization (`S.of(context)`).
   - Plain text input.

2. **Password input**
   - Label via localization (`S.of(context)`).
   - Obscured input.

3. **Submit button**
   - Label: `S.of(context).submit`.

---

### C5 — Explicit exclusions

The Demo Access screen MUST NOT include:

- Password reset flow
- “Forgot password” link
- Account creation / sign-up option
- OAuth buttons (Google / Apple)

This screen exists solely for deterministic reviewer access.

---

## 4. Authentication Behavior Contract

### C6 — Submit action

On submit, the frontend MUST emit an authentication event to the AuthBloc:
- `DemoLoginRequested(email: email, password: password)`

The BLoC invokes the AuthRepository, which calls Supabase internally.

### C6.1 — Loading state
While authentication is in progress, the submit button MUST be disabled and show a loading indicator.

### C6.2 — Input validation
Both fields MUST be non-empty before submit is enabled.

### C7 — Success handling

On successful authentication:
- A normal Supabase session is established.
- auth.uid() is available immediately.
- The app MUST continue using the standard post-login navigation path.

No reviewer-specific routing, flags, or modes are applied.

### C8 — Failure handling

On authentication failure:
- Display a user-safe, localized error message.
- Do NOT expose raw Supabase error strings.

Allow retry on the same screen.

## 5. Backend Assumptions (Non-Negotiable)
B1 — Demo user exists

A Supabase Auth user exists with email/password credentials.

B2 — Demo user is confirmed

The account is confirmed (no email verification step required).

B3 — Normal RLS applies

No RLS bypasses, reviewer flags, or special roles exist.

All access is governed by auth.uid() like any other user.

B4 — Entitlements are pre-provisioned

If premium features are required during review, the demo user is already entitled via the normal entitlement system.

## 6. Out of Scope

This contract explicitly does NOT define:

- Post-login user flows or screens

- Demo-only modes or feature restrictions

- Backend provisioning steps
- Credential rotation or password reset mechanics
- App Store submission instructions text

## 7. Acceptance Criteria

Tapping the Kinly logo 1–2 times shows no feedback.

On the 3rd tap, a localized progress indicator appears.

Indicator updates until the 7th tap.

On the 7th tap, the Demo Access screen opens.

Demo Access performs email/password login only.

Successful login behaves identically to any normal user.