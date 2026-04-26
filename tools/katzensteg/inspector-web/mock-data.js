// Live data adapter for Katzensteg inspector.
// Keeps the rich mock-shaped UI fed from current inspector endpoints, with
// graceful fallback placeholders where backend data is not yet exposed.

(function () {
  const demo = {
    session: {
      session_id: 'live-session',
      terminal: { identity: 'unknown', graphics_basic: 'unknown', file_whole: 'unknown', file_offset: 'unknown' },
      config: { intercept_mode: 'unknown', composite_mode: 'unknown', output_profile: 'unknown', present_fps: 0, max_queue_depth: 32, drop_stale_batches: true },
      engine: { name: 'katzensteg', version: 'dev' },
      app: { name: 'unknown' },
      active_segment_id: 0,
      segments: [],
    },
    frames: [],
    textures: [],
    kitty_images: [],
    placements: [],
    events: [],
    stats: { frames: 0, uploads_total: 0, placements_total: 0, bytes_uploaded: 0, avg_present_ms: 0, skipped_presents: 0, dropped_batches: 0, composite_frames: 0, sprite_frames: 0, tiled_frames: 0 },
    connection: {
      state: 'connecting',
      error: null,
      last_ok_ms: 0,
      last_attempt_ms: 0,
      failures: 0,
    },
    FOCUS_ID: 0,
  };

  window.MockData = demo;

  async function fetchJson(path) {
    const res = await fetch(`/inspect${path}`);
    if (!res.ok) throw new Error(`${path}: ${res.status}`);
    return await res.json();
  }

  function fmtStrategy(status) {
    if (status?.composite_mode === 'fullscreen') return { render_strategy: 'fullscreen_composite', strategy_short: 'composite' };
    if (status?.composite_mode === 'tiled_strip') return { render_strategy: 'tiled_strip', strategy_short: 'tiled' };
    return { render_strategy: 'sprite', strategy_short: 'sprite' };
  }

  function textureNickname(key) {
    return `texture ${String(key).slice(-6)}`;
  }

  function blendName(v) {
    if (typeof v === 'string') return v;
    if (v === 0) return 'none';
    if (v === 1) return 'blend';
    if (v === 2) return 'add';
    if (v === 4) return 'mod';
    if (v === 8) return 'mul';
    return String(v ?? 'unknown');
  }

  function makeTexturesFromEvents(events) {
    const map = new Map();
    for (const ev of events || []) {
      const payload = ev.payload || {};
      const key = payload.texture_key;
      if (!key) continue;
      if (!map.has(key)) {
        map.set(key, {
          texture_key: key,
          nickname: textureNickname(key),
          size: payload.rect ? [payload.rect[2] || 0, payload.rect[3] || 0] : [0, 0],
          format: payload.format || 'unknown',
          blend_mode: payload.blend_mode || 'unknown',
          color_mod: payload.color_mod || [255, 255, 255],
          alpha_mod: payload.alpha_mod || 255,
          last_updated_frame: ev.frame_id || 0,
          update_count: 0,
          bytes: payload.bytes || 0,
          access: payload.access || 'unknown',
        });
      }
      const t = map.get(key);
      if (ev.kind === 'update_texture') {
        t.update_count += 1;
        t.last_updated_frame = ev.frame_id || t.last_updated_frame;
        if (payload.rect) t.size = [payload.rect[2] || t.size[0], payload.rect[3] || t.size[1]];
        if (payload.bytes) t.bytes = payload.bytes;
      }
      if (ev.kind === 'set_texture_blend_mode' && payload.blend_mode) t.blend_mode = payload.blend_mode;
    }
    return [...map.values()];
  }

  function makeKittyImagesFromEvents(events) {
    return (events || [])
      .filter(ev => ev.kind === 'upload')
      .map(ev => ({
        image_id: ev.payload?.image_id ?? 0,
        source: 'composite_fullscreen',
        size: [ev.payload?.w ?? 0, ev.payload?.h ?? 0],
        uploaded_frame: ev.frame_id ?? 0,
        transport: ev.payload?.transport ?? 'unknown',
        bytes: ev.payload?.bytes ?? 0,
        from_texture_keys: [],
      }));
  }

  function makePlacementsFromEvents(events) {
    return (events || [])
      .filter(ev => ev.kind === 'placement')
      .map(ev => ({
        placement_id: ev.payload?.placement_id ?? 0,
        image_id: ev.payload?.image_id ?? 0,
        src_rect: ev.payload?.src_rect ?? [0, 0, 0, 0],
        dest_cells: ev.payload?.dest_cells ?? [0, 0, 0, 0],
        frame: ev.frame_id ?? 0,
      }));
  }

  function deriveFrameMetrics(frames, latest, status) {
    const fallbackStrategy = fmtStrategy(status);
    return frames.map((f, idx) => ({
      id: f.id,
      ts_ns: f.ts_ns || 0,
      ts_s: (f.ts_ns || 0) / 1e9,
      present_ns: f.present_ns || 0,
      queue_depth: f.queue_depth || 0,
      skipped_presents: f.skipped_presents || 0,
      dropped_frame_batches: 0,
      render_strategy: f.render_strategy || fallbackStrategy.render_strategy,
      strategy_short: f.strategy_short || fallbackStrategy.strategy_short,
      fallback_reasons: Array.isArray(f.fallback_reasons) ? f.fallback_reasons : [],
      counts: { copies: 0, fills: 0, lines: 0, points: 0, clears: 0, uploads: 0, placements: 0, ...(f.counts || {}) },
      bytes: { uploaded: 0, ...(f.bytes || {}) },
      timing: { producer_ns: 0, replay_ns: 0, compose_ns: 0, emit_ns: f.present_ns || 0, ...(f.timing || {}) },
      regime: idx >= frames.length - 1 ? 'latest' : 'captured',
    }));
  }

  function makeTexturesFromResources(resources) {
    return (resources || []).filter(r => !r.kind || r.kind === 'texture').map((r) => ({
      texture_key: r.texture_key || '0x0',
      nickname: r.alias || textureNickname(r.texture_key || '0x0'),
      size: Array.isArray(r.size) ? r.size : [0, 0],
      format: r.format ?? 'unknown',
      blend_mode: blendName(r.blend_mode),
      color_mod: [255, 255, 255],
      alpha_mod: 255,
      last_updated_frame: 0,
      update_count: r.update_count || 0,
      bytes: 0,
      access: 'unknown',
      image_id: r.image_id || 0,
    }));
  }

  function makeKittyImagesFromResources(resources, status, latest) {
    const uploadedFrame = latest && latest.id ? latest.id : 0;
    const seen = new Set();
    return (resources || [])
      .filter(r => r && r.kind === 'image' && r.image_id)
      .filter(r => {
        if (seen.has(r.image_id)) return false;
        seen.add(r.image_id);
        return true;
      })
      .map((r) => ({
        image_id: r.image_id,
        source: status?.composite_mode === 'fullscreen' ? 'composite_fullscreen' : status?.composite_mode === 'tiled_strip' ? 'composite_tile' : 'sprite',
        size: Array.isArray(r.size) ? r.size : [0, 0],
        uploaded_frame: uploadedFrame,
        transport: status?.output_profile || 'unknown',
        bytes: 0,
        from_texture_keys: r.texture_key ? [r.texture_key] : [],
      }));
  }

  function makePlacementsFromResources(resources, latest) {
    const frameId = latest && latest.id ? latest.id : 0;
    return (resources || [])
      .filter(r => r && r.kind === 'placement' && r.image_id && r.placement_id)
      .map((r) => ({
        placement_id: r.placement_id,
        image_id: r.image_id,
        src_rect: [0, 0, ...(Array.isArray(r.size) ? r.size : [0, 0])],
        dest_cells: [0, 0, 0, 0],
        frame: frameId,
      }));
  }

  async function refresh() {
    try {
      const status = await fetchJson('/capture/status');
      const segments = await fetchJson('/segments');
      const preferredSegmentId = Number(window.KatzenstegSelectedSegmentId || 0);
      const activeSegmentId = (preferredSegmentId && segments.some(s => s.id === preferredSegmentId))
        ? preferredSegmentId
        : (status.active_segment_id || (segments.length ? (segments.find(s => s.active) || segments[segments.length - 1]).id : 0));
      const [framesRaw, latest] = activeSegmentId ? await Promise.all([
        fetchJson(`/frames?segment=${activeSegmentId}`),
        fetchJson(`/frame/latest?segment=${activeSegmentId}`),
      ]) : [[], null];

      const frames = deriveFrameMetrics(framesRaw || [], latest, status);
      const preferredFrameId = Number(window.KatzenstegSelectedFrameId || 0);
      const focus = (preferredFrameId && frames.some(f => f.id === preferredFrameId))
        ? preferredFrameId
        : (latest && latest.id ? latest.id : (frames.length ? frames[frames.length - 1].id : 0));
      const focusedFrame = focus ? await fetchJson(`/frame/${focus}`) : null;
      const resources = focus ? await fetchJson(`/resources?frame=${focus}`) : [];

      const session = {
        session_id: `live-${activeSegmentId || focus || 0}`,
        terminal: {
          identity: status.terminal_identity || 'live',
          graphics_basic: 'supported',
          file_whole: 'unknown',
          file_offset: 'unknown',
        },
        config: {
          intercept_mode: status.intercept_mode || 'unknown',
          composite_mode: status.composite_mode || 'unknown',
          output_profile: status.output_profile || 'unknown',
          present_fps: status.present_fps || 0,
          max_queue_depth: 32,
          drop_stale_batches: true,
        },
        engine: { name: 'katzensteg', version: 'live' },
        app: { name: 'captured app' },
        active_segment_id: activeSegmentId || 0,
        segments,
      };

      const events = focusedFrame && focusedFrame.events ? focusedFrame.events : [];
      const resourceTextures = makeTexturesFromResources(resources);
      const eventTextures = makeTexturesFromEvents(events);
      const textures = resourceTextures.length ? resourceTextures.map((rt) => {
        const et = eventTextures.find(t => t.texture_key === rt.texture_key);
        return et ? { ...rt, ...et, nickname: rt.nickname || et.nickname, image_id: rt.image_id || et.image_id || 0 } : rt;
      }) : eventTextures;
      const kitty_images = resources && resources.length ? makeKittyImagesFromResources(resources, status, latest) : makeKittyImagesFromEvents(events);
      const placements = resources && resources.length ? makePlacementsFromResources(resources, latest) : makePlacementsFromEvents(events);

      // Decorate the focused frame with any available richer info from /frame/<id>
      const latestFrame = frames.find(f => f.id === focus);
      if (latestFrame && focusedFrame && typeof focusedFrame === 'object') {
        latestFrame.present_ns = focusedFrame.present_ns || latestFrame.present_ns;
        latestFrame.queue_depth = focusedFrame.queue_depth || latestFrame.queue_depth;
        latestFrame.skipped_presents = focusedFrame.skipped_presents || latestFrame.skipped_presents;
        if (focusedFrame.fallback_reasons) latestFrame.fallback_reasons = focusedFrame.fallback_reasons;
        if (focusedFrame.counts) latestFrame.counts = { ...latestFrame.counts, ...focusedFrame.counts };
        if (focusedFrame.bytes) latestFrame.bytes = { ...latestFrame.bytes, ...focusedFrame.bytes };
        if (focusedFrame.timing) latestFrame.timing = { ...latestFrame.timing, ...focusedFrame.timing };
        if (focusedFrame.render_strategy) latestFrame.render_strategy = focusedFrame.render_strategy;
        if (focusedFrame.strategy_short) latestFrame.strategy_short = focusedFrame.strategy_short;
        latestFrame.resource_refs = Array.isArray(focusedFrame.resource_refs) ? focusedFrame.resource_refs : [];
        latestFrame.mappings = Array.isArray(focusedFrame.mappings) ? focusedFrame.mappings : [];
      }

      const focusedEvents = focusedFrame && Array.isArray(focusedFrame.events) ? focusedFrame.events : [];
      const eventsForUi = focusedEvents.length ? focusedEvents : (() => {
        const synthetic = [];
        if (focusedFrame && focusedFrame.image_id) {
          synthetic.push({ kind: 'upload', thread: 'worker', ts_ns: focusedFrame.ts_ns || 0, payload: { image_id: focusedFrame.image_id, bytes: focusedFrame?.bytes?.uploaded || 0 } });
        }
        if (focusedFrame && focusedFrame.image_id && focusedFrame.placement_id) {
          synthetic.push({ kind: 'placement', thread: 'worker', ts_ns: focusedFrame.ts_ns || 0, payload: { image_id: focusedFrame.image_id, placement_id: focusedFrame.placement_id } });
        }
        if (latestFrame && Array.isArray(latestFrame.fallback_reasons)) {
          for (const reason of latestFrame.fallback_reasons) {
            synthetic.push({ kind: 'fallback', thread: 'worker', ts_ns: focusedFrame?.ts_ns || 0, payload: reason || {} });
          }
        }
        return synthetic;
      })();

      const stats = {
        frames: frames.length,
        uploads_total: frames.reduce((a, f) => a + (f.counts.uploads || 0), 0),
        placements_total: frames.reduce((a, f) => a + (f.counts.placements || 0), 0),
        bytes_uploaded: frames.reduce((a, f) => a + (f.bytes.uploaded || 0), 0),
        avg_present_ms: frames.length ? frames.reduce((a, f) => a + (f.present_ns || 0), 0) / frames.length / 1e6 : 0,
        skipped_presents: frames.reduce((a, f) => a + (f.skipped_presents || 0), 0),
        dropped_batches: frames.reduce((a, f) => a + (f.dropped_frame_batches || 0), 0),
        composite_frames: frames.filter(f => f.strategy_short === 'composite').length,
        sprite_frames: frames.filter(f => f.strategy_short === 'sprite').length,
        tiled_frames: frames.filter(f => f.strategy_short === 'tiled').length,
      };

      if (latestFrame && latestFrame.fallback_reasons.length) {
        for (const reason of latestFrame.fallback_reasons) {
          const tex = textures.find(t => t.texture_key === reason.texture_key);
          if (tex) tex.last_updated_frame = latestFrame.id;
        }
      }

      window.MockData = {
        session,
        frames,
        textures,
        kitty_images,
        placements,
        events: eventsForUi,
        stats,
        connection: {
          state: 'connected',
          error: null,
          last_ok_ms: Date.now(),
          last_attempt_ms: Date.now(),
          failures: 0,
        },
        FOCUS_ID: focus,
      };
      window.dispatchEvent(new Event('katzensteg-data'));
    } catch (err) {
      const prev = window.MockData || demo;
      console.error('katzensteg inspector refresh failed', err);
      window.MockData = {
        ...prev,
        connection: {
          state: prev.connection && prev.connection.last_ok_ms ? 'disconnected' : 'connecting',
          error: String(err && err.message || err),
          last_ok_ms: prev.connection ? prev.connection.last_ok_ms : 0,
          last_attempt_ms: Date.now(),
          failures: (prev.connection ? prev.connection.failures : 0) + 1,
        },
      };
      window.dispatchEvent(new Event('katzensteg-data'));
    }
  }

  window.KatzenstegInspectorRefresh = refresh;
  refresh();
  setInterval(refresh, 1000);
})();
