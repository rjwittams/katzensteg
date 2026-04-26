// panels.jsx — Frame detail, resource inspector, event log, and the novel Bridge view.

(function () {
  const { useState, useMemo, useRef, useEffect } = React;
  const { Preview } = window.Sprites;

  function fmtNs(ns) {
    const v = Number(ns) || 0;
    if (v < 1000) return v + "ns";
    if (v < 1e6) return (v / 1e3).toFixed(1) + "µs";
    return (v / 1e6).toFixed(2) + "ms";
  }
  function fmtBytes(b) {
    const v = Number(b) || 0;
    if (v < 1024) return v + " B";
    if (v < 1024 * 1024) return (v / 1024).toFixed(1) + " KB";
    return (v / 1024 / 1024).toFixed(2) + " MB";
  }

  function safeArray(v) { return Array.isArray(v) ? v : []; }
  function safeFrame(frame) {
    if (!frame) return null;
    return {
      ...frame,
      fallback_reasons: safeArray(frame.fallback_reasons),
      resource_refs: safeArray(frame.resource_refs),
      mappings: safeArray(frame.mappings),
      counts: { copies: 0, fills: 0, clears: 0, uploads: 0, placements: 0, ...(frame.counts || {}) },
      bytes: { uploaded: 0, ...(frame.bytes || {}) },
      timing: { producer_ns: 0, replay_ns: 0, compose_ns: 0, emit_ns: 0, ...(frame.timing || {}) },
      ts_s: Number(frame.ts_s) || 0,
      present_ns: Number(frame.present_ns) || 0,
      queue_depth: Number(frame.queue_depth) || 0,
      strategy_short: frame.strategy_short || "sprite",
      render_strategy: frame.render_strategy || "sprite",
    };
  }

  function safeSize(size) {
    return Array.isArray(size) && size.length >= 2 ? [Number(size[0]) || 0, Number(size[1]) || 0] : [0, 0];
  }

  const STRAT_PILL = {
    sprite: { cls: "green", label: "sprite" },
    composite: { cls: "accent", label: "fullscreen composite" },
    tiled: { cls: "yellow", label: "tiled_strip" },
  };

  // ──────────────────────────────────────────────────────────────
  // Frame detail (left column)
  // ──────────────────────────────────────────────────────────────
  function FrameDetail({ frame, frames, textures, onSelectResource, onSelectFrame }) {
    frame = safeFrame(frame);
    textures = safeArray(textures);
    frames = safeArray(frames);
    if (!frame) return <div className="panel-bd" style={{ padding: 16, color: "var(--fg-2)" }}>No frame selected.</div>;
    const strat = STRAT_PILL[frame.strategy_short] || STRAT_PILL.sprite;
    const total = Math.max(1, frame.timing.producer_ns + frame.timing.replay_ns + frame.timing.compose_ns + frame.timing.emit_ns);
    const tp = (v) => ((v / total) * 100).toFixed(0);
    const prev = frames.find(f => f.id === frame.id - 1);
    const next = frames.find(f => f.id === frame.id + 1);

    return (
      <div className="panel-bd">
        {/* Frame header block */}
        <div className="section">
          <div className="row" style={{ marginBottom: 8 }}>
            <div style={{ fontSize: "var(--fs-xl)", fontWeight: 600, color: "var(--fg-0)", letterSpacing: "-.01em" }} className="ui">Frame #{frame.id}</div>
            <span className={`pill ${strat.cls}`}><span className="dot"/>{strat.label}</span>
            <span className="grow"/>
            <button className="btn sm" disabled={!prev} onClick={() => prev && onSelectFrame(prev.id)}>← prev</button>
            <button className="btn sm" disabled={!next} onClick={() => next && onSelectFrame(next.id)}>next →</button>
          </div>
          <div className="muted" style={{ fontSize: "var(--fs-xs)" }}>
            t = {(frame.ts_s).toFixed(3)}s · regime: {frame.regime}
          </div>
        </div>

        {/* Reason card (the novel 'why this frame?' explainer) */}
        {frame.fallback_reasons.length > 0 && (
          <div className="section">
            <div className="section-title">Why composite?</div>
            {frame.fallback_reasons.map((r, i) => {
              const tex = textures.find(t => t.texture_key === r.texture_key);
              return (
                <div key={i} className="reason-card err" style={{ marginBottom: 6 }}>
                  <div className="hd"><span className="dot warn" style={{ background: "var(--red)"}}/><b>{r.kind}</b> <span className="muted">= {r.value}</span></div>
                  <div className="muted" style={{ fontSize: "var(--fs-sm)" }}>
                    SDL_BLENDMODE_ADD on <a onClick={() => onSelectResource && onSelectResource("texture", r.texture_key)} style={{ color: "var(--accent)", cursor: "pointer", borderBottom: "1px dashed var(--accent-dim)" }}>{tex?.nickname || r.texture_key}</a> cannot be expressed by kitty sprite compositing — forcing fullscreen framebuffer composite.
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* Stat grid */}
        <div className="stat-grid">
          <div className="stat"><span className="label">Present</span><span className="value">{fmtNs(frame.present_ns)}</span><span className="sub">{(1e9 / frame.present_ns).toFixed(1)} fps eq.</span></div>
          <div className="stat"><span className="label">Queue</span><span className="value">{frame.queue_depth}</span><span className="sub">max 32</span></div>
          <div className="stat"><span className="label">Copies</span><span className="value">{frame.counts.copies}</span><span className="sub">+{frame.counts.fills}f / {frame.counts.clears}c</span></div>
          <div className="stat"><span className="label">Uploaded</span><span className="value">{fmtBytes(frame.bytes.uploaded)}</span><span className="sub">{frame.counts.uploads} upload · {frame.counts.placements} placement</span></div>
        </div>

        {/* Timing breakdown */}
        <div className="section">
          <div className="section-title">Timing breakdown</div>
          <div className="timing-bar" style={{ marginBottom: 6 }}>
            <i style={{ width: tp(frame.timing.producer_ns) + "%", background: "var(--th-producer)" }} />
            <i style={{ width: tp(frame.timing.replay_ns) + "%", background: "var(--th-replay)" }} />
            <i style={{ width: tp(frame.timing.compose_ns) + "%", background: "var(--th-compose)" }} />
            <i style={{ width: tp(frame.timing.emit_ns) + "%", background: "var(--th-emit)" }} />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "3px 12px", fontSize: "var(--fs-sm)" }}>
            <Legend color="var(--th-producer)" label="producer" value={fmtNs(frame.timing.producer_ns)} />
            <Legend color="var(--th-replay)"   label="replay"   value={fmtNs(frame.timing.replay_ns)} />
            <Legend color="var(--th-compose)"  label="compose"  value={fmtNs(frame.timing.compose_ns)} />
            <Legend color="var(--th-emit)"     label="emit"     value={fmtNs(frame.timing.emit_ns)} />
          </div>
        </div>

        {/* Touched resources */}
        <div className="section">
          <div className="section-title">Touched textures</div>
          <div style={{ display: "grid", gridTemplateColumns: "auto 1fr auto auto", rowGap: 4, columnGap: 10, fontSize: "var(--fs-sm)", alignItems: "center" }}>
            {textures.filter(t => {
              const touchedByRef = frame.resource_refs.some(r => r && (r.kind === 'texture') && r.texture_key === t.texture_key);
              const touchedByFallback = frame.fallback_reasons.some(r => r && r.texture_key === t.texture_key);
              return touchedByRef || touchedByFallback;
            }).map(t => (
              <React.Fragment key={t.texture_key}>
                <span onClick={() => onSelectResource && onSelectResource("texture", t.texture_key)}
                      style={{ cursor: "pointer" }}>
                  <Preview kind={t.nickname} width={28} height={24} />
                </span>
                <a onClick={() => onSelectResource && onSelectResource("texture", t.texture_key)}
                   style={{ color: "var(--fg-0)", cursor: "pointer" }}>{t.nickname}</a>
                <span className="muted tnum">{t.size[0]}×{t.size[1]}</span>
                <span className={"pill " + (t.blend_mode === "add" ? "red" : "ghost")} style={{ height: 16, fontSize: 10 }}>{t.blend_mode}</span>
              </React.Fragment>
            ))}
          </div>
        </div>
      </div>
    );
  }

  function Legend({ color, label, value }) {
    return (
      <div className="row" style={{ gap: 6 }}>
        <span style={{ width: 8, height: 8, background: color, borderRadius: 2, flexShrink: 0 }} />
        <span style={{ color: "var(--fg-2)", width: 60 }}>{label}</span>
        <span className="tnum" style={{ color: "var(--fg-0)", marginLeft: "auto" }}>{value}</span>
      </div>
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Bridge view (novel SDL → kitty provenance)
  // ──────────────────────────────────────────────────────────────
  function BridgeView({ frame, textures, kittyImages, placements, selectedRes, onSelectResource }) {
    frame = safeFrame(frame);
    textures = safeArray(textures);
    kittyImages = safeArray(kittyImages);
    placements = safeArray(placements);
    if (!frame) return <div className="panel-bd" style={{ padding: 16, color: "var(--fg-2)" }}>No frame selected.</div>;
    const touched = useMemo(() => {
      const texKeys = frame.resource_refs.filter(r => r && r.kind === 'texture').map(r => r.texture_key);
      const imgIds = frame.resource_refs.filter(r => r && r.kind === 'image').map(r => r.image_id);
      const plcIds = frame.resource_refs.filter(r => r && r.kind === 'placement').map(r => r.placement_id);
      const img = kittyImages.find(i => i && imgIds.includes(i.image_id)) || kittyImages.find(i => i && i.uploaded_frame === frame.id) || null;
      const texs = textures.filter(t => texKeys.includes(t.texture_key));
      const plc = placements.find(p => p && plcIds.includes(p.placement_id)) || (img ? placements.find(p => p && p.image_id === img.image_id) : null) || null;
      return { img, texs, plc };
    }, [frame, textures, kittyImages, placements]);

    const { img, texs, plc } = touched;
    const ref = useRef(null);
    const [hover, setHover] = useState(null);

    return (
      <div className="panel-bd" style={{ display: "flex", flexDirection: "column", minHeight: 0 }}>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 180px 1fr", gap: 0, padding: "12px 0 10px", position: "relative", minHeight: 280 }}>
          {/* Left: SDL side */}
          <div style={{ padding: "0 12px", borderRight: "1px dashed var(--line)" }}>
            <div className="caps" style={{ marginBottom: 8 }}>SDL textures</div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              {texs.map(t => {
                const isCause = frame.fallback_reasons.some(r => r && r.texture_key === t.texture_key);
                const isSel = selectedRes?.kind === "texture" && selectedRes.key === t.texture_key;
                return (
                  <div key={t.texture_key}
                       data-tex={t.texture_key}
                       onClick={() => onSelectResource({ kind: "texture", key: t.texture_key })}
                       onMouseEnter={() => setHover({ kind: "texture", key: t.texture_key })}
                       onMouseLeave={() => setHover(null)}
                       style={{
                         display: "grid", gridTemplateColumns: "40px 1fr", gap: 8, alignItems: "center",
                         padding: 6, borderRadius: 6, cursor: "pointer",
                         background: isSel ? "rgba(255,138,61,.08)" : "transparent",
                         border: "1px solid " + (isCause ? "rgba(239,106,106,.4)" : "var(--line)"),
                       }}>
                    <Preview kind={t.nickname} width={40} height={36} />
                    <div style={{ minWidth: 0 }}>
                      <div className="nowrap" style={{ fontSize: "var(--fs-sm)" }}>{t.nickname}</div>
                      <div className="muted nowrap" style={{ fontSize: 10 }}>{t.size[0]}×{t.size[1]} · {t.format} · blend: <span style={{ color: t.blend_mode === "add" ? "var(--red)" : "var(--fg-1)" }}>{t.blend_mode}</span></div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {/* Middle: the bridge */}
          <div style={{ position: "relative", minHeight: 240 }} ref={ref}>
            <svg width="100%" height="100%" viewBox="0 0 180 260" preserveAspectRatio="none" style={{ position: "absolute", inset: 0 }}>
              <defs>
                {texs.map((t, i) => {
                  const isCause = frame.fallback_reasons.some(r => r && r.texture_key === t.texture_key);
                  return (
                    <linearGradient key={i} id={`br-g-${i}`} x1="0" x2="1" y1="0" y2="0">
                      <stop offset="0"   stopColor={isCause ? "#ef6a6a" : "#4dd2e8"} stopOpacity=".9"/>
                      <stop offset="1"   stopColor="#ff8a3d" stopOpacity=".9"/>
                    </linearGradient>
                  );
                })}
              </defs>
              {/* Suspension arches */}
              <path d="M 0 240 Q 90 20 180 240" stroke="rgba(255,255,255,.06)" fill="none" strokeWidth="1.5" />
              <path d="M 0 250 L 180 250" stroke="rgba(255,255,255,.06)" fill="none" strokeWidth="1" />
              {/* Cables from each texture → kitty image */}
              {texs.map((t, i) => {
                const total = texs.length;
                const y1 = 20 + (i + 0.5) * ((240 - 20) / total);
                const y2 = 130;
                const isCause = frame.fallback_reasons.some(r => r && r.texture_key === t.texture_key);
                const isHover = hover?.kind === "texture" && hover.key === t.texture_key;
                const isSel = selectedRes?.kind === "texture" && selectedRes.key === t.texture_key;
                return (
                  <path key={t.texture_key}
                        d={`M 0 ${y1} C 60 ${y1} 120 ${y2} 180 ${y2}`}
                        stroke={`url(#br-g-${i})`}
                        strokeWidth={isHover || isSel ? 2.5 : (isCause ? 1.8 : 1.2)}
                        strokeDasharray={isCause ? "4 3" : "0"}
                        fill="none"
                        opacity={isHover || isSel ? 1 : 0.75} />
                );
              })}
              {/* From kitty image to placement */}
              <path d="M 180 130 L 180 130" stroke="#ff8a3d" />
              {/* label chip on arch */}
              <g transform="translate(55,10)">
                <rect x="0" y="0" width="70" height="16" rx="8" fill="#0b0e13" stroke="rgba(255,138,61,.4)" />
                <text x="35" y="11" textAnchor="middle" fontSize="9" fill="#ff8a3d" fontFamily="ui-monospace,monospace">{img ? "→ 1 upload" : "no upload"}</text>
              </g>
            </svg>
            <div style={{ position: "absolute", top: 244, left: 0, right: 0, textAlign: "center", fontSize: 10, color: "var(--fg-2)", fontFamily: "var(--font-mono)" }}>
              {frame.render_strategy}
            </div>
          </div>

          {/* Right: kitty side */}
          <div style={{ padding: "0 12px" }}>
            <div className="caps" style={{ marginBottom: 8 }}>kitty image · placement</div>
            {img && (
              <div style={{
                display: "grid", gridTemplateColumns: "80px 1fr", gap: 8, alignItems: "flex-start",
                padding: 6, borderRadius: 6,
                border: "1px solid var(--line)",
                background: "rgba(255,138,61,.04)",
              }}>
                <Preview kind={img.source} width={80} height={62} />
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontSize: "var(--fs-sm)", color: "var(--fg-0)" }}>image_id <b className="tnum">{img.image_id}</b></div>
                  <div className="muted" style={{ fontSize: 10 }}>{img.size[0]}×{img.size[1]} · transport: <span style={{ color: "var(--cyan)" }}>{img.transport}</span></div>
                  <div className="muted" style={{ fontSize: 10 }}>bytes: {fmtBytes(img.bytes)}</div>
                </div>
              </div>
            )}
            {plc && (
              <div style={{ marginTop: 6, padding: 6, border: "1px solid var(--line)", borderRadius: 6 }}>
                <div style={{ fontSize: "var(--fs-sm)" }}>placement <b className="tnum">{plc.placement_id}</b></div>
                <div className="muted" style={{ fontSize: 10 }}>cells: [{(Array.isArray(plc.dest_cells) ? plc.dest_cells : [0,0,0,0]).join(", ")}]</div>
                <div className="muted" style={{ fontSize: 10 }}>src: [{plc.src_rect.join(", ")}]</div>
                {/* cell grid preview */}
                <svg width="100%" height="42" viewBox="0 0 160 42" style={{ marginTop: 4 }}>
                  <rect x="0" y="0" width="160" height="42" fill="#0a0d12" stroke="var(--line)" />
                  <rect x={(Array.isArray(plc.dest_cells) ? plc.dest_cells[0] : 0) * (160/165)} y={(Array.isArray(plc.dest_cells) ? plc.dest_cells[1] : 0) * (42/50)}
                        width={(Array.isArray(plc.dest_cells) ? plc.dest_cells[2] : 0) * (160/165)} height={(Array.isArray(plc.dest_cells) ? plc.dest_cells[3] : 0) * (42/50)}
                        fill="rgba(255,138,61,.25)" stroke="var(--accent)" strokeWidth=".7" />
                </svg>
              </div>
            )}
          </div>
        </div>

        {/* legend */}
        <div style={{ padding: "6px 12px", borderTop: "1px solid var(--line)", display: "flex", gap: 14, fontSize: "var(--fs-xs)", color: "var(--fg-2)", background: "#0e1116" }}>
          <span><span style={{ display: "inline-block", width: 14, height: 2, background: "#4dd2e8", marginRight: 4, verticalAlign: "middle" }}/>reuse / sprite</span>
          <span><span style={{ display: "inline-block", width: 14, height: 2, background: "#ff8a3d", marginRight: 4, verticalAlign: "middle" }}/>composite contributor</span>
          <span><span style={{ display: "inline-block", width: 14, height: 0, borderTop: "2px dashed #ef6a6a", marginRight: 4, verticalAlign: "middle" }}/>fallback cause</span>
          <span className="grow"/>
          <span className="muted">click a texture or image to pin</span>
        </div>
      </div>
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Resource inspector (table of textures / kitty images / placements)
  // ──────────────────────────────────────────────────────────────
  function ResourceInspector({ textures, kittyImages, placements, selectedRes, onSelectResource, mode, onChangeMode, selectedFrameId }) {
    const [filter, setFilter] = useState("");
    textures = safeArray(textures);
    kittyImages = safeArray(kittyImages);
    placements = safeArray(placements);

    let rows = [];
    if (mode === "tex") {
      rows = textures.filter(t => !filter || (String(t.texture_key || "").includes(filter) || String(t.nickname || "").includes(filter) || String(t.blend_mode || "").includes(filter)));
    } else if (mode === "img") {
      rows = kittyImages.filter(i => !filter || String(i.image_id || "").includes(filter) || String(i.source || "").includes(filter) || String(i.transport || "").includes(filter));
    } else {
      rows = placements.filter(p => !filter || String(p.placement_id || "").includes(filter) || String(p.image_id || "").includes(filter));
    }

    // selected record → preview panel
    const selectedRecord = useMemo(() => {
      if (!selectedRes) return null;
      if (selectedRes.kind === "texture") return textures.find(t => t.texture_key === selectedRes.key);
      if (selectedRes.kind === "image")   return kittyImages.find(i => i.image_id === selectedRes.key);
      if (selectedRes.kind === "placement") return placements.find(p => p.placement_id === selectedRes.key);
      return null;
    }, [selectedRes, textures, kittyImages, placements]);

    return (
      <div className="panel-bd" style={{ display: "grid", gridTemplateColumns: "1fr 260px", gap: 0, minHeight: 0 }}>
        <div style={{ display: "flex", flexDirection: "column", minHeight: 0, borderRight: "1px solid var(--line)" }}>
          <div style={{ display: "flex", gap: 6, padding: "6px 10px", borderBottom: "1px solid var(--line)", background: "#0e1116" }}>
            <div style={{ display: "flex", gap: 2 }}>
              <button className="btn sm" data-active={mode === "tex" ? "1" : undefined} onClick={() => onChangeMode("tex")}>Textures · {textures.length}</button>
              <button className="btn sm" data-active={mode === "img" ? "1" : undefined} onClick={() => onChangeMode("img")}>Images · {kittyImages.length}</button>
              <button className="btn sm" data-active={mode === "plc" ? "1" : undefined} onClick={() => onChangeMode("plc")}>Placements · {placements.length}</button>
            </div>
            <div className="grow" />
            <input className="filter-input" placeholder="filter…" value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 140 }}/>
          </div>
          <div style={{ flex: 1, overflow: "auto", minHeight: 0 }}>
            {mode === "tex" && (
              <table className="tbl">
                <thead><tr><th></th><th>texture_key</th><th>size</th><th>fmt</th><th>blend</th><th>updates</th><th>bytes</th></tr></thead>
                <tbody>
                  {rows.map(t => (
                    <tr key={t.texture_key}
                        data-selected={selectedRes?.kind === "texture" && selectedRes.key === t.texture_key ? "1" : undefined}
                        onClick={() => onSelectResource({ kind: "texture", key: t.texture_key })}>
                      <td style={{ width: 32 }}><Preview kind={t.nickname} width={24} height={20} /></td>
                      <td><span style={{ color: "var(--fg-0)" }}>{t.nickname}</span><div className="muted" style={{ fontSize: 10 }}>{t.texture_key}</div></td>
                      <td className="tnum">{t.size[0]}×{t.size[1]}</td>
                      <td className="muted">{t.format}</td>
                      <td><span className={"pill " + (t.blend_mode === "add" ? "red" : "ghost")} style={{ height: 16, fontSize: 10 }}>{t.blend_mode}</span></td>
                      <td className="tnum">{t.update_count}</td>
                      <td className="tnum muted">{fmtBytes(t.bytes)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            {mode === "img" && (
              <table className="tbl">
                <thead><tr><th></th><th>image_id</th><th>source</th><th>size</th><th>transport</th><th>frame</th><th>bytes</th></tr></thead>
                <tbody>
                  {rows.map(i => (
                    <tr key={i.image_id}
                        data-selected={selectedRes?.kind === "image" && selectedRes.key === i.image_id ? "1" : undefined}
                        onClick={() => onSelectResource({ kind: "image", key: i.image_id })}>
                      <td style={{ width: 32 }}><Preview kind={i.source} width={24} height={20} /></td>
                      <td><span style={{ color: "var(--cyan)" }} className="tnum">{i.image_id}</span></td>
                      <td>{i.source}</td>
                      <td className="tnum">{i.size[0]}×{i.size[1]}</td>
                      <td><span className="pill cyan" style={{ height: 16, fontSize: 10 }}>{i.transport}</span></td>
                      <td className="tnum">{i.uploaded_frame}</td>
                      <td className="tnum muted">{fmtBytes(i.bytes)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            {mode === "plc" && (
              <table className="tbl">
                <thead><tr><th>placement_id</th><th>image_id</th><th>src_rect</th><th>dest_cells</th><th>frame</th></tr></thead>
                <tbody>
                  {rows.map(p => (
                    <tr key={p.placement_id}
                        data-selected={selectedRes?.kind === "placement" && selectedRes.key === p.placement_id ? "1" : undefined}
                        onClick={() => onSelectResource({ kind: "placement", key: p.placement_id })}>
                      <td className="tnum" style={{ color: "var(--accent)" }}>{p.placement_id}</td>
                      <td className="tnum muted">{p.image_id}</td>
                      <td className="tnum muted">[{p.src_rect.join(", ")}]</td>
                      <td className="tnum">[{p.dest_cells.join(", ")}]</td>
                      <td className="tnum muted">{p.frame}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
        <div style={{ padding: 12, overflow: "auto", minHeight: 0 }}>
          {!selectedRecord ? (
            <div className="muted" style={{ fontSize: "var(--fs-sm)" }}>Select a row to preview.</div>
          ) : selectedRes.kind === "texture" ? (
            <TexturePreview t={selectedRecord} />
          ) : selectedRes.kind === "image" ? (
            <ImagePreview img={selectedRecord} />
          ) : (
            <PlacementPreview p={selectedRecord} />
          )}
        </div>
      </div>
    );
  }

  function TexturePreview({ t }) {
    if (!t) return <div className="muted" style={{ fontSize: "var(--fs-sm)" }}>No texture selected.</div>;
    const size = safeSize(t.size);
    const previewH = size[0] > 0 ? Math.max(1, Math.floor(220 * size[1] / size[0])) : 120;
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div className="caps">SDL texture</div>
        <Preview kind={t.nickname || "texture"} width={220} height={previewH} />
        <dl className="kv">
          <dt>texture_key</dt><dd>{t.texture_key}</dd>
          <dt>nickname</dt><dd>{t.nickname}</dd>
          <dt>size</dt><dd>{size[0]} × {size[1]}</dd>
          <dt>format</dt><dd>{t.format}</dd>
          <dt>access</dt><dd>{t.access}</dd>
          <dt>blend</dt><dd>{t.blend_mode}</dd>
          <dt>color_mod</dt><dd>[{safeArray(t.color_mod).join(", ")}]</dd>
          <dt>alpha_mod</dt><dd>{t.alpha_mod}</dd>
          <dt>updates</dt><dd>{t.update_count}</dd>
          <dt>last_updated</dt><dd>frame #{t.last_updated_frame}</dd>
          <dt>bytes</dt><dd>{fmtBytes(t.bytes)}</dd>
        </dl>
      </div>
    );
  }
  function ImagePreview({ img }) {
    if (!img) return <div className="muted" style={{ fontSize: "var(--fs-sm)" }}>No image selected.</div>;
    const size = safeSize(img.size);
    const previewH = size[0] > 0 ? Math.max(1, Math.floor(220 * size[1] / size[0])) : 120;
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div className="caps">kitty image</div>
        <Preview kind={img.source || "image"} width={220} height={previewH} />
        <dl className="kv">
          <dt>image_id</dt><dd style={{ color: "var(--cyan)" }}>{img.image_id}</dd>
          <dt>source</dt><dd>{img.source}</dd>
          <dt>size</dt><dd>{size[0]} × {size[1]}</dd>
          <dt>transport</dt><dd>{img.transport}</dd>
          <dt>uploaded_frame</dt><dd>#{img.uploaded_frame}</dd>
          <dt>bytes</dt><dd>{fmtBytes(img.bytes)}</dd>
          <dt>from textures</dt><dd>{safeArray(img.from_texture_keys).length}</dd>
        </dl>
      </div>
    );
  }
  function PlacementPreview({ p }) {
    if (!p) return <div className="muted" style={{ fontSize: "var(--fs-sm)" }}>No placement selected.</div>;
    const dest = Array.isArray(p.dest_cells) && p.dest_cells.length >= 4 ? p.dest_cells : [0,0,0,0];
    const src = Array.isArray(p.src_rect) && p.src_rect.length >= 4 ? p.src_rect : [0,0,0,0];
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div className="caps">placement</div>
        <svg width="220" height="68" viewBox="0 0 220 68" style={{ background: "var(--bg-1)", border: "1px solid var(--line)", borderRadius: 4 }}>
          <rect x="4" y="4" width="212" height="60" fill="none" stroke="var(--line)" strokeDasharray="3 2"/>
          <rect x={4 + (dest[0] / 165) * 212}
                y={4 + (dest[1] / 50) * 60}
                width={(dest[2] / 165) * 212}
                height={(dest[3] / 50) * 60}
                fill="rgba(255,138,61,.18)" stroke="var(--accent)"/>
        </svg>
        <dl className="kv">
          <dt>placement_id</dt><dd style={{ color: "var(--accent)" }}>{p.placement_id}</dd>
          <dt>image_id</dt><dd className="tnum">{p.image_id}</dd>
          <dt>src_rect</dt><dd>[{src.join(", ")}]</dd>
          <dt>dest_cells</dt><dd>[{dest.join(", ")}]</dd>
          <dt>frame</dt><dd>#{p.frame}</dd>
        </dl>
      </div>
    );
  }

  // ──────────────────────────────────────────────────────────────
  // Event log (bottom drawer)
  // ──────────────────────────────────────────────────────────────
  function EventLog({ events, selectedFrameId }) {
    const [filter, setFilter] = useState("");
    events = safeArray(events);
    const [threadFilter, setThreadFilter] = useState("all");
    const [kindFilter, setKindFilter] = useState("all");

    const filtered = events.filter(e => {
      if (threadFilter !== "all" && e.thread !== threadFilter) return false;
      if (kindFilter !== "all" && e.kind !== kindFilter) return false;
      if (!filter) return true;
      const s = (e.kind + " " + JSON.stringify(e.payload)).toLowerCase();
      return s.includes(filter.toLowerCase());
    });

    const kinds = useMemo(() => Array.from(new Set(events.map(e => e.kind))), [events]);

    return (
      <div style={{ display: "flex", flexDirection: "column", height: "100%", minHeight: 0 }}>
        <div style={{ display: "flex", gap: 6, padding: "6px 10px", alignItems: "center", borderBottom: "1px solid var(--line)", background: "#0e1116" }}>
          <span className="caps">Events · frame #{selectedFrameId}</span>
          <span className="grow"/>
          <select className="filter-input" value={threadFilter} onChange={e => setThreadFilter(e.target.value)}>
            <option value="all">all threads</option>
            <option value="producer">producer</option>
            <option value="worker">worker</option>
            <option value="main">main</option>
          </select>
          <select className="filter-input" value={kindFilter} onChange={e => setKindFilter(e.target.value)}>
            <option value="all">all kinds</option>
            {kinds.map(k => <option key={k} value={k}>{k}</option>)}
          </select>
          <input className="filter-input" placeholder="filter payload…" value={filter} onChange={e => setFilter(e.target.value)} style={{ width: 180 }}/>
          <span className="muted" style={{ fontSize: "var(--fs-xs)" }}>{filtered.length}/{events.length}</span>
        </div>
        <div style={{ flex: 1, overflow: "auto", minHeight: 0 }}>
          <table className="tbl">
            <thead><tr><th style={{ width: 110 }}>ts (rel)</th><th style={{ width: 80 }}>thread</th><th style={{ width: 180 }}>kind</th><th>payload</th></tr></thead>
            <tbody>
              {filtered.map((e, i) => {
                const baseT = events[0] ? (events[0].ts_ns || 0) : 0;
                const dt = (e.ts_ns - baseT) / 1e6;
                return (
                  <tr key={i}>
                    <td className="tnum muted">+{dt.toFixed(3)}ms</td>
                    <td><span className={"pill " + (e.thread === "producer" ? "blue" : e.thread === "worker" ? "violet" : "ghost")} style={{ height: 16, fontSize: 10 }}>{e.thread}</span></td>
                    <td style={{ color: e.kind.includes("fallback") ? "var(--red)" : e.kind.includes("upload") ? "var(--cyan)" : "var(--fg-0)" }}>{e.kind}</td>
                    <td className="muted" style={{ fontSize: 11, fontFamily: "var(--font-mono)" }}>{JSON.stringify(e.payload)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    );
  }

  window.Panels = { FrameDetail, BridgeView, ResourceInspector, EventLog };
})();
