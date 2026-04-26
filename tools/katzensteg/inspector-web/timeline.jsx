// timeline.jsx — full-width multi-track timeline with scrubbable playhead.
// Tracks (top→bottom):
//   - frame duration bars (height = present_ns)
//   - queue depth area chart
//   - upload bytes bars
//   - strategy ribbon
//   - marker lane (skipped / dropped / fallback / upload)

(function () {
  const { useRef, useEffect, useState, useMemo, useCallback } = React;

  const STRAT_COLOR = {
    sprite: "var(--strat-sprite)",
    composite: "var(--strat-composite)",
    tiled: "var(--strat-tiled)",
  };

  function fmtMs(ns) { return (ns / 1e6).toFixed(1) + "ms"; }
  function fmtBytes(b) {
    if (b < 1024) return b + "B";
    if (b < 1024*1024) return (b/1024).toFixed(1) + "KB";
    return (b/1024/1024).toFixed(2) + "MB";
  }

  function Timeline({ frames, selectedId, onSelect, onHover, live, tracks }) {
    const containerRef = useRef(null);
    const [hoverIdx, setHoverIdx] = useState(-1);
    const [width, setWidth] = useState(1000);

    useEffect(() => {
      const ro = new ResizeObserver(() => {
        if (containerRef.current) setWidth(containerRef.current.clientWidth);
      });
      if (containerRef.current) ro.observe(containerRef.current);
      return () => ro.disconnect();
    }, []);

    const n = frames.length;
    const leftGutter = 48;
    const colW = n > 0 ? Math.max(4, (width - leftGutter) / n) : Math.max(4, width - leftGutter);

    const maxPresent = useMemo(() => Math.max(1, ...frames.map(f => f.present_ns || 0)), [frames]);
    const maxQueue   = useMemo(() => Math.max(1, ...frames.map(f => f.queue_depth || 0)), [frames]);
    const maxUpload  = useMemo(() => Math.max(1, ...frames.map(f => (f.bytes && f.bytes.uploaded) || 0)), [frames]);

    // Track heights
    const H = {
      frames: tracks.frames ? 56 : 0,
      queue: tracks.queue ? 32 : 0,
      upload: tracks.upload ? 28 : 0,
      thread: tracks.thread ? 28 : 0,
      strat: tracks.strat ? 10 : 0,
      marker: tracks.markers ? 20 : 0,
    };

    const selectedIdx = frames.findIndex(f => f.id === selectedId);

    const handleMove = (e) => {
      if (n === 0 || !containerRef.current) {
        setHoverIdx(-1);
        onHover && onHover(null);
        return;
      }
      const r = containerRef.current.getBoundingClientRect();
      const x = e.clientX - r.left - leftGutter;
      const i = Math.max(0, Math.min(n - 1, Math.floor(x / colW)));
      setHoverIdx(i);
      onHover && onHover(frames[i] || null);
    };
    const handleClick = () => {
      const frame = hoverIdx >= 0 ? frames[hoverIdx] : null;
      if (frame) onSelect(frame.id);
    };

    return (
      <div className="tl-root" ref={containerRef}
           onMouseMove={handleMove}
           onMouseLeave={() => { setHoverIdx(-1); onHover && onHover(null); }}
           onClick={handleClick}>
        <style>{`
          .tl-root { position: relative; user-select: none; cursor: crosshair; background: #0b0e13; }
          .tl-hdr  { display: flex; align-items: center; height: var(--tlhdr-h); padding: 0 10px; gap: 12px; border-bottom: 1px solid var(--line); background: #0e1116; }
          .tl-hdr .lbl { font-size: var(--fs-xs); color: var(--fg-2); text-transform: uppercase; letter-spacing: .08em; }
          .tl-hdr .spacer { flex: 1; }
          .tl-track-label {
            position: absolute; left: 0; width: ${leftGutter}px; height: 100%;
            display: flex; align-items: center; justify-content: flex-end;
            padding-right: 6px; font-size: 9.5px; letter-spacing: .04em;
            text-transform: uppercase; color: var(--fg-2);
            border-right: 1px solid var(--line);
            background: #0b0e13;
          }
          .tl-track { position: relative; border-bottom: 1px solid var(--line); }
          .tl-scale { position: absolute; inset: 0; pointer-events: none; }
          .tl-scale .tick { position: absolute; top: 0; bottom: 0; width: 1px; background: rgba(255,255,255,.04); }
          .tl-scale .tick .t { position: absolute; top: 2px; left: 4px; font-size: 9.5px; color: var(--fg-3); }
          .tl-hover { position: absolute; top: 0; bottom: 0; width: 1px; background: rgba(255,255,255,.2); pointer-events: none; }
          .tl-playhead { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--accent); pointer-events: none; box-shadow: 0 0 8px rgba(255,138,61,.7); }
          .tl-playhead::before { content: ''; position: absolute; top: -1px; left: -4px; width: 9px; height: 9px; background: var(--accent); clip-path: polygon(50% 100%, 0 0, 100% 0); }
          .tl-tt { position: absolute; z-index: 3; background: #0a0c10; border: 1px solid var(--line-2); border-radius: 6px; padding: 6px 8px; font-size: var(--fs-xs); pointer-events: none; min-width: 180px; box-shadow: 0 6px 20px rgba(0,0,0,.6); }
          .tl-tt .k { color: var(--fg-2); }
          .tl-tt .v { color: var(--fg-0); font-variant-numeric: tabular-nums; }
          .tl-live { position: absolute; top: 4px; right: 8px; z-index: 2; display: flex; align-items: center; gap: 6px; font-size: var(--fs-xs); color: var(--fg-2); }
        `}</style>

        <div className="tl-hdr">
          <span className="lbl">Timeline</span>
          <span className="lbl">{frames.length} frames · {frames[0]?.id}–{frames[frames.length-1]?.id}</span>
          <span className="spacer" />
          <span className="lbl">sprite</span><span className="pill green"><span className="dot"/>{frames.filter(f=>f.strategy_short==='sprite').length}</span>
          <span className="lbl">composite</span><span className="pill accent"><span className="dot"/>{frames.filter(f=>f.strategy_short==='composite').length}</span>
          <span className="lbl">tiled</span><span className="pill yellow"><span className="dot"/>{frames.filter(f=>f.strategy_short==='tiled').length}</span>
          {live && (<span className="tl-live"><span className="dot live"/>LIVE · follow latest</span>)}
        </div>

        {/* Frame duration track */}
        {tracks.frames && (
          <div className="tl-track" style={{ height: H.frames, paddingLeft: leftGutter }}>
            <div className="tl-track-label">frame<br/>ms</div>
            {/* 16.67ms guide (60fps) */}
            <div style={{ position: 'absolute', left: leftGutter, right: 0, top: (1 - (16.67e6 / maxPresent)) * H.frames, borderTop: '1px dashed rgba(110,168,255,.25)' }}>
              <span style={{ position:'absolute', right: 6, top: -12, fontSize: 9.5, color: 'rgba(110,168,255,.6)' }}>16.67ms · 60fps</span>
            </div>
            {frames.map((f, i) => {
              const h = (f.present_ns / maxPresent) * (H.frames - 4);
              const c = STRAT_COLOR[f.strategy_short];
              return (
                <div key={f.id}
                     style={{
                       position: 'absolute',
                       left: leftGutter + i * colW,
                       width: Math.max(colW - 1, 1),
                       bottom: 0, height: h, background: c,
                       opacity: f.dropped_frame_batches > 0 ? 0.55 : 1,
                     }} />
              );
            })}
          </div>
        )}

        {/* Queue depth */}
        {tracks.queue && (
          <div className="tl-track" style={{ height: H.queue, paddingLeft: leftGutter }}>
            <div className="tl-track-label">queue</div>
            <svg width={width - leftGutter} height={H.queue} style={{ position: 'absolute', left: leftGutter, top: 0 }}>
              <defs>
                <linearGradient id="qg" x1="0" x2="0" y1="0" y2="1">
                  <stop offset="0" stopColor="#c678dd" stopOpacity=".55" />
                  <stop offset="1" stopColor="#c678dd" stopOpacity="0" />
                </linearGradient>
              </defs>
              <path d={(() => {
                const pts = frames.map((f, i) => [leftGutter === leftGutter ? i * colW + colW/2 : 0, H.queue - (f.queue_depth / maxQueue) * (H.queue - 2)]);
                let d = `M 0 ${H.queue}`;
                pts.forEach(([x,y]) => d += ` L ${x} ${y}`);
                d += ` L ${(n-1) * colW + colW/2} ${H.queue} Z`;
                return d;
              })()} fill="url(#qg)" stroke="#c678dd" strokeWidth=".8" />
              <line x1="0" x2={width - leftGutter} y1={H.queue - (16 / maxQueue) * (H.queue - 2)} y2={H.queue - (16 / maxQueue) * (H.queue - 2)} stroke="rgba(230,196,106,.35)" strokeDasharray="2 3" />
            </svg>
          </div>
        )}

        {/* Upload bytes */}
        {tracks.upload && (
          <div className="tl-track" style={{ height: H.upload, paddingLeft: leftGutter }}>
            <div className="tl-track-label">uploads<br/>KB</div>
            {frames.map((f, i) => {
              const h = (f.bytes.uploaded / maxUpload) * (H.upload - 2);
              if (f.bytes.uploaded === 0) return null;
              return <div key={f.id} style={{ position: 'absolute', left: leftGutter + i * colW, bottom: 0, width: Math.max(colW - 1, 1), height: h, background: 'var(--cyan)', opacity: .8 }} />;
            })}
          </div>
        )}

        {/* Thread breakdown */}
        {tracks.thread && (
          <div className="tl-track" style={{ height: H.thread, paddingLeft: leftGutter }}>
            <div className="tl-track-label">threads</div>
            {frames.map((f, i) => {
              const total = f.timing.producer_ns + f.timing.replay_ns + f.timing.compose_ns + f.timing.emit_ns;
              const h = H.thread - 2;
              const hp = (f.timing.producer_ns / total) * h;
              const hr = (f.timing.replay_ns / total) * h;
              const hc = (f.timing.compose_ns / total) * h;
              const he = h - hp - hr - hc;
              const x = leftGutter + i * colW;
              const w = Math.max(colW - 1, 1);
              let y = H.thread - h;
              const bars = [];
              bars.push(<div key="p" style={{ position:'absolute', left:x, top:y, width:w, height:hp, background:'var(--th-producer)' }} />);
              y += hp;
              bars.push(<div key="r" style={{ position:'absolute', left:x, top:y, width:w, height:hr, background:'var(--th-replay)' }} />);
              y += hr;
              bars.push(<div key="c" style={{ position:'absolute', left:x, top:y, width:w, height:hc, background:'var(--th-compose)' }} />);
              y += hc;
              bars.push(<div key="e" style={{ position:'absolute', left:x, top:y, width:w, height:he, background:'var(--th-emit)' }} />);
              return bars;
            })}
          </div>
        )}

        {/* Strategy ribbon */}
        {tracks.strat && (
          <div className="tl-track" style={{ height: H.strat, paddingLeft: leftGutter }}>
            <div className="tl-track-label">strategy</div>
            {frames.map((f, i) => (
              <div key={f.id} style={{
                position: 'absolute',
                left: leftGutter + i * colW, top: 1,
                width: Math.max(colW, 1), height: H.strat - 2,
                background: STRAT_COLOR[f.strategy_short], opacity: .85
              }} />
            ))}
          </div>
        )}

        {/* Marker lane */}
        {tracks.markers && (
          <div className="tl-track" style={{ height: H.marker, paddingLeft: leftGutter }}>
            <div className="tl-track-label">events</div>
            {frames.map((f, i) => {
              const x = leftGutter + i * colW + colW/2;
              const m = [];
              if (f.fallback_reasons.length) m.push(<div key="fb" title="fallback" style={{ position:'absolute', left: x - 4, top: 3, width: 8, height: 8, background:'var(--red)', borderRadius: 2, transform:'rotate(45deg)' }} />);
              if (f.skipped_presents > 0) m.push(<div key="sk" title="skipped" style={{ position:'absolute', left: x - 3, top: 8, width: 6, height: 6, background:'var(--yellow)', borderRadius: '50%' }} />);
              if (f.dropped_frame_batches > 0) m.push(<div key="dr" title="dropped" style={{ position:'absolute', left: x - 4, top: 10, width: 8, height: 2, background:'var(--red)' }} />);
              if (f.counts.uploads > 0) m.push(<div key="up" title="upload" style={{ position:'absolute', left: x - 3, top: 14, width: 6, height: 3, background:'var(--cyan)' }} />);
              return m;
            })}
          </div>
        )}

        {/* Selected playhead */}
        {selectedIdx >= 0 && (
          <div className="tl-playhead" style={{ left: leftGutter + selectedIdx * colW + colW / 2 }} />
        )}

        {/* Hover cursor */}
        {hoverIdx >= 0 && hoverIdx !== selectedIdx && (
          <div className="tl-hover" style={{ left: leftGutter + hoverIdx * colW + colW / 2 }} />
        )}

        {/* Hover tooltip */}
        {hoverIdx >= 0 && frames[hoverIdx] && (() => {
          const f = frames[hoverIdx];
          const tx = leftGutter + hoverIdx * colW + colW / 2;
          const left = Math.min(width - 220, Math.max(0, tx + 8));
          return (
            <div className="tl-tt" style={{ top: 36, left }}>
              <div style={{ display:'flex', justifyContent:'space-between', marginBottom: 4 }}>
                <span style={{ color: 'var(--fg-0)', fontWeight: 600 }}>#{f.id}</span>
                <span className={`pill ${f.strategy_short === 'composite' ? 'accent' : f.strategy_short === 'tiled' ? 'yellow' : 'green'}`} style={{ height: 14, padding: '0 5px', fontSize: 9.5 }}>{f.strategy_short}</span>
              </div>
              <div style={{ display:'grid', gridTemplateColumns: 'auto 1fr', columnGap: 8, rowGap: 1 }}>
                <span className="k">present</span><span className="v">{fmtMs(f.present_ns)}</span>
                <span className="k">queue</span><span className="v">{f.queue_depth}</span>
                <span className="k">copies</span><span className="v">{f.counts.copies}</span>
                <span className="k">upload</span><span className="v">{fmtBytes(f.bytes.uploaded)}</span>
                {f.fallback_reasons.length > 0 && (<><span className="k" style={{color:'var(--red)'}}>fallback</span><span className="v" style={{color:'var(--red)'}}>{f.fallback_reasons[0].kind}</span></>)}
                {f.dropped_frame_batches > 0 && (<><span className="k" style={{color:'var(--red)'}}>dropped</span><span className="v">{f.dropped_frame_batches}</span></>)}
              </div>
            </div>
          );
        })()}
      </div>
    );
  }

  window.Timeline = Timeline;
})();
