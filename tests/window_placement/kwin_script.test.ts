import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

import { test } from 'bun:test';

interface Screen {
  name: string
}

interface DesktopWindow {
  pid: number
  resourceClass: string
  fullScreen: boolean
  normalWindow: boolean
  output: Screen
  fullScreenChanged?: { connect: (handler: () => void) => void }
}

function script(mode = 'gamescope', output = 'Virtual-1', mirror = false) {
  const generator = Bun.env.HERMES_PLACEMENT_SCRIPT_GENERATOR;
  assert.ok(generator, 'Set HERMES_PLACEMENT_SCRIPT_GENERATOR to the compiled script.cc');
  return execFileSync(generator, mirror ? [mode, output, 'mirror'] : [mode, output], { encoding: 'utf8' });
}

function desktop(existing: DesktopWindow[], mode = 'gamescope', outputExists = true) {
  const physical = { name: 'HDMI-A-1' };
  const target = { name: 'Virtual-1' };
  const moves: DesktopWindow[] = [];
  let onAdded: ((window: DesktopWindow) => void) | undefined;
  const workspace = {
    screens: outputExists ? [physical, target] : [physical],
    windowList: () => existing,
    windowAdded: { connect: (handler: (window: DesktopWindow) => void) => { onAdded = handler; } },
    sendClientToScreen: (window: DesktopWindow, screen: Screen) => {
      moves.push(window);
      window.output = screen;
    },
  };
  vm.runInNewContext(script(mode), { workspace });
  return {
    moves,
    target,
    add(window: DesktopWindow) {
      assert.ok(onAdded);
      onAdded(window);
    },
  };
}

function window(pid: number, resourceClass = 'gamescope', fullScreen = true): DesktopWindow {
  return { pid, resourceClass, fullScreen, normalWindow: true, output: { name: 'HDMI-A-1' } };
}

test('moves only launched Gamescope PIDs, including windows already created', () => {
  const local = window(900);
  const streamed = window(42);
  const { moves, target, add } = desktop([local, streamed]);
  assert.deepEqual(moves, [streamed]);
  assert.equal(streamed.output, target);
  assert.equal(streamed.fullScreen, true);
  assert.equal(local.output.name, 'HDMI-A-1');
  const futureLocal = window(901);
  add(futureLocal);
  assert.equal(futureLocal.output.name, 'HDMI-A-1');
  const detached = window(43, 'gamescope', false);
  add(detached);
  assert.deepEqual(moves, [streamed, detached]);
  assert.equal(detached.fullScreen, false);
  add(streamed);
  assert.equal(moves.length, 2, 'do not move or toggle a window already on the target');
});

test('no launched PID means no class-wide Gamescope fallback', () => {
  for (const mode of ['no-pids', 'invalid-pids']) {
    const windows = [window(0), window(1), window(42), window(900)];
    const { moves, add } = desktop(windows, mode);
    add(window(42));
    assert.equal(moves.length, 0);
  }
});

test('Steam can reuse an existing process and keeps its fullscreen state', () => {
  const steam = window(900, 'steam', false);
  const unrelated = window(42);
  const { moves, add } = desktop([steam, unrelated], 'steam');
  assert.deepEqual(moves, [steam]);
  assert.equal(steam.fullScreen, false);
  const bigPicture = window(901, 'steam', true);
  add(bigPicture);
  assert.deepEqual(moves, [steam, bigPicture]);
  assert.equal(bigPicture.fullScreen, true);
});

test('Big Picture that moves itself back and goes fullscreen is placed again', () => {
  // Recorded on KDE Plasma 6.8 with a 2560x1440 primary monitor lit: Steam
  // adds "Steam Big Picture Mode" on the primary monitor, the script moves it
  // to Virtual-1, Steam moves it straight back and makes it fullscreen there.
  const handlers: (() => void)[] = [];
  let fullScreen = false;
  const bigPicture: DesktopWindow = {
    pid: 4538,
    resourceClass: 'steam',
    normalWindow: true,
    output: { name: 'HDMI-A-1' },
    fullScreenChanged: { connect: fn => handlers.push(fn) },
    get fullScreen() { return fullScreen; },
    set fullScreen(value) {
      if (value !== fullScreen) {
        fullScreen = value;
        handlers.forEach(fn => fn());
      }
    },
  };
  const { moves, target, add } = desktop([], 'steam');
  add(bigPicture);
  assert.deepEqual(moves, [bigPicture]);
  assert.equal(bigPicture.output, target);
  assert.equal(bigPicture.fullScreen, false, 'a window that was not fullscreen stays that way');

  bigPicture.output = { name: 'HDMI-A-1' };  // Steam moves it back...
  bigPicture.fullScreen = true;              // ...and goes fullscreen there.
  assert.deepEqual(moves, [bigPicture, bigPicture]);
  assert.equal(bigPicture.output, target);
  assert.equal(bigPicture.fullScreen, true);

  bigPicture.fullScreen = false;  // Leaving fullscreen on the target is left alone.
  bigPicture.fullScreen = true;
  assert.equal(moves.length, 2, 'already on the target: no further move');
});

test('missing outputs and non-normal windows are left alone', () => {
  const hidden = window(42);
  hidden.normalWindow = false;
  assert.equal(desktop([hidden]).moves.length, 0);
  assert.equal(desktop([window(42)], 'gamescope', false).moves.length, 0);
});

test('rejects an output name that could inject JavaScript', () => {
  assert.equal(script('gamescope', 'Virtual-1";throw Error("injected")//'), '');
});

interface Rect {
  x: number
  y: number
  width: number
  height: number
}

interface MirrorScreen {
  name: string
  geometry: Rect
  geometryChanged: { connect: (handler: () => void) => void }
}

interface MirrorWindow {
  pid: number
  resourceClass: string
  fullScreen: boolean
  normalWindow: boolean
  noBorder: boolean
  keepAbove: boolean
  frameGeometry: Rect
  output: { name: string }
  fullScreenChanged: { connect: (handler: () => void) => void }
  frameGeometryChanged: { connect: (handler: () => void) => void }
}

// Recorded on Haven (KDE Plasma 6, 2026-11-24): a 2992x1344 Hestia RS stream
// in the mirror layout. Virtual-1 is scaled 0.933333 and centred on DP-2,
// and the launched Gamescope went fullscreen on DP-2 at 0,0 2560x1440.
function mirrorDesktop(existing: MirrorWindow[], mode = 'gamescope') {
  const monitor = { name: 'DP-2' };
  const geometryHandlers: (() => void)[] = [];
  const target: MirrorScreen = {
    name: 'Virtual-1',
    geometry: { x: -323, y: 0, width: 3206, height: 1440 },
    geometryChanged: { connect: fn => geometryHandlers.push(fn) },
  };
  const moves: MirrorWindow[] = [];
  const screensHandlers: (() => void)[] = [];
  let onAdded: ((window: MirrorWindow) => void) | undefined;
  const workspace = {
    screens: [monitor, target] as { name: string }[],
    screensChanged: { connect: (fn: () => void) => screensHandlers.push(fn) },
    windowList: () => existing,
    windowAdded: { connect: (handler: (window: MirrorWindow) => void) => { onAdded = handler; } },
    sendClientToScreen: (window: MirrorWindow, screen: MirrorScreen) => {
      moves.push(window);
      window.output = screen;
    },
  };
  vm.runInNewContext(script(mode, 'Virtual-1', true), { workspace });
  return {
    moves,
    target,
    add(window: MirrorWindow) {
      assert.ok(onAdded);
      onAdded(window);
    },
    moveTarget(geometry: Rect) {
      target.geometry = geometry;
      geometryHandlers.forEach(fn => fn());
    },
    removeTarget() {
      workspace.screens = [monitor];
      screensHandlers.forEach(fn => fn());
    },
  };
}

// The script builds rectangles in its own context; compare their values.
const rect = ({ x, y, width, height }: Rect): Rect => ({ x, y, width, height });

function mirrorWindow(pid: number, resourceClass = 'gamescope'): MirrorWindow {
  const handlers: (() => void)[] = [];
  const geometryHandlers: (() => void)[] = [];
  let fullScreen = true;
  let frameGeometry: Rect = { x: 0, y: 0, width: 2560, height: 1440 };
  return {
    pid,
    resourceClass,
    normalWindow: true,
    noBorder: false,
    keepAbove: false,
    get frameGeometry() { return frameGeometry; },
    set frameGeometry(value) {
      frameGeometry = value;
      geometryHandlers.forEach(fn => fn());
    },
    output: { name: 'DP-2' },
    fullScreenChanged: { connect: fn => handlers.push(fn) },
    frameGeometryChanged: { connect: fn => geometryHandlers.push(fn) },
    get fullScreen() { return fullScreen; },
    set fullScreen(value) {
      if (value !== fullScreen) {
        fullScreen = value;
        handlers.forEach(fn => fn());
      }
    },
  };
}

test('in a mirror the launched Gamescope covers the virtual output instead of going fullscreen', () => {
  const local = mirrorWindow(900);
  const streamed = mirrorWindow(42);
  const { moves, target } = mirrorDesktop([local, streamed]);
  assert.equal(moves.length, 0, 'fullscreen through sendClientToScreen would land on DP-2 again');
  assert.equal(streamed.fullScreen, false);
  assert.equal(streamed.noBorder, true);
  assert.equal(streamed.keepAbove, true);
  assert.deepEqual(rect(streamed.frameGeometry), target.geometry);
  assert.equal(local.fullScreen, true, 'a Gamescope Hermes did not start is left alone');
  assert.equal(local.noBorder, false);
  assert.deepEqual(local.frameGeometry, { x: 0, y: 0, width: 2560, height: 1440 });
});

test('in a mirror a Gamescope that asks for fullscreen again is covered again', () => {
  const { target, add } = mirrorDesktop([]);
  const streamed = mirrorWindow(43);
  add(streamed);
  streamed.fullScreen = true;
  assert.equal(streamed.fullScreen, false);
  assert.deepEqual(rect(streamed.frameGeometry), target.geometry);
});

test('in a mirror the covered Gamescope follows the virtual output when it moves', () => {
  const streamed = mirrorWindow(42);
  const { moveTarget } = mirrorDesktop([streamed]);
  // KWin replaying a remembered layout: scale 0.75 at 0,0.
  const replayed = { x: 0, y: 0, width: 3990, height: 1792 };
  moveTarget(replayed);
  assert.deepEqual(rect(streamed.frameGeometry), replayed);
});

test('in a mirror Steam is still placed, never covered', () => {
  const steam = mirrorWindow(900, 'steam');
  const { moves, target } = mirrorDesktop([steam], 'steam');
  assert.deepEqual(moves, [steam]);
  assert.equal(steam.output, target);
  assert.equal(steam.noBorder, false);
  assert.equal(steam.keepAbove, false);
});

test('in a mirror a covered Gamescope that KWin moves below a panel is covered again', () => {
  // Recorded on Haven: after a resume at 1280x720 the window sat at 0,38,
  // clear of DP-2's 38-pixel panel, instead of covering Virtual-1 at 0,0.
  const streamed = mirrorWindow(42);
  const { target } = mirrorDesktop([streamed]);
  streamed.frameGeometry = { x: 0, y: 38, width: 1707, height: 960 };
  assert.deepEqual(rect(streamed.frameGeometry), target.geometry);
});

test('in a mirror the re-covering stops if something keeps moving the window', () => {
  const streamed = mirrorWindow(42);
  mirrorDesktop([streamed]);
  let moves = 0;
  for (let i = 0; i < 50; ++i) {
    streamed.frameGeometry = { x: 0, y: 38, width: 100, height: 100 };
    if (streamed.frameGeometry.y === 38) {
      break;
    }
    moves += 1;
  }
  assert.ok(moves <= 20, `covered again ${moves} times`);
});

test('in a mirror Gamescope gets plain fullscreen back when the virtual output goes', () => {
  const streamed = mirrorWindow(42);
  const { removeTarget } = mirrorDesktop([streamed]);
  removeTarget();
  assert.equal(streamed.fullScreen, true);
  assert.equal(streamed.noBorder, false);
  assert.equal(streamed.keepAbove, false);
  streamed.fullScreen = false;
  streamed.fullScreen = true;
  assert.equal(streamed.fullScreen, true, 'not covered again once the output is gone');
});
