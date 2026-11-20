# Share a Host

[中文](SHARING.md) · [First use](GETTING_STARTED.en.md)

## Registered users and teams

1. Sign in to the same instance. In Account settings, open organizations and create/join the appropriate organization. The server normally restricts organization creation to configured instance administrators.
2. Add members/teams or issue an organization join link. Recipients still need an account permitted by the instance's account-registration policy.
3. Open the Host menu → **Share…** → members/teams. Prefer a dedicated sharing Vault for only the selected Host. Review every copied key, group or jump-host dependency; whole-Vault sharing is a separate choice.
4. Set the desired role, verify the recipient device fingerprint and explicitly deliver the encrypted key. An organization administrator cannot obtain a Vault key just by adding a grant. Pending-key states are not an active cryptographic membership.
5. When changing an accepted member's role, use the owner-confirmed Make Editor/Viewer action. Removing a member restricts server access immediately; the Vault owner still needs key rotation, and any credentials already seen by the recipient should be changed.

## Team Vaults

A team Vault is an encrypted Vault that belongs to an organization. Use it to hand a set of Hosts to a team for ongoing shared use, instead of sharing Hosts one by one.

1. An owner or administrator of the organization opens **Account settings → Organizations →** the organization and chooses **New team Vault** in the **Team Vaults** section; the same action is offered in the **Put in Vault…** dialog of a Host. Enter a name and pick Viewer or Editor for teams or individual members.
2. After creation, the same window lists member devices: verify each fingerprint and deliver the key. A grant is only the desired access; a member has no Vault key until you confirm their device, and an organization administrator cannot obtain one alone.
3. Put Hosts in it: Host menu → **Put in Vault…**, choose the target Vault, then **Move** or **Copy**.
   - **Move** removes the Host from the source Vault only after its copy in the target Vault is synchronized.
   - **Copy** leaves both; later edits are not kept in step.
   - Credentials, jump Hosts and trusted host keys the Host uses are copied along. A credential with identical content or the same jump Host that already exists in the target is reused instead of duplicated, and a group of the same name is kept.
   - A Host that other Hosts still use as their jump Host can only be copied, or moved together with them.
   - Everyone with access to the target Vault can connect to these Hosts and use the logins saved with them.
4. When you create a Host and can write to more than one Vault, the editor shows **Save to** at the top, so the Host can go straight into a team Vault without passing through your personal one.
5. Members receive team Vaults delivered to their device when they open the **Organizations** page, and switch to them from the Vault list in the top menu, where team Vaults are labeled with their organization. Editors can add Hosts to a team Vault; Viewers can only use them.

## Temporary browser links

The operator must first enable SQLite cloud access, guacd, an exact HTTPS public origin, a gateway key and narrow target CIDR/port rules. See the [cloud sharing deployment guide](CLOUD-SHARING.md).

1. Establish the target's trusted SSH host key or RDP certificate pin.
2. In **Share…**, select temporary access and choose the start/expiry, custom address, openings, connection/concurrency limits and clipboard/read-only policy.
3. Copy the complete link once. The secret cannot be displayed again; rotate it if lost. Anyone holding the link may use it within its policy.
4. The visitor opens the link in a browser, clicks **Continue** to redeem and **Connect** to open a session. Nothing redeems or connects automatically. Refresh resumes only the same link's session.
5. Use activity to inspect sessions or terminate access; pause, revoke or rotate the link when required.

The gateway can decrypt login capsules and observe the session; this temporary-access mode is not zero-knowledge. Guests do not receive the login through the sharing API, but the remote account's own permissions still determine what they can do. File/drive/printing/recording channels are not offered by this guest flow. VNC is opt-in and not live-validated.

Openings are counted on redemption. Connection attempts count when the gateway admits an attempt; capacity/concurrency refusals do not consume that attempt, while target/login failure after admission may. Links use UTC time windows. Recurring schedules are not implemented.

## Missing Share controls

Check server capabilities, SQLite mode, account/Vault role and target trust. Switching account, instance or Vault while sharing cancels stale operations; an error may report a step already committed on the old server. It does not silently roll back that step or install old keys into a new session.
