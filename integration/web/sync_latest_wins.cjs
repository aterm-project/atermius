'use strict';

/*
 * WEB-SYNC-LATEST-WINS-01
 *
 * One account on two devices (two isolated Chromium contexts) against a
 * disposable local server and SQLite database.
 *
 *  1. Device A registers the owner (an instance administrator) and saves a
 *     Host. Device B signs in with the same account as a new device and
 *     receives the Host.
 *  2. Both devices go offline and edit the same Host. B reconnects and pushes
 *     first; A reconnects afterwards with an edit based on the version B has
 *     already replaced.
 *  3. Latest version wins: A's later push becomes the current version on both
 *     devices, neither Sync page shows an open conflict, the server stores no
 *     conflict branch, and the Host's Version history lists the three
 *     versions with the device that made each one ("This device", or the
 *     other device's name). A dialog that identifies the other device only as
 *     "Node <ID prefix>" is recorded as a product defect: the scenario goes
 *     on, and the run fails at the end with every such defect listed.
 *  4. The administrator lowers "Versions kept per record" in the admin
 *     console. The very next push prunes the record to the new limit, and
 *     after further edits the history dialog lists exactly that many.
 *
 * Environment:
 *   ATERMIUS_WEB_ROOT        compiled Web bundle (default apps/client/build/web)
 *   ATERMIUS_SERVER_BINARY   server binary (default <target>/debug/atermius-server,
 *                            <target> = CARGO_TARGET_DIR or server/target)
 *   ATERMIUS_WEB_SHOT_DIR    directory for screenshots (optional)
 *   ATERMIUS_SYNC_POLICY_VIA_API=1  change the limit through the admin API
 *                            instead of the admin console UI
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const {
  ADMIN_CONSOLE_ENTRY,
  ADMIN_CONSOLE_EXIT,
  inAdminConsole,
  expectHostedSignIn,
  waitForWorkspaceHome,
  workspaceMarker,
} = require('./support/hosted_web.cjs');

const ACCEPTANCE_ID = 'WEB-SYNC-LATEST-WINS-01';
const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = process.env.ATERMIUS_WEB_ROOT
  ? path.resolve(process.env.ATERMIUS_WEB_ROOT)
  : path.join(ROOT, 'apps/client/build/web');
const CARGO_TARGET_DIR = process.env.CARGO_TARGET_DIR
  ? path.resolve(ROOT, process.env.CARGO_TARGET_DIR)
  : path.join(ROOT, 'server/target');
const SERVER_BINARY = process.env.ATERMIUS_SERVER_BINARY
  ? path.resolve(process.env.ATERMIUS_SERVER_BINARY)
  : path.join(CARGO_TARGET_DIR, 'debug/atermius-server');
const SHOT_DIR = process.env.ATERMIUS_WEB_SHOT_DIR || null;
const POLICY_VIA_API = process.env.ATERMIUS_SYNC_POLICY_VIA_API === '1';
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

const suffix = crypto.randomBytes(4).toString('hex');
const USERNAME = `latest-wins-${suffix}@example.test`;
const PASSWORD = `Latest-wins-${crypto.randomBytes(18).toString('base64url')}`;
const DEVICE_A = `Device A ${suffix}`;
const DEVICE_B = `Device B ${suffix}`;
const HOST_NAME = `Shared host ${suffix}`;
const HOST_USER = 'latest-wins-user';
const ADDRESS_CREATED = `created-${suffix}.latest-wins.example.test`;
const ADDRESS_FROM_B = `from-b-${suffix}.latest-wins.example.test`;
const ADDRESS_FROM_A = `from-a-${suffix}.latest-wins.example.test`;
// Lowered limit, and how many versions exist before it is lowered.
const LOWERED_LIMIT = 3;
const VERSIONS_BEFORE_LOWERING = 5;
const EDITS_AFTER_LOWERING = 3;

let stage = 'start';
const log = (...items) => console.log(new Date().toISOString().slice(11, 19), ...items);
function setStage(next) {
  stage = next;
  log('stage:', next);
}
function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A failed product expectation that does not prevent the rest of the
// scenario from running. The run still fails; every one is listed at the end.
const productDefects = [];
function expectProduct(condition, message) {
  if (condition) return true;
  productDefects.push(message);
  log('PRODUCT DEFECT:', message);
  return false;
}

async function unusedPort(address = '127.0.0.1') {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, address, resolve);
  });
  const { port } = listener.address();
  await new Promise((resolve) => listener.close(resolve));
  return port;
}

async function waitUntil(predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await predicate();
    if (last) return last;
    await sleep(150);
  }
  throw new Error(`timed out waiting for ${label}`);
}

// ---------------------------------------------------------------- browser

async function shot(page, name) {
  if (!SHOT_DIR) return;
  await page.screenshot({ path: path.join(SHOT_DIR, `${name}.png`) }).catch(() => {});
}

async function dump(page, tag) {
  const labels = await page.evaluate(() => [...document.querySelectorAll(
    'flt-semantics[role],flt-semantics[aria-label],input,textarea')]
    .filter((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    })
    .map((node) => `${node.getAttribute('role') || node.tagName}:${
      (node.getAttribute('aria-label') || node.innerText || '').replace(/\n/g, ' | ').slice(0, 110)}`)
    .filter((line) => !line.endsWith(':'))).catch(() => []);
  log(tag, JSON.stringify(labels.slice(0, 160)));
}

// While the pointer rests on a control with a tooltip, that control's
// accessible name becomes "<label> <tooltip>"; park it on an empty corner.
async function parkPointer(page) {
  const viewport = page.viewportSize() || { width: 800, height: 600 };
  await page.mouse.move(viewport.width - 3, Math.round(viewport.height / 2));
}

async function field(page, label, timeoutMs = 20000) {
  const selector = `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`;
  const locator = page.locator(selector);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const count = await locator.count();
    for (let index = 0; index < count; index += 1) {
      if (await locator.nth(index).isVisible()) return locator.nth(index);
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`browser field '${label}' is not visible`);
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(150);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 30 });
    await page.waitForTimeout(200);
    if (await locator.inputValue() === value) {
      await locator.press('Tab');
      await page.waitForTimeout(100);
      if (await locator.inputValue() === value) return;
    }
  }
  throw new Error(`browser field '${label}' did not retain its input`);
}

async function button(page, label, timeoutMs = 20000) {
  const matches = page.getByRole('button', { name: label, exact: true });
  const deadline = Date.now() + timeoutMs;
  const startedAt = Date.now();
  let parked = false;
  while (Date.now() < deadline) {
    const count = await matches.count();
    for (let index = 0; index < count; index += 1) {
      if (await matches.nth(index).isVisible()) return matches.nth(index);
    }
    if (!parked && Date.now() - startedAt > 1000) {
      parked = true;
      await parkPointer(page);
    }
    await page.waitForTimeout(100);
  }
  throw new Error(`visible button not found: ${label}`);
}

async function click(page, label, timeoutMs) {
  await (await button(page, label, timeoutMs)).click();
}

// Visible text of the semantics tree: every visible node's own label (its
// aria-label, or the text it renders itself outside child semantics nodes),
// split into lines. A node's text is never taken from its descendants, so a
// repeated line is a repeated node.
async function semanticLines(page) {
  return page.evaluate(() => {
    const lines = [];
    const ownText = (node) => {
      let text = '';
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          text += child.textContent;
        } else if (child.nodeType === Node.ELEMENT_NODE &&
            !child.tagName.toLowerCase().startsWith('flt-semantics')) {
          text += `${child.innerText || child.textContent || ''}\n`;
        }
      }
      return text;
    };
    // A card whose only focusable child is a text field carries its whole
    // text in that field's aria-label.
    for (const node of document.querySelectorAll(
      'flt-semantics,input[aria-label],textarea[aria-label]')) {
      const rect = node.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const own = node.getAttribute('aria-label') ||
        (node.tagName.toLowerCase() === 'flt-semantics' ? ownText(node) : '');
      if (own) lines.push(...own.split('\n').map((line) => line.trim()).filter(Boolean));
    }
    return lines;
  }).catch(() => []);
}

async function open(page, baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded' });
  await waitUntil(async () => await page.locator('flt-semantics-placeholder').count() > 0,
    60000, 'the Flutter semantics placeholder');
  await page.evaluate(async () => { await window.sodium?.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await expectHostedSignIn(page, baseUrl);
}

// ------------------------------------------------------------------ hosts

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hostCard(page, name) {
  return page.getByRole('group', {
    name: new RegExp(`^Host: ${escapeRegExp(name)}; `),
  }).first();
}

async function hostVisible(page, name, endpoint) {
  return page.evaluate(({ expectedName, expectedEndpoint }) => {
    const prefix = `Host: ${expectedName}; `;
    return [...document.querySelectorAll('flt-semantics[role="group"]')]
      .map((node) => (node.getAttribute('aria-label') || '').trim())
      .some((label) => label.startsWith(prefix) && label.includes(`@${expectedEndpoint}`));
  }, { expectedName: name, expectedEndpoint: endpoint }).catch(() => false);
}

async function waitForHost(page, name, endpoint, timeoutMs = 30000) {
  try {
    await waitUntil(() => hostVisible(page, name, endpoint), timeoutMs,
      `Host ${name} at ${endpoint}`);
  } catch (error) {
    const labels = await page.evaluate(() =>
      [...document.querySelectorAll('flt-semantics[role="group"]')]
        .map((node) => node.getAttribute('aria-label') || '')
        .filter((label) => label.startsWith('Host: '))).catch(() => []);
    log('visible Host cards', JSON.stringify(labels));
    throw error;
  }
}

async function waitForHostEditor(page) {
  const dialog = page.locator('flt-semantics[role="dialog"]').filter({
    has: page.getByRole('button', { name: 'Save encrypted host', exact: true }),
  }).filter({ has: page.locator('input[aria-label*="Display name"]') });
  await dialog.first().waitFor({ state: 'visible', timeout: 20000 });
}

async function waitForHostEditorClosed(page) {
  await waitUntil(async () => await page.getByRole('button', {
    name: 'Save encrypted host', exact: true,
  }).count() === 0, 20000, 'the Host editor to close');
}

async function addHost(page, { name, address, username }) {
  await workspaceMarker(page).first().click();
  const item = page.getByRole('menuitem', { name: 'New SSH host', exact: true });
  await item.waitFor({ state: 'visible', timeout: 15000 });
  await item.click();
  await waitForHostEditor(page);
  await fill(page, 'Display name', name);
  await fill(page, 'Hostname or IP', address);
  await fill(page, 'Port', '22');
  await fill(page, 'SSH username', username);
  await click(page, 'Save encrypted host');
  await waitForHostEditorClosed(page);
  await waitForHost(page, name, `${address}:22`);
}

async function openHostMenuItem(page, name, item) {
  const card = hostCard(page, name);
  await card.waitFor({ state: 'visible', timeout: 15000 });
  await parkPointer(page);
  await card.getByRole('button', { name: 'More', exact: true }).click();
  const entry = page.getByRole('menuitem', { name: item, exact: true });
  await entry.waitFor({ state: 'visible', timeout: 15000 });
  await entry.click();
}

async function editHostAddress(page, name, address) {
  await openHostMenuItem(page, name, 'Edit');
  await waitForHostEditor(page);
  await fill(page, 'Hostname or IP', address);
  await click(page, 'Save encrypted host');
  await waitForHostEditorClosed(page);
  await waitForHost(page, name, `${address}:22`);
}

// ------------------------------------------------------------------- sync

const SYNC_STATE_WORDS = [
  'Idle', 'Pending', 'Syncing', 'Retry queued', 'Offline', 'Sync error',
  'Snapshot needed', 'Key update needed', 'Read-only', 'Sign in needed',
  'Device revoked',
];

// The workspace status line reads "<Vault> · <state> · <n> pending".
async function syncStatus(page) {
  return page.evaluate((words) => {
    for (const node of document.querySelectorAll('flt-semantics')) {
      const rect = node.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const text = `${node.getAttribute('aria-label') || ''}\n${node.innerText || ''}`;
      for (const rawLine of text.split('\n')) {
        const match = /(?:^| · )([^·]+) · (\d+) pending$/.exec(rawLine.trim());
        if (match && words.includes(match[1].trim())) {
          return { state: match[1].trim(), pending: Number(match[2]) };
        }
      }
    }
    return null;
  }, SYNC_STATE_WORDS).catch(() => null);
}

async function waitForSyncStatus(page, predicate, label, timeoutMs = 45000) {
  let last = null;
  try {
    return await waitUntil(async () => {
      last = await syncStatus(page);
      return last && predicate(last) ? last : null;
    }, timeoutMs, label);
  } catch (error) {
    log('last sync status', JSON.stringify(last));
    throw error;
  }
}

const VAULT_MENU_BUTTON = /^Host menu · click to open(?: Host menu · click to open)?$/;
const SYNC_ACTION_ITEM =
  /^(Idle|Pending|Syncing|\d+ pending|Retry queued|Offline|Sync error)$/;

// Starts a sync pass from the Host menu unless one is already running.
async function startSync(page) {
  await parkPointer(page);
  const menuButton = page.getByRole('button', { name: VAULT_MENU_BUTTON }).first();
  const item = page.getByRole('menuitem', { name: SYNC_ACTION_ITEM }).first();
  const closeMenu = async () => {
    await page.keyboard.press('Escape');
    await item.waitFor({ state: 'hidden', timeout: 2000 }).catch(() => {});
    if (await item.isVisible().catch(() => false)) {
      // Dismiss through the modal barrier when the menu kept keyboard focus
      // elsewhere.
      const viewport = page.viewportSize() || { width: 800, height: 600 };
      await page.mouse.click(viewport.width - 4, viewport.height - 4);
      await item.waitFor({ state: 'hidden', timeout: 5000 });
    }
    await parkPointer(page);
  };
  // The item is disabled while a pass holds the gate, and an open menu does
  // not refresh; reopen it until the item is offered.
  const deadline = Date.now() + 30000;
  for (;;) {
    await menuButton.waitFor({ state: 'visible', timeout: 15000 });
    await menuButton.click();
    await item.waitFor({ state: 'visible', timeout: 15000 });
    const label = (await item.getAttribute('aria-label') || await item.innerText()).trim();
    const disabled = await item.getAttribute('aria-disabled') === 'true';
    if (!disabled && label !== 'Syncing') break;
    await closeMenu();
    if (label === 'Syncing') return;
    if (Date.now() >= deadline) throw new Error('the sync action stayed disabled');
    await page.waitForTimeout(250);
  }
  await item.click();
  await parkPointer(page);
}

async function settledClean(page) {
  const status = await syncStatus(page);
  if (!status || status.state !== 'Idle' || status.pending !== 0) return false;
  // Stable for a moment: a pass that is about to start would flip it.
  await page.waitForTimeout(600);
  const again = await syncStatus(page);
  return Boolean(again && again.state === 'Idle' && again.pending === 0);
}

// Waits until the device is idle with an empty outbox. Automatic sync
// usually gets there by itself after an edit or a reconnect; a pass is
// started from the Host menu when it has not after a few seconds.
async function syncUntilClean(page, label) {
  const deadline = Date.now() + 75000;
  let nextManualStart = Date.now() + 4000;
  for (;;) {
    if (await settledClean(page)) return;
    if (Date.now() >= deadline) {
      throw new Error(`${label}: sync did not settle (${JSON.stringify(await syncStatus(page))})`);
    }
    if (Date.now() >= nextManualStart) {
      nextManualStart = Date.now() + 5000;
      await startSync(page);
    }
    await page.waitForTimeout(400);
  }
}

// ---------------------------------------------------------- server state

function serverRecordState(databasePath, recordId) {
  const script = `
import json, sqlite3, sys
db = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
db.row_factory = sqlite3.Row
record = sys.argv[2]
versions = [dict(r) for r in db.execute(
    'SELECT revision_id,base_revision_id,commit_seq,device_id,operation '
    'FROM record_versions WHERE record_id=? ORDER BY commit_seq', (record,))]
head = db.execute('SELECT revision_id FROM record_heads WHERE record_id=?', (record,)).fetchone()
conflicts = db.execute('SELECT COUNT(*) FROM conflicts').fetchone()[0]
open_conflicts = db.execute(
    'SELECT COUNT(*) FROM conflicts WHERE resolved_revision_id IS NULL').fetchone()[0]
policy = db.execute(
    'SELECT record_history_limit,revision FROM instance_sync_policy WHERE policy_id=1').fetchone()
devices = {r['device_id']: r['name'] for r in db.execute('SELECT device_id,name FROM devices')}
print(json.dumps({
    'versions': versions,
    'head': head['revision_id'] if head else None,
    'conflicts': conflicts,
    'openConflicts': open_conflicts,
    'policy': dict(policy) if policy else None,
    'devices': devices,
}))
`;
  const result = spawnSync('python3', ['-I', '-c', script, databasePath, recordId],
    { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`server database read failed: ${(result.stderr || '').slice(0, 400)}`);
  }
  return JSON.parse(result.stdout);
}

// ---------------------------------------------------------------- history

// The JSON body of a GET the page made. Chromium does not always keep the
// body of a finished request; the same request is then repeated with the
// page's own session and client headers.
async function responseJson(response) {
  try {
    return await response.json();
  } catch (_) {
    const sent = await response.request().allHeaders();
    const headers = Object.fromEntries(Object.entries(sent).filter(([name]) =>
      name === 'authorization' || name.startsWith('x-atermius-')));
    const repeated = await fetch(response.url(), { headers });
    assertThat(repeated.status === 200,
      `repeating ${new URL(response.url()).pathname} returned ${repeated.status}`);
    return repeated.json();
  }
}

const HISTORY_DIALOG = 'flt-semantics[role="alertdialog"],flt-semantics[role="dialog"]';

// Opens the Host's Version history and returns what the dialog lists, newest
// first, with the server response the dialog was built from.
async function readHostHistory(page, name, shotName) {
  const isHistoryResponse = (response) =>
    /\/api\/v1\/vaults\/[^/]+\/records\/[^/]+\/revisions$/.test(
      new URL(response.url()).pathname) && response.request().method() === 'GET';
  // The history is an AlertDialog (role "alertdialog").
  const dialog = page.locator(HISTORY_DIALOG).last();
  let response = null;
  // A menu item activated while the page behind it is still settling after
  // a navigation is occasionally dropped; open the menu again in that case.
  for (let attempt = 0; attempt < 3 && response === null; attempt += 1) {
    const responsePromise = page.waitForResponse(isHistoryResponse, { timeout: 8000 })
      .catch(() => null);
    await openHostMenuItem(page, name, 'Version history');
    response = await responsePromise;
    if (response === null && await dialog.isVisible().catch(() => false)) {
      throw new Error('the Version history dialog opened without a history request');
    }
  }
  assertThat(response !== null, 'the Version history menu item did not open the dialog');
  assertThat(response.status() === 200,
    `record history request returned ${response.status()}`);
  const body = await responseJson(response);
  const recordId = new URL(response.url()).pathname.split('/').slice(-2)[0];
  await dialog.waitFor({ state: 'visible', timeout: 15000 });
  // One semantics node per listed version, in list order. Its text is
  // "<time>", "Current" on the head, "<operation> · <device>", then the
  // change summary, one per line: the node's aria-label when the row has a
  // Restore button, otherwise the text it renders itself.
  const readEntries = async () => page.evaluate((selector) => {
    const dialogs = [...document.querySelectorAll(selector)];
    const root = dialogs[dialogs.length - 1];
    if (!root) return [];
    const headline = /^(Created|Edited|Deleted|Restored) · (.+)$/;
    const entries = [];
    for (const node of root.querySelectorAll('flt-semantics')) {
      let text = node.getAttribute('aria-label') || '';
      if (!text) {
        for (const child of node.children) {
          if (!child.tagName.toLowerCase().startsWith('flt-semantics')) {
            text += `${child.textContent || ''}\n`;
          }
        }
      }
      const rows = text.split('\n').map((row) => row.trim()).filter(Boolean);
      const match = rows.map((row) => headline.exec(row)).find(Boolean);
      if (!match) continue;
      entries.push({
        time: rows[0],
        operation: match[1],
        device: match[2],
        current: rows.includes('Current'),
        summary: rows.find((row) => /^(Changed: |No field changes$|Earliest kept version$)/.test(row)) || null,
      });
    }
    return entries;
  }, HISTORY_DIALOG).catch(() => []);
  let entries = [];
  await waitUntil(async () => {
    entries = await readEntries();
    return entries.length > 0;
  }, 20000, 'the Version history entries');
  await page.waitForTimeout(500);
  entries = await readEntries();
  const lines = await semanticLines(page);
  await shot(page, shotName);
  const limitLine = lines.find((line) =>
    /^The server keeps the latest \d+ versions of each record\.$/.test(line)) || null;
  const titled = lines.some((line) => line.includes(`Version history · ${name}`));
  const currentBadges = entries.filter((entry) => entry.current).length;
  await click(page, 'Close');
  await waitUntil(async () => await page.locator(HISTORY_DIALOG).count() === 0, 15000,
    'the Version history dialog to close');
  return {
    recordId,
    entries,
    limitLine,
    titled,
    currentBadges,
    lines,
    serverLimit: body.record_history_limit,
    serverRevisions: body.revisions.map((revision) => ({
      revisionId: revision.revision_id,
      deviceId: revision.device_id,
      operation: revision.operation,
    })),
  };
}

// The Sync page's "Open conflicts" tile and conflict cards.
async function syncPageEvidence(page, shotName) {
  await parkPointer(page);
  const navigation = page.getByRole('button', { name: /^Sync and conflicts(?:\s+\d+)?$/ });
  await waitUntil(async () => {
    const count = await navigation.count();
    for (let index = 0; index < count; index += 1) {
      if (await navigation.nth(index).isVisible()) {
        await navigation.nth(index).click();
        return true;
      }
    }
    return false;
  }, 15000, 'the Sync and conflicts navigation item');
  let lines = [];
  await waitUntil(async () => {
    lines = await semanticLines(page);
    return lines.some((line) => /Open conflicts/.test(line));
  }, 20000, 'the Sync health tiles');
  await page.waitForTimeout(500);
  lines = await semanticLines(page);
  await shot(page, shotName);
  const text = lines.join('\n');
  const openConflicts = /Open conflicts\s+(\d+)/.exec(text);
  const outbox = /Outbox items\s+(\d+)/.exec(text);
  return {
    openConflicts: openConflicts ? Number(openConflicts[1]) : null,
    outboxItems: outbox ? Number(outbox[1]) : null,
    noOpenConflicts: lines.includes('No open conflicts'),
    noCrossDeviceBranches: lines.includes('No pending cross-device branches'),
    upToDate: lines.includes('Up to date'),
    nodeIdShown: lines.some((line) => /Node ID/.test(line)),
    lines,
  };
}

// ------------------------------------------------------------ admin policy

async function lowerLimitThroughAdminConsole(page, limit) {
  await parkPointer(page);
  await click(page, ADMIN_CONSOLE_ENTRY);
  await waitUntil(async () => inAdminConsole(page), 30000, 'the admin console');
  await click(page, 'Vaults and quotas', 30000);
  // The card loads the current policy on request.
  await click(page, 'Load history limit', 30000);
  const limitField = await field(page, 'Versions kept per record', 30000);
  // The loaded policy is the deployment default until someone changes it.
  let shownBefore = '';
  await waitUntil(async () => {
    // Flutter copies the field's text into its editing input on focus.
    await limitField.click();
    await page.waitForTimeout(200);
    shownBefore = await limitField.inputValue();
    return shownBefore !== '';
  }, 15000, 'the loaded history limit');
  assertThat(shownBefore === '20' && (await semanticLines(page)).includes('Server default: 20'),
    `the admin console shows a history limit of ${JSON.stringify(shownBefore)} before the change`);
  await fill(page, 'Versions kept per record', String(limit));
  await shot(page, '30-admin-console-history-limit');
  const policyResponse = page.waitForResponse((response) =>
    new URL(response.url()).pathname === '/api/v1/admin/sync-policy' &&
    response.request().method() === 'PUT', { timeout: 30000 });
  policyResponse.catch(() => {});
  await click(page, 'Save history limit');
  const response = await policyResponse;
  assertThat(response.status() === 200,
    `admin console did not save the history limit (status ${response.status()})`);
  // Chromium does not always keep the body of a finished request; the caller
  // checks the persisted policy in the server database either way.
  const body = await response.json().catch(() => null);
  assertThat(body === null || body.record_history_limit === limit,
    'the admin console saved a different history limit than the one entered');
  await waitUntil(async () => (await semanticLines(page))
    .some((line) => line.includes('History limit saved.')), 15000,
  'the "History limit saved." notice');
  await shot(page, '31-admin-console-history-limit-saved');
  await click(page, ADMIN_CONSOLE_EXIT);
  await waitUntil(async () => !inAdminConsole(page), 30000, 'the workspace after the admin console');
  await waitForWorkspaceHome(page, { notice: 'none' });
  return { ...(body || { response_body: 'not retained by the browser' }), shown_before: shownBefore };
}

async function lowerLimitThroughApi(baseUrl, token, limit) {
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  const current = await (await fetch(`${baseUrl}/api/v1/admin/sync-policy`, { headers })).json();
  const response = await fetch(`${baseUrl}/api/v1/admin/sync-policy`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ expected_revision: current.revision, record_history_limit: limit }),
  });
  const body = await response.json();
  assertThat(response.status === 200 && body.record_history_limit === limit,
    `admin API did not save the history limit (status ${response.status})`);
  return body;
}

// ------------------------------------------------------------------- main

async function main() {
  assertThat(fs.existsSync(path.join(WEB_ROOT, 'index.html')),
    `Web bundle not found at ${WEB_ROOT}`);
  assertThat(fs.existsSync(SERVER_BINARY), `server binary not found at ${SERVER_BINARY}`);
  if (SHOT_DIR) fs.mkdirSync(SHOT_DIR, { recursive: true });

  const apiPort = await unusedPort();
  const baseUrl = `http://127.0.0.1:${apiPort}`;
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-sync-latest-wins-'));
  const dataDir = path.join(tempRoot, 'data');
  fs.mkdirSync(dataDir, { mode: 0o700 });
  const databasePath = path.join(dataDir, 'atermius.db');
  let server;
  let browser;
  const pages = {};
  let bearerA = null;
  // A terminated run (Ctrl-C, a timeout wrapper, a closed output pipe) must
  // not leave the server or its data directory behind.
  const stopServer = () => {
    if (server) {
      try { process.kill(-server.pid, 'SIGTERM'); } catch (_) { /* already gone */ }
    }
    fs.rmSync(tempRoot, { recursive: true, force: true });
  };
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.once(signal, () => {
      stopServer();
      process.exit(1);
    });
  }
  process.once('exit', stopServer);
  try {
    setStage('start the disposable server');
    const env = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${apiPort}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_ADMIN_USERNAMES: USERNAME,
      RUST_LOG: 'off',
    };
    delete env.ATERMIUS_RECORD_HISTORY_LIMIT;
    server = spawn(SERVER_BINARY, ['serve'], { cwd: ROOT, env, detached: true, stdio: 'ignore' });
    await waitUntil(async () => {
      if (server.exitCode !== null) throw new Error('the server exited during startup');
      try {
        return (await fetch(`${baseUrl}/health/ready`)).status === 200;
      } catch (_) {
        return false;
      }
    }, 60000, 'the server to become ready');
    const boot = spawnSync(SERVER_BINARY, ['bootstrap'], { cwd: ROOT, env, encoding: 'utf8' });
    const tokenMatch = (boot.stdout || '').match(/(?:^|\n)([A-Za-z0-9_-]{40,})\s*$/);
    assertThat(tokenMatch, 'the bootstrap command printed no token');
    const instance = await (await fetch(`${baseUrl}/api/v1/instance`)).json();
    assertThat(instance.limits.record_history_limit === 20,
      'a new instance does not advertise the default history limit of 20');

    browser = await chromium.launch({
      headless: true,
      executablePath: CHROMIUM_EXECUTABLE || undefined,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
    const contextA = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 900 } });
    const contextB = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 900 } });
    const pageA = await contextA.newPage();
    const pageB = await contextB.newPage();
    pages.A = pageA;
    pages.B = pageB;
    const pageErrors = [];
    const conflictUploads = [];
    const pushes = [];
    for (const [profile, page] of Object.entries(pages)) {
      page.on('pageerror', (error) => {
        pageErrors.push(profile);
        log('PAGEERROR', profile, String(error.message).slice(0, 300));
      });
      page.on('request', (request) => {
        const { pathname } = new URL(request.url());
        if (profile === 'A' && !bearerA && pathname.startsWith('/api/v1/vaults')) {
          const header = request.headers().authorization || '';
          if (header.startsWith('Bearer ')) bearerA = header.slice(7);
        }
      });
      page.on('response', (response) => {
        const request = response.request();
        const { pathname } = new URL(response.url());
        if (request.method() !== 'POST') return;
        if (/^\/api\/v1\/vaults\/[^/]+\/conflicts$/.test(pathname)) {
          conflictUploads.push({ profile, status: response.status() });
        }
        if (/^\/api\/v1\/vaults\/[^/]+\/sync\/push$/.test(pathname)) {
          pushes.push({ profile, status: response.status(), at: Date.now() });
        }
      });
    }

    setStage('device A: register the owner');
    await open(pageA, baseUrl);
    await fill(pageA, 'Owner email', USERNAME);
    await fill(pageA, 'Master password · 12+ characters', PASSWORD);
    await fill(pageA, 'Confirm master password', PASSWORD);
    await fill(pageA, 'One-time bootstrap token', tokenMatch[1]);
    await fill(pageA, 'Device name', DEVICE_A);
    await fill(pageA, 'First Vault', `Latest wins ${suffix}`);
    await click(pageA, 'Create owner account');
    await waitForWorkspaceHome(pageA, { notice: 'expect' });

    setStage('device A: save the shared Host');
    await addHost(pageA, { name: HOST_NAME, address: ADDRESS_CREATED, username: HOST_USER });
    await syncUntilClean(pageA, 'device A after creating the Host');
    await shot(pageA, '01-a-host-created');

    setStage('device B: sign in with the same account as a new device');
    await open(pageB, baseUrl);
    await fill(pageB, 'Email or username', USERNAME);
    await fill(pageB, 'Master password', PASSWORD);
    const deviceNameField = pageB.locator('input[aria-label*="Device name"]');
    if (await deviceNameField.count() > 0 && await deviceNameField.first().isVisible()) {
      await fill(pageB, 'Device name', DEVICE_B);
    }
    await click(pageB, 'Sign in and unlock');
    await waitForWorkspaceHome(pageB, { notice: 'expect' });
    await waitForHost(pageB, HOST_NAME, `${ADDRESS_CREATED}:22`, 45000);
    await syncUntilClean(pageB, 'device B after its first sync');
    await shot(pageB, '02-b-host-received');

    setStage('both devices go offline and edit the same Host');
    await Promise.all([contextA.setOffline(true), contextB.setOffline(true)]);
    await editHostAddress(pageB, HOST_NAME, ADDRESS_FROM_B);
    await editHostAddress(pageA, HOST_NAME, ADDRESS_FROM_A);
    const offlineA = await waitForSyncStatus(pageA, (status) => status.pending >= 1,
      'device A to queue its offline edit');
    const offlineB = await waitForSyncStatus(pageB, (status) => status.pending >= 1,
      'device B to queue its offline edit');
    log('offline outboxes', JSON.stringify({ A: offlineA, B: offlineB }));
    await shot(pageA, '03-a-offline-edit');
    await shot(pageB, '04-b-offline-edit');

    setStage('device B reconnects and pushes first');
    await contextB.setOffline(false);
    await syncUntilClean(pageB, 'device B after reconnecting');
    assertThat(pushes.some((push) => push.profile === 'B' && push.status === 200),
      'device B did not push its offline edit');
    await waitForHost(pageB, HOST_NAME, `${ADDRESS_FROM_B}:22`);

    setStage('device A reconnects with an edit based on the replaced version');
    const pushesBeforeA = pushes.length;
    await contextA.setOffline(false);
    await syncUntilClean(pageA, 'device A after reconnecting');
    log('device A pushes after reconnecting',
      JSON.stringify(pushes.slice(pushesBeforeA).filter((push) => push.profile === 'A')
        .map((push) => push.status)));

    setStage('both devices converge on the later push');
    await waitForHost(pageA, HOST_NAME, `${ADDRESS_FROM_A}:22`);
    await syncUntilClean(pageB, 'device B pulling the winning version');
    await waitForHost(pageB, HOST_NAME, `${ADDRESS_FROM_A}:22`, 45000);
    await shot(pageA, '05-a-converged');
    await shot(pageB, '06-b-converged');

    setStage('no conflict on either Sync page or on the server');
    const syncA = await syncPageEvidence(pageA, '07-a-sync-page');
    const syncB = await syncPageEvidence(pageB, '08-b-sync-page');
    const syncSummary = ({ lines, ...rest }) => rest;
    log('sync pages', JSON.stringify({ A: syncSummary(syncA), B: syncSummary(syncB) }));
    for (const [profile, evidence] of [['A', syncA], ['B', syncB]]) {
      assertThat(evidence.openConflicts === 0,
        `device ${profile} Sync page shows ${evidence.openConflicts} open conflicts`);
      assertThat(evidence.noOpenConflicts,
        `device ${profile} Sync page lists a conflict branch instead of "No open conflicts"`);
      assertThat(evidence.noCrossDeviceBranches,
        `device ${profile} Sync page lists a cross-device conflict branch`);
      assertThat(evidence.outboxItems === 0,
        `device ${profile} Sync page shows ${evidence.outboxItems} outbox items`);
      assertThat(evidence.nodeIdShown, `device ${profile} Sync page does not show its Node ID`);
    }
    assertThat(conflictUploads.length === 0,
      `a device uploaded a conflict branch: ${JSON.stringify(conflictUploads)}`);

    setStage('Version history shows the three versions with their devices');
    await click(pageA, 'Hosts');
    await waitForHost(pageA, HOST_NAME, `${ADDRESS_FROM_A}:22`);
    const historyA = await readHostHistory(pageA, HOST_NAME, '09-a-version-history');
    await click(pageB, 'Hosts');
    await waitForHost(pageB, HOST_NAME, `${ADDRESS_FROM_A}:22`);
    const historyB = await readHostHistory(pageB, HOST_NAME, '10-b-version-history');
    const recordId = historyA.recordId;
    log('history on A', JSON.stringify({ entries: historyA.entries, limit: historyA.limitLine }));
    log('history on B', JSON.stringify({ entries: historyB.entries, limit: historyB.limitLine }));
    let serverState = serverRecordState(databasePath, recordId);
    const deviceIdByName = Object.fromEntries(
      Object.entries(serverState.devices).map(([id, name]) => [name, id]));
    const deviceAId = deviceIdByName[DEVICE_A];
    const deviceBId = Object.keys(serverState.devices).find((id) => id !== deviceAId);
    log('server record', JSON.stringify({
      versions: serverState.versions.map((version) => ({
        operation: version.operation,
        device: version.device_id === deviceAId ? 'A' : version.device_id === deviceBId ? 'B' : '?',
        basedOnPrevious: version.base_revision_id,
      })),
      conflicts: serverState.conflicts,
      devices: serverState.devices,
    }));
    assertThat(deviceAId && deviceBId && Object.keys(serverState.devices).length === 2,
      'the server does not hold exactly the two devices');
    assertThat(serverState.conflicts === 0,
      `the server stores ${serverState.conflicts} conflict branches`);
    const [created, fromB, fromA] = serverState.versions;
    assertThat(serverState.versions.length === 3 &&
      created.operation === 'create' && created.device_id === deviceAId &&
      fromB.operation === 'update' && fromB.device_id === deviceBId &&
      fromB.base_revision_id === created.revision_id &&
      fromA.operation === 'update' && fromA.device_id === deviceAId &&
      fromA.base_revision_id === fromB.revision_id &&
      serverState.head === fromA.revision_id,
    'the server history is not create(A) <- update(B) <- update(A, head)');
    // What a viewer's dialog must list for the server's versions, newest
    // first: "This device" for its own versions; another device by its
    // name, or by "Node <first 8 of its ID>" while the viewer does not know
    // the name.
    const attribution = (viewerDeviceId, versions) => versions.slice().reverse().map((version) => ({
      operation: { create: 'Created', update: 'Edited', delete: 'Deleted', restore: 'Restored' }[
        version.operation],
      own: version.device_id === viewerDeviceId,
      name: serverState.devices[version.device_id],
      node: `Node ${version.device_id.slice(0, 8)}`,
    }));
    const attributedToRightDevices = (history, expected) =>
      history.entries.length === expected.length && history.entries.every((entry, index) =>
        entry.operation === expected[index].operation &&
        (expected[index].own
          ? entry.device === 'This device'
          : [expected[index].name, expected[index].node].includes(entry.device)));
    const otherDevicesNamed = (history, expected) => history.entries.every((entry, index) =>
      expected[index].own || entry.device === expected[index].name);
    const viewers = [
      { profile: 'A', page: pageA, deviceId: deviceAId, history: historyA },
      { profile: 'B', page: pageB, deviceId: deviceBId, history: historyB },
    ];
    for (const viewer of viewers) {
      const expected = attribution(viewer.deviceId, serverState.versions);
      assertThat(attributedToRightDevices(viewer.history, expected),
        `device ${viewer.profile} lists the wrong history: ${JSON.stringify(viewer.history.entries)}`);
      const named = expectProduct(otherDevicesNamed(viewer.history, expected),
        `Version history on device ${viewer.profile} shows the other device as ` +
        `${JSON.stringify(viewer.history.entries.filter((entry) => /^Node /.test(entry.device))
          .map((entry) => entry.device))} instead of its device name: the dialog only knows ` +
        'device names after the Devices page has loaded the device list in this session');
      if (!named) {
        // Narrow the defect down: once this device has loaded the device
        // list (its Devices page does), the same dialog names the other one.
        const otherName = expected.find((entry) => !entry.own).name;
        await click(viewer.page, 'Devices');
        await waitUntil(async () => (await semanticLines(viewer.page))
          .some((line) => line.includes(otherName)), 20000,
        `the other device on the Devices page of ${viewer.profile}`);
        await click(viewer.page, 'Hosts');
        await waitForHost(viewer.page, HOST_NAME, `${ADDRESS_FROM_A}:22`);
        const reopened = await readHostHistory(viewer.page, HOST_NAME,
          `11-${viewer.profile.toLowerCase()}-version-history-after-devices`);
        log(`history on ${viewer.profile} after opening Devices`, JSON.stringify(reopened.entries));
        assertThat(attributedToRightDevices(reopened, expected) &&
          otherDevicesNamed(reopened, expected),
        `device ${viewer.profile} does not name the other device even after loading its device list`);
      }
    }
    for (const [profile, history] of [['A', historyA], ['B', historyB]]) {
      assertThat(history.titled, `device ${profile} history dialog is not titled with the Host`);
      assertThat(history.currentBadges === 1,
        `device ${profile} history marks ${history.currentBadges} versions as Current`);
      assertThat(history.limitLine ===
        'The server keeps the latest 20 versions of each record.' && history.serverLimit === 20,
      `device ${profile} history does not state the default limit of 20`);
      assertThat(history.serverRevisions[0].revisionId === fromA.revision_id,
        `device ${profile} history does not start with the winning version`);
    }

    setStage(`device A builds a history of ${VERSIONS_BEFORE_LOWERING} versions`);
    let editIndex = 0;
    const nextAddress = () => {
      editIndex += 1;
      return `edit-${editIndex}-${suffix}.latest-wins.example.test`;
    };
    let currentAddress = ADDRESS_FROM_A;
    while (serverRecordState(databasePath, recordId).versions.length < VERSIONS_BEFORE_LOWERING) {
      currentAddress = nextAddress();
      await editHostAddress(pageA, HOST_NAME, currentAddress);
      await syncUntilClean(pageA, 'device A after an edit');
    }
    serverState = serverRecordState(databasePath, recordId);
    assertThat(serverState.versions.length === VERSIONS_BEFORE_LOWERING && !serverState.policy,
      'the record does not hold the expected versions before the limit is lowered');

    setStage(`the administrator lowers the history limit to ${LOWERED_LIMIT}`);
    let policy;
    if (POLICY_VIA_API) {
      assertThat(bearerA, 'no session token was observed for device A');
      policy = await lowerLimitThroughApi(baseUrl, bearerA, LOWERED_LIMIT);
    } else {
      policy = await lowerLimitThroughAdminConsole(pageA, LOWERED_LIMIT);
    }
    log('sync policy', JSON.stringify({ via: POLICY_VIA_API ? 'admin API' : 'admin console UI', policy }));
    serverState = serverRecordState(databasePath, recordId);
    assertThat(serverState.policy && serverState.policy.record_history_limit === LOWERED_LIMIT &&
      serverState.policy.revision === 1, 'the server did not persist the lowered limit');
    assertThat(serverState.versions.length === VERSIONS_BEFORE_LOWERING,
      'lowering the limit pruned by itself');
    const instanceAfter = await (await fetch(`${baseUrl}/api/v1/instance`)).json();
    assertThat(instanceAfter.limits.record_history_limit === LOWERED_LIMIT,
      'GET /api/v1/instance does not advertise the lowered limit');

    setStage('the very next push prunes to the new limit');
    await click(pageA, 'Hosts');
    await waitForHost(pageA, HOST_NAME, `${currentAddress}:22`);
    currentAddress = nextAddress();
    await editHostAddress(pageA, HOST_NAME, currentAddress);
    await syncUntilClean(pageA, 'device A after the first edit under the new limit');
    serverState = serverRecordState(databasePath, recordId);
    log('versions kept after one push under the new limit', serverState.versions.length);
    assertThat(serverState.versions.length === LOWERED_LIMIT,
      `one push after the change kept ${serverState.versions.length} versions, not ${LOWERED_LIMIT}`);

    setStage('further edits never exceed the limit');
    for (let index = 1; index < EDITS_AFTER_LOWERING; index += 1) {
      currentAddress = nextAddress();
      await editHostAddress(pageA, HOST_NAME, currentAddress);
      await syncUntilClean(pageA, 'device A after an edit under the new limit');
      assertThat(serverRecordState(databasePath, recordId).versions.length === LOWERED_LIMIT,
        'an edit under the new limit left more versions than the limit');
    }
    serverState = serverRecordState(databasePath, recordId);
    const prunedHistoryA = await readHostHistory(pageA, HOST_NAME, '32-a-version-history-pruned');
    await syncUntilClean(pageB, 'device B pulling the last edits');
    await click(pageB, 'Hosts').catch(() => {});
    await waitForHost(pageB, HOST_NAME, `${currentAddress}:22`, 45000);
    const prunedHistoryB = await readHostHistory(pageB, HOST_NAME, '33-b-version-history-pruned');
    log('pruned history on A', JSON.stringify({
      entries: prunedHistoryA.entries, limit: prunedHistoryA.limitLine }));
    log('pruned history on B', JSON.stringify({
      entries: prunedHistoryB.entries, limit: prunedHistoryB.limitLine }));
    const expectedLimitLine = `The server keeps the latest ${LOWERED_LIMIT} versions of each record.`;
    for (const [profile, history, viewerDeviceId] of [
      ['A', prunedHistoryA, deviceAId], ['B', prunedHistoryB, deviceBId]]) {
      assertThat(history.entries.length === LOWERED_LIMIT,
        `device ${profile} history lists ${history.entries.length} versions, not ${LOWERED_LIMIT}`);
      assertThat(attributedToRightDevices(history, attribution(viewerDeviceId, serverState.versions)) &&
        history.entries.every((entry) => entry.operation === 'Edited'),
      `device ${profile} pruned history has unexpected entries: ${JSON.stringify(history.entries)}`);
      assertThat(history.limitLine === expectedLimitLine && history.serverLimit === LOWERED_LIMIT,
        `device ${profile} history does not state the limit of ${LOWERED_LIMIT}`);
      assertThat(history.currentBadges === 1,
        `device ${profile} pruned history marks ${history.currentBadges} versions as Current`);
      assertThat(JSON.stringify(history.serverRevisions.map((revision) => revision.revisionId)) ===
        JSON.stringify(serverState.versions.map((version) => version.revision_id).reverse()),
      `device ${profile} history does not match the server's retained versions`);
    }
    assertThat(serverState.head === serverState.versions[LOWERED_LIMIT - 1].revision_id &&
      serverState.conflicts === 0, 'the head is not the newest retained version');
    assertThat(conflictUploads.length === 0, 'a device uploaded a conflict branch');
    assertThat(pageErrors.length === 0, `the pages raised ${pageErrors.length} errors`);

    if (productDefects.length > 0) {
      const summary = new Error(`the scenario ran to the end with ${productDefects.length} ` +
        `product defect(s):\n- ${productDefects.join('\n- ')}`);
      summary.productDefectSummary = true;
      throw summary;
    }
    console.log(`${ACCEPTANCE_ID} passed: the later push won on both devices without a ` +
      `conflict, Version history attributed all three versions, and after the limit was ` +
      `lowered to ${LOWERED_LIMIT} through the ${POLICY_VIA_API ? 'admin API' : 'admin console'} ` +
      `the history kept exactly ${LOWERED_LIMIT} versions from the first push on.`);
  } catch (error) {
    if (error && error.productDefectSummary) {
      log(`${ACCEPTANCE_ID} FAILED: ${error.message}`);
    } else {
      log(`${ACCEPTANCE_ID} FAILED during: ${stage}`);
      log(String(error && error.stack ? error.stack : error).slice(0, 1500));
      for (const [profile, page] of Object.entries(pages)) {
        await shot(page, `zz-failure-${profile}`);
        await dump(page, `FAILURE ${profile}`);
      }
    }
    process.exitCode = 1;
  } finally {
    if (browser) await browser.close().catch(() => {});
    stopServer();
  }
}

main();
