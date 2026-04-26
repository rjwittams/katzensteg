// app.jsx — the session bar + main shell + main entry.

(function () {
  const { useState, useMemo, useEffect, useCallback } = React;
  const { Logo } = window.Sprites;
  const { FrameDetail, BridgeView, ResourceInspector, EventLog } = window.Panels;
  const { Timeline } = window;
  const {
    useTweaks,
    TweaksPanel,
    TweakSection,
    TweakToggle,
    TweakRadio,
  } = window;

  const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
    "density": "compact",
    "live": false,
    "accent": "orange",
    "showEventLog": true,
    "tracks": {
      "frames": true,
      "queue": true,
      "upload": true,
      "thread": true,
      "strat": true,
      "markers": true
    },
    "rightTopTab": "bridge",
    "rightBottomTab": "resources"
  }/*EDITMODE-END*/;

  function fmtAge(ms) {
    if (!ms) return 'never';
    const delta = Math.max(0, Date.now() - ms);
    if (delta < 1000) return 'just now';
    if (delta < 60000) return `${Math.floor(delta / 1000)}s ago`;
    return `${Math.floor(delta / 60000)}m ago`;
  }

  function ConnectionBanner({ connection, onRetry }) {
    if (!connection || connection.state === 'connected') return null;
    const title = connection.state === 'connecting' ? 'Inspector backend connecting…' : 'Inspector backend disconnected';
    const detail = connection.last_ok_ms
      ? `Last successful refresh ${fmtAge(connection.last_ok_ms)}.`
      : 'No successful refresh yet.';
    return (
      <div className={`connection-banner ${connection.state}`}>
        <div className="row" style={{ gap: 10 }}>
          <span className={`dot ${connection.state === 'disconnected' ? 'warn' : ''}`} style={{ background: connection.state === 'disconnected' ? 'var(--yellow)' : 'var(--blue)' }} />
          <div className="col" style={{ gap: 2 }}>
            <div style={{ color: 'var(--fg-0)' }}>{title}</div>
            <div className="muted" style={{ fontSize: 'var(--fs-xs)' }}>{detail} {connection.error ? `Error: ${connection.error}` : ''}</div>
          </div>
          <span className="grow" />
          <button className="btn sm" onClick={onRetry}>retry</button>
        </div>
      </div>
    );
  }

  function SessionBar({ session, stats, live, onToggleLive, capture, onToggleCapture, connection, selectedSegmentId, onSelectSegment }) {
    return (
      <div className="session-bar">
        <div className="logo"><Logo size={22}/><b>Katzensteg</b><small className="ui">inspector</small></div>
        <div style={{ width: 1, height: 22, background: "var(--line)" }}/>
        <span className="prompt-chip" title="Session ID"><span className="lbl">sess</span><span className="val tnum">{session.session_id.slice(-5)}</span></span>
        <span className="prompt-chip" title="Terminal"><span className="lbl">term</span><span className="val">{session.terminal.identity}</span></span>
        <span className="prompt-chip" title="Output profile"><span className="lbl">out</span><span className="val" style={{ color: "var(--cyan)" }}>{session.config.output_profile}</span></span>
        <span className="prompt-chip" title="Composite mode"><span className="lbl">composite</span><span className="val" style={{ color: "var(--accent)" }}>{session.config.composite_mode}</span></span>
        <span className="prompt-chip" title="Intercept mode"><span className="lbl">intercept</span><span className="val">{session.config.intercept_mode}</span></span>
        <span className="prompt-chip" title="Segment"><span className="lbl">segment</span><span className="val tnum">{selectedSegmentId || '—'}</span></span>
        <span className="grow"/>
        <span className="muted" style={{ fontSize: "var(--fs-xs)" }}>queue health</span>
        <QueueHealthBar stats={stats}/>
        <span className="muted tnum" style={{ fontSize: "var(--fs-xs)" }}>{stats.frames} frames · {(stats.bytes_uploaded/1024/1024).toFixed(1)}MB</span>
        <div style={{ width: 1, height: 22, background: "var(--line)" }}/>
        {connection?.state !== 'connected' && (
          <span className={`pill ${connection.state === 'disconnected' ? 'yellow' : 'blue'}`}>
            <span className="dot"/>{connection.state}
          </span>
        )}
        <button className="btn sm" data-active={live ? "1" : undefined} onClick={onToggleLive}>
          <span className={"dot " + (live ? "live" : "")}/>{live ? "live" : "paused"}
        </button>
        <button className={"btn sm " + (capture ? "primary" : "")} onClick={onToggleCapture}>
          {capture ? "■ stop" : "● capture"}
        </button>
        <button className="btn sm ghost" title="Clear" onClick={() => window.KatzenstegInspectorRefresh && fetch('/inspect/capture/clear').then(() => window.KatzenstegInspectorRefresh())}>clear</button>
        <button className="btn sm ghost" title="Settings">⚙</button>
      </div>
    );
  }

  function QueueHealthBar({ stats }) {
    // 24 mini bars showing queue distribution (mocked from stats)
    const bars = [];
    for (let i = 0; i < 24; i++) {
      const v = 0.3 + 0.7 * Math.abs(Math.sin(i * 0.41 + stats.frames * 0.01));
      const color = v > 0.8 ? "var(--red)" : v > 0.6 ? "var(--yellow)" : "var(--green)";
      bars.push(<i key={i} style={{ display: "inline-block", width: 2, height: 4 + v * 10, background: color, marginRight: 1, verticalAlign: "middle" }}/>);
    }
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 0 }}>{bars}</span>;
  }

  class ErrorBoundary extends React.Component {
    constructor(props) {
      super(props);
      this.state = { error: null };
    }
    static getDerivedStateFromError(error) {
      return { error };
    }
    componentDidCatch(error, info) {
      console.error('katzensteg inspector render error', error, info);
    }
    render() {
      if (this.state.error) {
        return (
          <div style={{ padding: 16, color: 'var(--fg-0)', fontFamily: 'var(--font-mono)' }}>
            <div style={{ color: 'var(--red)', marginBottom: 8 }}>Inspector render error</div>
            <pre style={{ whiteSpace: 'pre-wrap', color: 'var(--fg-1)' }}>{String(this.state.error && this.state.error.stack || this.state.error)}</pre>
          </div>
        );
      }
      return this.props.children;
    }
  }

  function App() {
    const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
    const [data, setData] = useState(window.MockData);
    const { session, frames, textures, kitty_images, placements, events, stats, connection, FOCUS_ID } = data;
    const [selectedId, setSelectedId] = useState(FOCUS_ID);
    const [selectedSegmentId, setSelectedSegmentId] = useState(session.active_segment_id || 0);

    useEffect(() => {
      const onUpdate = () => setData({ ...window.MockData });
      window.addEventListener("katzensteg-data", onUpdate);
      return () => window.removeEventListener("katzensteg-data", onUpdate);
    }, []);

    useEffect(() => {
      if (!frames.some(f => f.id === selectedId)) {
        setSelectedId(FOCUS_ID);
        window.KatzenstegSelectedFrameId = FOCUS_ID || 0;
      }
    }, [frames, selectedId, FOCUS_ID]);

    useEffect(() => {
      const nextSegmentId = session.active_segment_id || (Array.isArray(session.segments) && session.segments.length ? session.segments[session.segments.length - 1].id : 0);
      if (!selectedSegmentId || !(Array.isArray(session.segments) && session.segments.some(s => s.id === selectedSegmentId))) {
        setSelectedSegmentId(nextSegmentId || 0);
        window.KatzenstegSelectedSegmentId = nextSegmentId || 0;
      }
    }, [session.active_segment_id, session.segments, selectedSegmentId]);
    const [hoverFrame, setHoverFrame] = useState(null);
    const [selectedRes, setSelectedRes] = useState(null);
    const [resMode, setResMode] = useState("tex");
    const [capture, setCapture] = useState(false);

    // Apply density to root
    useEffect(() => { document.documentElement.setAttribute("data-density", t.density); }, [t.density]);

    const selectedFrame = frames.find(f => f.id === selectedId) || null;

    useEffect(() => {
      fetch('/inspect/capture/status')
        .then(r => r.json())
        .then(s => setCapture(!!s.enabled))
        .catch(() => {});
    }, [data]);

    const callInspect = useCallback(async (path) => {
      await fetch(`/inspect${path}`);
      if (window.KatzenstegInspectorRefresh) await window.KatzenstegInspectorRefresh();
    }, []);

    const handleSelectSegment = useCallback(async (segmentId) => {
      window.KatzenstegSelectedSegmentId = segmentId;
      window.KatzenstegSelectedFrameId = 0;
      setSelectedSegmentId(segmentId);
      setSelectedId(0);
      setSelectedRes(null);
      if (window.KatzenstegInspectorRefresh) await window.KatzenstegInspectorRefresh();
    }, []);

    const handleSelectFrame = useCallback((frameId) => {
      window.KatzenstegSelectedFrameId = frameId || 0;
      setSelectedId(frameId || 0);
    }, []);

    // Auto-advance in live mode
    useEffect(() => {
      if (!t.live) return;
      const h = setInterval(() => {
        if (!frames.length) return;
        const idx = frames.findIndex(f => f.id === window.KatzenstegSelectedFrameId);
        const nextId = idx < 0 ? frames[frames.length - 1].id : frames[Math.min(idx + 1, frames.length - 1)].id;
        handleSelectFrame(nextId);
      }, 900);
      return () => clearInterval(h);
    }, [t.live, frames, handleSelectFrame]);

    const handleSelectResource = useCallback((arg1, arg2) => {
      if (typeof arg1 === "string") setSelectedRes({ kind: arg1, key: arg2 });
      else setSelectedRes(arg1);
      if (arg1?.kind === "texture" || arg1 === "texture") setResMode("tex");
      if (arg1?.kind === "image" || arg1 === "image") setResMode("img");
      if (arg1?.kind === "placement" || arg1 === "placement") setResMode("plc");
    }, []);

    // Keyboard: arrows change frame
    useEffect(() => {
      const onKey = (e) => {
        if (e.target && /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
        if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && frames.length) {
          e.preventDefault();
          const idx = frames.findIndex(f => f.id === selectedId);
          const safeIdx = idx < 0 ? frames.length - 1 : idx;
          const ni = e.key === "ArrowLeft" ? Math.max(0, safeIdx - 1) : Math.min(frames.length - 1, safeIdx + 1);
          handleSelectFrame(frames[ni].id);
        }
        if (e.key === " ") { e.preventDefault(); setTweak("live", !t.live); }
      };
      window.addEventListener("keydown", onKey);
      return () => window.removeEventListener("keydown", onKey);
    }, [selectedId, frames, t.live, setTweak, handleSelectFrame]);

    return (
      <div className="app">
        <SessionBar session={session} stats={stats} live={t.live} capture={capture} connection={connection}
                    selectedSegmentId={selectedSegmentId}
                    onSelectSegment={handleSelectSegment}
                    onToggleLive={() => setTweak("live", !t.live)}
                    onToggleCapture={() => callInspect(capture ? "/capture/stop" : "/capture/start")} />
        <div className="body">
          <ConnectionBanner connection={connection} onRetry={() => window.KatzenstegInspectorRefresh && window.KatzenstegInspectorRefresh()} />
          <div className="segment-strip">
            <div className="segment-strip-inner">
              <span className="caps">Capture segments</span>
              {(Array.isArray(session.segments) ? session.segments : []).map((seg) => (
                <button key={seg.id} className="btn sm"
                        data-active={selectedSegmentId === seg.id ? "1" : undefined}
                        onClick={() => handleSelectSegment(seg.id)}>
                  #{seg.id} · {seg.frame_count || 0}f{seg.active ? ' · live' : ''}
                </button>
              ))}
              {(!Array.isArray(session.segments) || session.segments.length === 0) && <span className="muted" style={{ fontSize: 'var(--fs-xs)' }}>no segments yet</span>}
            </div>
          </div>
          <div className="timeline-region">
            <Timeline frames={frames} selectedId={selectedId} onSelect={handleSelectFrame}
                      onHover={setHoverFrame} live={t.live} tracks={t.tracks}/>
          </div>

          <div className="quadrants">
            <div className="left-col">
              <div className="panel-hd">
                <b>Frame</b>
                <span className="muted">#{selectedFrame?.id}</span>
                <span className="grow"/>
                <span className="kbd">←</span><span className="kbd">→</span>
                <span className="hint">navigate</span>
                <span className="kbd">Space</span>
                <span className="hint">{t.live ? "pause" : "play"}</span>
              </div>
              <FrameDetail frame={selectedFrame} frames={frames} textures={textures}
                           onSelectResource={handleSelectResource} onSelectFrame={handleSelectFrame}/>
            </div>

            <div className="right-col">
              <div className="r-top panel">
                <div className="panel-hd">
                  <div className="tabs">
                    <button data-active={t.rightTopTab === "bridge" ? "1" : undefined} onClick={() => setTweak("rightTopTab", "bridge")}>🐾 Bridge</button>
                    <button data-active={t.rightTopTab === "frameview" ? "1" : undefined} onClick={() => setTweak("rightTopTab", "frameview")}>Frame view</button>
                    <button data-active={t.rightTopTab === "mapping" ? "1" : undefined} onClick={() => setTweak("rightTopTab", "mapping")}>Mapping table</button>
                  </div>
                  <span className="grow"/>
                  <span className="pill ghost" title="Selected frame"><span className="dot" style={{ background: "var(--accent)" }}/>#{selectedFrame?.id}</span>
                </div>
                {!selectedFrame ? (
                  <div className="panel-bd" style={{ padding: 16, color: "var(--fg-2)" }}>No captured frame yet. Start capture and present a frame.</div>
                ) : (
                  <>
                    {t.rightTopTab === "bridge" && (
                      <BridgeView frame={selectedFrame} textures={textures}
                                  kittyImages={kitty_images} placements={placements}
                                  selectedRes={selectedRes} onSelectResource={setSelectedRes}/>
                    )}
                    {t.rightTopTab === "frameview" && <FrameView frame={selectedFrame}/>}
                    {t.rightTopTab === "mapping" && <MappingTable frame={selectedFrame} textures={textures} kittyImages={kitty_images} placements={placements}/>} 
                  </>
                )}
              </div>

              <div className="r-bottom panel">
                <div className="panel-hd">
                  <div className="tabs">
                    <button data-active={t.rightBottomTab === "resources" ? "1" : undefined} onClick={() => setTweak("rightBottomTab", "resources")}>Resources</button>
                    <button data-active={t.rightBottomTab === "events" ? "1" : undefined} onClick={() => setTweak("rightBottomTab", "events")}>Events</button>
                    <button data-active={t.rightBottomTab === "config" ? "1" : undefined} onClick={() => setTweak("rightBottomTab", "config")}>Config</button>
                  </div>
                  <span className="grow"/>
                </div>
                {t.rightBottomTab === "resources" && (
                  <ResourceInspector textures={textures} kittyImages={kitty_images} placements={placements}
                                     selectedRes={selectedRes} onSelectResource={setSelectedRes}
                                     mode={resMode} onChangeMode={setResMode}
                                     selectedFrameId={selectedId}/>
                )}
                {t.rightBottomTab === "events" && <EventLog events={events} selectedFrameId={selectedId}/>}
                {t.rightBottomTab === "config" && <ConfigPane session={session}/>}
              </div>
            </div>
          </div>
        </div>

        <TweaksPanel title="Inspector Tweaks">
          <TweakSection label="Density" />
          <TweakRadio label="Info density" value={t.density} options={["comfy", "compact", "dense"]}
                      onChange={(v) => setTweak("density", v)} />
          <TweakSection label="Mode" />
          <TweakToggle label="Live follow-latest" value={t.live} onChange={(v) => setTweak("live", v)} />
          <TweakSection label="Timeline tracks" />
          {Object.entries({frames:"Frame duration",queue:"Queue depth",upload:"Upload bytes",thread:"Thread breakdown",strat:"Strategy ribbon",markers:"Event markers"}).map(([k, label]) => (
            <TweakToggle key={k} label={label} value={t.tracks[k]}
                         onChange={(v) => setTweak("tracks", { ...t.tracks, [k]: v })}/>
          ))}
          <TweakSection label="Panels" />
          <TweakRadio label="Right-top" value={t.rightTopTab} options={["bridge","frameview","mapping"]} onChange={(v)=>setTweak("rightTopTab",v)}/>
          <TweakRadio label="Right-bottom" value={t.rightBottomTab} options={["resources","events","config"]} onChange={(v)=>setTweak("rightBottomTab",v)}/>
        </TweaksPanel>
      </div>
    );
  }

  function FrameView({ frame }) {
    // Visual: render the composited frame with a "what got drawn" overlay
    const { Preview } = window.Sprites;
    if (!frame) return <div className="panel-bd" style={{ padding: 16, color: "var(--fg-2)" }}>No frame selected.</div>;
    const textures = Array.isArray(window.MockData && window.MockData.textures) ? window.MockData.textures : [];
    return (
      <div className="panel-bd" style={{ padding: 14, display: "flex", gap: 14 }}>
        <div>
          <div className="caps" style={{ marginBottom: 6 }}>Final output (kitty image 10423)</div>
          <Preview kind="composite_fullscreen" width={360} height={275}/>
          <div className="muted" style={{ fontSize: "var(--fs-xs)", marginTop: 4 }}>879×672 · file_whole · 2.25 MB</div>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div className="caps" style={{ marginBottom: 6 }}>Contributors</div>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(110px,1fr))", gap: 8 }}>
            {textures.map(t => (
              <div key={t.texture_key} style={{ border: "1px solid var(--line)", borderRadius: 6, padding: 6 }}>
                <Preview kind={t.nickname} width={90} height={60}/>
                <div style={{ fontSize: "var(--fs-xs)", marginTop: 4 }}>{t.nickname}</div>
                <div className="muted" style={{ fontSize: 10 }}>{t.size.join("×")} · {t.blend_mode}</div>
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  function MappingTable({ frame, textures, kittyImages, placements }) {
    if (!frame) return <div className="panel-bd" style={{ padding: 16, color: "var(--fg-2)" }}>No frame selected.</div>;
    textures = Array.isArray(textures) ? textures : [];
    kittyImages = Array.isArray(kittyImages) ? kittyImages : [];
    placements = Array.isArray(placements) ? placements : [];
    const resourceRefs = Array.isArray(frame.resource_refs) ? frame.resource_refs : [];
    const texKeys = resourceRefs.filter(r => r && r.kind === 'texture').map(r => r.texture_key);
    const imgIds = resourceRefs.filter(r => r && r.kind === 'image').map(r => r.image_id);
    const plcIds = resourceRefs.filter(r => r && r.kind === 'placement').map(r => r.placement_id);
    const rows = textures.filter(t => texKeys.includes(t.texture_key));
    const img = kittyImages.find(i => i && imgIds.includes(i.image_id)) || kittyImages.find(i => i && i.uploaded_frame === frame.id) || null;
    const plc = placements.find(p => p && plcIds.includes(p.placement_id)) || (img ? placements.find(p => p && p.image_id === img.image_id) : null) || null;
    return (
      <div className="panel-bd" style={{ padding: 0 }}>
        <table className="tbl">
          <thead><tr><th>SDL texture</th><th>size</th><th>blend</th><th>→</th><th>kitty image</th><th>transport</th><th>placement</th></tr></thead>
          <tbody>
            {rows.map(t => (
              <tr key={t.texture_key}>
                <td>{t.nickname}<div className="muted" style={{ fontSize: 10 }}>{t.texture_key}</div></td>
                <td className="tnum">{t.size.join("×")}</td>
                <td><span className={"pill " + (t.blend_mode === "add" ? "red" : "ghost")} style={{ height: 16, fontSize: 10 }}>{t.blend_mode}</span></td>
                <td className="muted">→</td>
                <td className="tnum" style={{ color: "var(--cyan)" }}>{img.image_id}</td>
                <td><span className="pill cyan" style={{ height: 16, fontSize: 10 }}>{img.transport}</span></td>
                <td className="tnum" style={{ color: "var(--accent)" }}>{plc?.placement_id ?? "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  }

  function ConfigPane({ session }) {
    const rows = [
      ["intercept_mode", session.config.intercept_mode, ["sync", "queued_replay"]],
      ["composite_mode", session.config.composite_mode, ["sprite", "fullscreen", "tiled_strip"]],
      ["output_profile", session.config.output_profile, ["direct_apc", "file_whole", "file_offset"]],
      ["present_fps", session.config.present_fps + " (uncapped)", null],
      ["max_queue_depth", session.config.max_queue_depth, null],
      ["drop_stale_batches", String(session.config.drop_stale_batches), null],
    ];
    return (
      <div className="panel-bd" style={{ padding: 14 }}>
        <div className="caps" style={{ marginBottom: 8 }}>Runtime config</div>
        <table className="tbl">
          <thead><tr><th>key</th><th>value</th><th>options</th></tr></thead>
          <tbody>
            {rows.map(([k, v, o]) => (
              <tr key={k}>
                <td className="muted">{k}</td>
                <td style={{ color: "var(--fg-0)" }}>{v}</td>
                <td className="muted" style={{ fontSize: "var(--fs-xs)" }}>{o ? o.join(" · ") : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="muted" style={{ marginTop: 14, fontSize: "var(--fs-xs)" }}>Live config editing is not implemented yet — this space is reserved for future /config endpoint.</div>
      </div>
    );
  }

  const root = ReactDOM.createRoot(document.getElementById("root"));
  root.render(<ErrorBoundary><App/></ErrorBoundary>);
})();
