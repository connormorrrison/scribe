/*
 * The card kit: injected into every visualization page at document start, before the page's own scripts.
 * Global `Card`. Keep in step with the description the agent gets (VisualizationTool.cardKit).
 *
 * Talks to the app only through window.webkit.messageHandlers.card: ready, error, focus, resize, paused.
 */
(function () {
  'use strict';
  if (window.Card) return;

  function post(message) {
    try { window.webkit.messageHandlers.card.postMessage(message); } catch (e) { /* not in the app */ }
  }

  // MARK: Errors and ready

  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && (t.src || t.href)) {
      post({ type: 'error', line: 0, message: 'couldn’t load ' + (t.src || t.href) +
        ' (the only files are app://lib/three.min.js and app://lib/d3.min.js; there is no network)' });
      return;
    }
    if (t === window || !t) {
      var m = e.message || (e.error && e.error.message) || 'unknown error';
      post({ type: 'error', message: String(m), line: e.lineno || 0 });
    }
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    post({ type: 'error', message: String((r && r.message) || r || 'unhandled rejection'), line: 0 });
  });
  window.addEventListener('load', function () {
    requestAnimationFrame(function () { requestAnimationFrame(function () { post({ type: 'ready' }); }); });
  });

  // MARK: Pausing

  // The app's Pause button freezes the page's clock: requestAnimationFrame keeps running (so dragging and sliders
  // still redraw), but its timestamps, performance.now() and Date.now() stand still, so anything animated from time
  // stops where it is. Timers wait, and CSS animations pause.
  var paused = false, pausedAt = 0, pausedTotal = 0;
  var realNow = performance.now.bind(performance), realDateNow = Date.now.bind(Date);
  var realRAF = window.requestAnimationFrame.bind(window);
  var realSetTimeout = window.setTimeout.bind(window), realSetInterval = window.setInterval.bind(window);
  function clockNow() { return (paused ? pausedAt : realNow()) - pausedTotal; }
  try { performance.now = clockNow; } catch (e) {}
  Date.now = function () { return realDateNow() - pausedTotal - (paused ? realNow() - pausedAt : 0); };
  window.requestAnimationFrame = function (fn) { return realRAF(function () { fn(clockNow()); }); };
  function whenRunning(fn, args) {
    return function run() {
      if (paused) { realSetTimeout(run, 100); return; }
      if (typeof fn === 'function') fn.apply(window, args);
    };
  }
  window.setTimeout = function (fn, ms) {
    return realSetTimeout(whenRunning(fn, Array.prototype.slice.call(arguments, 2)), ms);
  };
  window.setInterval = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2);
    return realSetInterval(function () { if (!paused && typeof fn === 'function') fn.apply(window, args); }, ms);
  };

  // MARK: One font

  // Everything on the card uses the app's one font, SF Pro Rounded, in regular or semibold. CSS forces it on every
  // element; canvas text gets it here, whatever family the page asks for.
  var FONT = 'ui-rounded, "SF Pro Rounded", -apple-system, system-ui, sans-serif';
  function roundedFont(spec) {
    var m = /^(.*?)(\d*\.?\d+(?:px|pt|em|rem|%))(\s*\/\s*\S+)?\s+.+$/.exec(String(spec).trim());
    if (!m) return spec;
    var lead = m[1].replace(/\b(bold|bolder|[6-9]00)\b/g, '600').replace(/\b(lighter|[1-3]00)\b/g, '400');
    return lead + m[2] + ' ' + FONT;
  }
  try {
    var fontProp = Object.getOwnPropertyDescriptor(CanvasRenderingContext2D.prototype, 'font');
    Object.defineProperty(CanvasRenderingContext2D.prototype, 'font', {
      configurable: true, enumerable: fontProp.enumerable,
      get: function () { return fontProp.get.call(this); },
      set: function (v) { fontProp.set.call(this, roundedFont(v)); }
    });
  } catch (e) {}

  function root() { return document.body || document.documentElement; }
  function clamp(x, a, b) { return Math.min(b, Math.max(a, x)); }

  var Card = {};
  window.Card = Card;

  Card.color = {
    stage: '#0E0E10', curve: '#58C4DD', result: '#FFFF00', second: '#F0AC5F', rise: '#83C167',
    primary: '#FFFFFF', grid: 'rgba(88,196,221,0.12)', axes: 'rgba(255,255,255,0.65)', bond: 'rgba(255,255,255,0.75)',
    flash: '#FFE38A', warn: '#FF9F0A', ok: '#7EE29A', red: '#FF5A5A', muted: 'rgba(255,255,255,0.35)',
    text: 'rgba(255,255,255,0.82)', label: 'rgba(255,255,255,0.72)'
  };

  /** A canvas font in the app's one font: Card.font(14) or Card.font(14, 600). */
  Card.font = function (size, weight) { return (weight >= 600 ? '600 ' : '') + (size || 14) + 'px ' + FONT; };

  /** Pauses or resumes the whole page (the app's Pause button calls this). */
  var resumeTimelines = [];
  Card.setPaused = function (p) {
    p = !!p;
    if (p === paused) return;
    if (p) {
      pausedAt = realNow(); paused = true;
      resumeTimelines = timelines.filter(function (t) { return t.playing; });
      resumeTimelines.forEach(function (t) { t.pause(); });
      try { document.getAnimations().forEach(function (a) { a.pause(); }); } catch (e) {}
    } else {
      pausedTotal += realNow() - pausedAt; paused = false;
      resumeTimelines.forEach(function (t) { t.play(); });
      resumeTimelines = [];
      try { document.getAnimations().forEach(function (a) { a.play(); }); } catch (e) {}
    }
  };
  Object.defineProperty(Card, 'paused', { get: function () { return paused; } });

  Card.ease = function (t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
  Card.lerp = function (a, b, t) { return a + (b - a) * t; };
  Card.clamp = clamp;

  Card.focus = function (id) { post({ type: 'focus', part: String(id) }); };
  /** Asks the app for a taller or shorter card (points, 220–440). */
  Card.resize = function (height) { post({ type: 'resize', height: Number(height) }); };

  // MARK: Resizing

  var resizeFns = [];
  var stages = [];
  Card.onResize = function (fn) { resizeFns.push(fn); };

  function area() {
    var dockHeight = dock ? dock.offsetHeight : 0;
    return { w: window.innerWidth, h: Math.max(0, window.innerHeight - dockHeight) };
  }

  function sizeStage(s) {
    var a = area(), r = window.devicePixelRatio || 1;
    s.width = a.w; s.height = a.h;
    s.canvas.style.width = a.w + 'px';
    s.canvas.style.height = a.h + 'px';
    if (s.ctx) {
      s.canvas.width = Math.max(1, Math.round(a.w * r));
      s.canvas.height = Math.max(1, Math.round(a.h * r));
      s.ctx.setTransform(r, 0, 0, r, 0, 0);
    }
  }

  var resizeQueued = false;
  function layoutChanged() {
    if (resizeQueued) return;
    resizeQueued = true;
    requestAnimationFrame(function () {
      resizeQueued = false;
      var dockHeight = dock ? dock.offsetHeight : 0;
      document.documentElement.style.setProperty('--dock', dockHeight + 'px');
      stages.forEach(sizeStage);
      resizeFns.forEach(function (fn) { fn(); });
    });
  }
  window.addEventListener('resize', layoutChanged);

  // MARK: Stage

  /**
   * A canvas filling the card above the dock. Returns { canvas, ctx, width, height, clear() }: `ctx` is a 2D context
   * already scaled for the screen (null with {webgl: true}); width and height (CSS px) stay current on resize.
   * Pass {canvas: element} to use a canvas of your own.
   */
  Card.stage = function (opts) {
    opts = opts || {};
    var c = opts.canvas || document.createElement('canvas');
    c.style.position = 'fixed'; c.style.left = '0'; c.style.top = '0';
    if (!c.parentNode) root().appendChild(c);
    var s = { canvas: c, ctx: opts.webgl ? null : c.getContext('2d'), width: 0, height: 0 };
    s.clear = function () {
      if (!s.ctx) return;
      s.ctx.fillStyle = Card.color.stage;
      s.ctx.fillRect(0, 0, s.width, s.height);
    };
    stages.push(s);
    sizeStage(s);
    return s;
  };

  // MARK: Dock

  var dock = null, timelineRow = null;
  function ensureDock() {
    if (!dock) {
      dock = document.createElement('div');
      dock.id = 'card-dock';
      root().appendChild(dock);
    }
    return dock;
  }

  /**
   * The readout: a line or two of live values under the drawing, above the controls. Plain text; "\n" (or <br>)
   * starts a second line. An empty string hides it.
   */
  var readoutRow = null;
  Card.readout = function (text) {
    var t = String(text == null ? '' : text).replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]*>/g, '')
      .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').trim();
    if (!readoutRow) {
      if (!t) return;
      readoutRow = document.createElement('div');
      readoutRow.id = 'card-readout';
      var d = ensureDock();
      d.insertBefore(readoutRow, d.firstChild);
    }
    if (readoutRow.textContent === t) return;
    var before = readoutRow.offsetHeight;
    readoutRow.textContent = t;
    readoutRow.style.display = t ? '' : 'none';
    if (readoutRow.offsetHeight !== before) layoutChanged();
  };

  /** A slider in the dock: {label, min, max, value, step, onInput(v), format(v)?}. Returns {value, set(v)}. */
  Card.slider = function (o) {
    var row = document.createElement('div');
    row.className = 'card-slider';
    var label = document.createElement('label');
    label.innerHTML = o.label || '';
    var input = document.createElement('input');
    input.type = 'range';
    input.min = o.min; input.max = o.max; input.step = o.step || (o.max - o.min) / 100;
    input.value = o.value != null ? o.value : o.min;
    var out = document.createElement('output');
    var decimals = Math.max(0, Math.min(4, -Math.floor(Math.log10(Number(input.step) || 1))));
    function show(v) { out.textContent = o.format ? o.format(v) : v.toFixed(decimals); }
    show(Number(input.value));
    row.appendChild(label); row.appendChild(input); row.appendChild(out);
    var d = ensureDock();
    d.insertBefore(row, timelineRow);
    var api = {
      get value() { return Number(input.value); },
      set: function (v) { input.value = v; show(Number(input.value)); }
    };
    input.addEventListener('input', function () {
      Card.takeOver();
      var v = Number(input.value);
      show(v);
      if (o.onInput) o.onInput(v);
    });
    layoutChanged();
    return api;
  };

  /**
   * A row of buttons in the dock, one of which is chosen: {label?, options: ['Sine', 'Cosine'] or [['Sine', 'sin'], …],
   * value, onChange(v)}. Returns {value, set(v)}.
   */
  Card.choice = function (o) {
    var row = document.createElement('div');
    row.className = 'card-buttons';
    if (o.label) {
      var label = document.createElement('label');
      label.innerHTML = o.label;
      row.appendChild(label);
    }
    var options = (o.options || []).map(function (x) { return Array.isArray(x) ? x : [x, x]; });
    var value = o.value != null ? o.value : (options[0] || [])[1];
    var buttons = options.map(function (x) {
      var b = document.createElement('button');
      b.className = 'card-button';
      b.innerHTML = x[0];
      b.addEventListener('click', function () {
        if (value === x[1]) return;
        api.set(x[1]);
        if (o.onChange) o.onChange(x[1]);
      });
      row.appendChild(b);
      return b;
    });
    var api = {
      get value() { return value; },
      set: function (v) {
        value = v;
        buttons.forEach(function (b, i) { b.classList.toggle('on', options[i][1] === v); });
      }
    };
    api.set(value);
    ensureDock().insertBefore(row, timelineRow);
    layoutChanged();
    return api;
  };

  /** An on/off button in the dock (toggles share one row): {label, value, onChange(on)}. Returns {value, set(on)}. */
  var toggleRow = null;
  Card.toggle = function (o) {
    if (!toggleRow) {
      toggleRow = document.createElement('div');
      toggleRow.className = 'card-buttons';
      ensureDock().insertBefore(toggleRow, timelineRow);
    }
    var on = !!o.value;
    var b = document.createElement('button');
    b.className = 'card-button card-toggle';
    b.innerHTML = o.label || '';
    var api = {
      get value() { return on; },
      set: function (v) { on = !!v; b.classList.toggle('on', on); }
    };
    api.set(on);
    b.addEventListener('click', function () {
      api.set(!on);
      if (o.onChange) o.onChange(on);
    });
    toggleRow.appendChild(b);
    layoutChanged();
    return api;
  };

  // MARK: Timeline

  var timelines = [];
  var phaseSpans = null;

  /** Pauses the timeline (and auto-rotation): the student has taken over. */
  Card.takeOver = function () { timelines.forEach(function (t) { t.pause(); }); takenOver = true; };
  var takenOver = false;

  /** Eased progress, 0 to 1, through phase i of the timeline at time t. */
  Card.phase = function (t, i) {
    if (!phaseSpans || !phaseSpans[i]) return Card.ease(t);
    var p = phaseSpans[i];
    return Card.ease((t - p.start) / Math.max(1e-6, p.end - p.start));
  };

  var PLAY = '<svg viewBox="0 0 16 16"><path d="M4 2.5v11l9.5-5.5z"/></svg>';
  var PAUSE = '<svg viewBox="0 0 16 16"><path d="M3.5 2.5h3v11h-3zM9.5 2.5h3v11h-3z"/></svg>';
  var REPLAY = '<svg viewBox="0 0 16 16"><path d="M8 3a5 5 0 1 1-4.6 3h1.7A3.5 3.5 0 1 0 8 4.5V7L4.5 3.75 8 .5z"/></svg>';

  /**
   * The play / scrub bar: {duration (s), phases: [["Label", share], …], onFrame(t), loop?}. Plays once by itself
   * (t 0 → 1). Returns {play(), pause(), seek(t), t}.
   */
  Card.timeline = function (o) {
    var duration = Math.max(0.1, Number(o.duration) || 4);
    var phases = o.phases || [];
    var total = phases.reduce(function (s, p) { return s + Math.max(0, Number(p[1]) || 0); }, 0) || 1;
    var at = 0;
    phaseSpans = phases.map(function (p) {
      var start = at; at += Math.max(0, Number(p[1]) || 0) / total;
      return { label: p[0], start: start, end: at };
    });

    var row = document.createElement('div');
    row.className = 'card-timeline';
    row.innerHTML = '<button class="card-play" aria-label="Play"></button>' +
      '<div class="card-track-wrap"><div class="card-track"><div class="rail"></div><div class="fill"></div>' +
      '<div class="knob"></div></div><div class="card-phases"></div></div>';
    var button = row.querySelector('.card-play');
    var track = row.querySelector('.card-track');
    var fill = row.querySelector('.fill');
    var knob = row.querySelector('.knob');
    var labels = row.querySelector('.card-phases');
    phaseSpans.forEach(function (p) {
      var span = document.createElement('span');
      span.textContent = p.label;
      span.style.left = (p.start * 100) + '%';
      labels.appendChild(span);
    });
    if (!phaseSpans.length) labels.style.display = 'none';
    ensureDock().appendChild(row);
    timelineRow = row;

    var t = 0, playing = true, last = null;
    function render() {
      fill.style.width = (t * 100) + '%';
      knob.style.left = 'calc(' + (t * 100) + '% - ' + (t * 24) + 'px)';
      button.innerHTML = playing ? PAUSE : (t >= 1 ? REPLAY : PLAY);
      button.setAttribute('aria-label', playing ? 'Pause' : 'Play');
      if (o.onFrame) o.onFrame(t);
    }
    function tick(now) {
      if (playing) {
        if (last != null) t += (now - last) / 1000 / duration;
        last = now;
        if (t >= 1) {
          if (o.loop) { t = t % 1; } else { t = 1; playing = false; last = null; }
        }
        render();
      }
      requestAnimationFrame(tick);
    }
    var api = {
      get t() { return t; },
      get playing() { return playing; },
      play: function () { if (t >= 1) t = 0; playing = true; last = null; render(); },
      pause: function () { playing = false; last = null; render(); },
      seek: function (v) { t = clamp(v, 0, 1); render(); }
    };
    timelines.push(api);

    button.addEventListener('click', function () {
      if (playing) { api.pause(); return; }
      // Playing the timeline while the whole card is paused resumes the card too.
      if (paused) { Card.setPaused(false); post({ type: 'paused', value: false }); }
      api.play();
    });
    var dragging = false;
    function scrub(e) {
      var r = track.getBoundingClientRect();
      api.seek((e.clientX - r.left) / Math.max(1, r.width));
    }
    track.parentNode.addEventListener('pointerdown', function (e) {
      dragging = true; Card.takeOver(); scrub(e);
      try { e.target.setPointerCapture(e.pointerId); } catch (x) {}
    });
    window.addEventListener('pointermove', function (e) { if (dragging) scrub(e); });
    window.addEventListener('pointerup', function () { dragging = false; });

    layoutChanged();
    render();
    requestAnimationFrame(tick);
    return api;
  };

  // MARK: 3D

  /**
   * A three.js scene on its own stage, with lights, a camera that orbits its target (drag to turn, pinch to zoom),
   * gentle auto-rotation until the student touches it, and a render loop. Needs
   * <script src="app://lib/three.min.js"></script> before the page's script.
   * Options: {distance: 6, azimuth: 0.6, elevation: 1.1 (radians from straight down the y axis), target: [0,0,0],
   * fov: 45, autoRotate: true, minDistance, maxDistance}.
   * Returns {THREE, scene, camera, renderer, stage, onFrame(fn(dt, elapsed)), label(html, position), orbit}.
   */
  Card.three = function (o) {
    o = o || {};
    var THREE = window.THREE;
    if (!THREE) throw new Error('Card.three() needs <script src="app://lib/three.min.js"></script> before your script');
    var s = Card.stage({ webgl: true });
    var renderer = new THREE.WebGLRenderer({ canvas: s.canvas, antialias: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setClearColor(0x0E0E10, 1);
    renderer.setSize(s.width, s.height, false);

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(o.fov || 45, s.width / Math.max(1, s.height), 0.01, 2000);
    scene.add(new THREE.HemisphereLight(0xffffff, 0x223344, 0.55));
    var sun = new THREE.DirectionalLight(0xffffff, 0.7);
    sun.position.set(3, 5, 4);
    scene.add(sun);

    var t0 = o.target || [0, 0, 0];
    var orbit = {
      target: new THREE.Vector3(t0[0], t0[1], t0[2]),
      distance: o.distance || 6,
      azimuth: o.azimuth != null ? o.azimuth : 0.6,
      elevation: o.elevation != null ? o.elevation : 1.1,
      autoRotate: o.autoRotate !== false,
      speed: o.rotateSpeed || 0.25,
      minDistance: o.minDistance || 0.5,
      maxDistance: o.maxDistance || 200
    };
    function place() {
      var r = orbit.distance, th = orbit.azimuth, ph = orbit.elevation;
      camera.position.set(orbit.target.x + r * Math.sin(ph) * Math.sin(th),
                          orbit.target.y + r * Math.cos(ph),
                          orbit.target.z + r * Math.sin(ph) * Math.cos(th));
      camera.lookAt(orbit.target);
    }

    // Drag to orbit, pinch to zoom.
    var pointers = {}, pinch = null;
    function count() { return Object.keys(pointers).length; }
    function spread() {
      var p = Object.keys(pointers).map(function (k) { return pointers[k]; });
      return Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
    }
    s.canvas.addEventListener('pointerdown', function (e) {
      pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
      try { s.canvas.setPointerCapture(e.pointerId); } catch (x) {}
      orbit.autoRotate = false;
      Card.takeOver();
      if (count() === 2) pinch = spread();
    });
    s.canvas.addEventListener('pointermove', function (e) {
      var p = pointers[e.pointerId];
      if (!p) return;
      var dx = e.clientX - p.x, dy = e.clientY - p.y;
      p.x = e.clientX; p.y = e.clientY;
      if (count() === 1) {
        orbit.azimuth -= dx * 0.008;
        orbit.elevation = clamp(orbit.elevation - dy * 0.008, 0.05, Math.PI - 0.05);
      } else if (count() === 2 && pinch) {
        var now = spread();
        orbit.distance = clamp(orbit.distance * pinch / Math.max(1, now), orbit.minDistance, orbit.maxDistance);
        pinch = now;
      }
    });
    function lift(e) { delete pointers[e.pointerId]; if (count() < 2) pinch = null; }
    s.canvas.addEventListener('pointerup', lift);
    s.canvas.addEventListener('pointercancel', lift);

    // HTML labels pinned to points in the scene.
    var labels = [];
    function label(html, position, opts) {
      var el = document.createElement('div');
      el.className = 'card-label';
      el.innerHTML = html;
      if (opts && opts.color) el.style.color = opts.color;
      root().appendChild(el);
      var entry = { el: el, position: position };
      labels.push(entry);
      return el;
    }
    var v = new THREE.Vector3();
    function placeLabels() {
      for (var i = 0; i < labels.length; i++) {
        var l = labels[i], p = l.position;
        if (p && p.isObject3D) p.getWorldPosition(v);
        else if (Array.isArray(p)) v.set(p[0], p[1], p[2]);
        else if (p) v.copy(p);
        v.project(camera);
        var hidden = v.z > 1 || !l.el.isConnected;
        l.el.style.display = hidden ? 'none' : '';
        l.el.style.left = ((v.x + 1) / 2 * s.width) + 'px';
        l.el.style.top = ((1 - v.y) / 2 * s.height) + 'px';
      }
    }

    Card.onResize(function () {
      renderer.setSize(s.width, s.height, false);
      camera.aspect = s.width / Math.max(1, s.height);
      camera.updateProjectionMatrix();
    });

    var frameFns = [], last = null, elapsed = 0;
    function loop(now) {
      var dt = last == null ? 0 : Math.min(0.1, (now - last) / 1000);
      last = now; elapsed += dt;
      if (orbit.autoRotate) orbit.azimuth += dt * orbit.speed;
      place();
      for (var i = 0; i < frameFns.length; i++) frameFns[i](dt, elapsed);
      renderer.render(scene, camera);
      placeLabels();
      requestAnimationFrame(loop);
    }
    place();
    requestAnimationFrame(loop);

    return {
      THREE: THREE, scene: scene, camera: camera, renderer: renderer, stage: s, orbit: orbit,
      onFrame: function (fn) { frameFns.push(fn); },
      label: label
    };
  };
})();
