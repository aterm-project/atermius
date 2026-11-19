'use strict';

// The browser build is served by its Atermius server and signs in to that
// origin only (apps/client/lib/platform/server_hosted.dart): there is no
// workspace-mode chooser, no "Server URL" field and no "Connect securely"
// step. These helpers cover the entry steps every acceptance script shares.

const SIGN_IN_FIELD_LABELS = ['Owner email', 'Email or username'];
const WORKSPACE_ADD_TOOLTIP = 'Add a host or open a local Shell or serial Console';
const NOTICE_ACKNOWLEDGE = 'I understand';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function anyVisible(locator) {
  const count = await locator.count().catch(() => 0);
  for (let index = 0; index < count; index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) return true;
  }
  return false;
}

/// Waits for the hosted sign-in or first-account page and checks that it
/// belongs to `baseUrl`: the page is on that origin and offers no address
/// field. Returns the label of the visible account field.
async function expectHostedSignIn(page, baseUrl, timeoutMs = 30000) {
  const expectedOrigin = new URL(baseUrl).origin;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const label of SIGN_IN_FIELD_LABELS) {
      const field = page.locator(`input[aria-label*=${JSON.stringify(label)}]`);
      if (!(await anyVisible(field))) continue;
      const pageOrigin = new URL(page.url()).origin;
      if (pageOrigin !== expectedOrigin) {
        throw new Error('hosted sign-in page is not on the serving origin');
      }
      if (await anyVisible(page.locator('input[aria-label*="Server URL"]'))) {
        throw new Error('hosted sign-in page offered a server address field');
      }
      return label;
    }
    await sleep(100);
  }
  throw new Error('hosted sign-in page did not appear');
}

function workspaceMarker(page) {
  return page.getByRole('button', { name: WORKSPACE_ADD_TOOLTIP, exact: false });
}

function noticeButton(page) {
  return page.getByRole('button', { name: NOTICE_ACKNOWLEDGE, exact: true });
}

/// Waits for the unlocked workspace Home page.
///
/// A device that has not yet acknowledged the account's credential-visibility
/// mode gets a one-time modal notice over the workspace. `notice` says what
/// the caller expects on this device:
///   'expect' — the notice must appear; it is acknowledged (default for a
///              device's first unlock),
///   'none'   — the notice must not appear (already acknowledged here),
///   'maybe'  — acknowledge it when it appears.
async function waitForWorkspaceHome(page, { notice = 'expect', timeoutMs = 45000 } = {}) {
  if (!['expect', 'none', 'maybe'].includes(notice)) {
    throw new Error('unknown credential notice expectation');
  }
  const deadline = Date.now() + timeoutMs;
  let acknowledged = false;
  let markerSince = null;
  while (Date.now() < deadline) {
    if (await anyVisible(noticeButton(page))) {
      if (notice === 'none') {
        throw new Error('credential visibility notice reappeared on an acknowledged device');
      }
      await noticeButton(page).first().click({ timeout: 10000 }).catch(() => {});
      // The dialog fades out after the click. Wait until it is gone: a
      // second click aimed at the fading button would wait for a button
      // that no longer exists until its own timeout.
      const closeDeadline = Date.now() + 10000;
      while (Date.now() < closeDeadline && await anyVisible(noticeButton(page))) {
        await sleep(100);
      }
      if (await anyVisible(noticeButton(page))) {
        throw new Error('credential visibility notice did not close after it was acknowledged');
      }
      acknowledged = true;
      markerSince = null;
      continue;
    }
    if (await anyVisible(workspaceMarker(page))) {
      if (acknowledged || notice === 'none') return { noticeAcknowledged: acknowledged };
      markerSince ??= Date.now();
      // 'maybe': the notice follows the first status fetch; give it a
      // moment before deciding it is not coming.
      if (notice === 'maybe' && Date.now() - markerSince > 4000) {
        return { noticeAcknowledged: false };
      }
    } else {
      markerSince = null;
    }
    await sleep(100);
  }
  if (notice === 'expect' && !acknowledged && markerSince !== null) {
    throw new Error('credential visibility notice did not appear on a new device');
  }
  throw new Error('workspace Home page did not appear');
}

module.exports = {
  WORKSPACE_ADD_TOOLTIP,
  expectHostedSignIn,
  waitForWorkspaceHome,
  workspaceMarker,
};
