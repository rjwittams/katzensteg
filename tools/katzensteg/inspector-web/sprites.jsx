// sprites.jsx — draws small canvas previews that look like ttytris assets.
// Shared by SDL-side (raw textures) and kitty-side (composited image) previews.

(function () {
  // A tiny palette per Tetromino-like block
  const PAL = {
    I: ["#4dd2e8", "#2a9aaa"],
    O: ["#e6c46a", "#8f7a2a"],
    T: ["#c678dd", "#6b3d84"],
    S: ["#6ccf8e", "#3a7a51"],
    Z: ["#ef6a6a", "#8b3535"],
    J: ["#6ea8ff", "#3a5db0"],
    L: ["#ff8a3d", "#9c4c14"],
  };

  function drawBlock(ctx, x, y, s, pal) {
    const [a, b] = pal;
    ctx.fillStyle = a;
    ctx.fillRect(x, y, s, s);
    ctx.fillStyle = "rgba(255,255,255,.18)";
    ctx.fillRect(x, y, s, 1);
    ctx.fillRect(x, y, 1, s);
    ctx.fillStyle = "rgba(0,0,0,.35)";
    ctx.fillRect(x, y + s - 1, s, 1);
    ctx.fillRect(x + s - 1, y, 1, s);
    ctx.fillStyle = b;
    ctx.fillRect(x + 2, y + 2, s - 4, s - 4);
    ctx.fillStyle = "rgba(255,255,255,.14)";
    ctx.fillRect(x + 2, y + 2, s - 4, 1);
  }

  // playfield.blocks — 256x224 atlas: 7 tetromino block styles across the top row,
  // plus a ghost tile and a clear-flash tile.
  function drawBlocksAtlas(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = "#0a0d12";
    ctx.fillRect(0, 0, W, H);
    const tile = Math.floor(W / 8);
    const keys = ["I", "O", "T", "S", "Z", "J", "L"];
    for (let i = 0; i < keys.length; i++) {
      drawBlock(ctx, i * tile + 2, 2, tile - 4, PAL[keys[i]]);
    }
    // ghost
    ctx.strokeStyle = "#6ea8ff";
    ctx.lineWidth = 2;
    ctx.strokeRect(7 * tile + 3, 3, tile - 6, tile - 6);
    // flash
    ctx.fillStyle = "rgba(255,255,255,.9)";
    ctx.fillRect(2, tile + 2, tile - 4, tile - 4);
    // a second row: a mini playfield preview
    const pfX = 2, pfY = tile * 2 + 2;
    const cols = 10, rows = Math.min(Math.floor((H - pfY) / tile), 12);
    ctx.fillStyle = "#0e1218";
    ctx.fillRect(pfX, pfY, cols * tile, rows * tile);
    ctx.strokeStyle = "rgba(255,255,255,.07)";
    for (let c = 0; c <= cols; c++) { ctx.beginPath(); ctx.moveTo(pfX + c * tile, pfY); ctx.lineTo(pfX + c * tile, pfY + rows * tile); ctx.stroke(); }
    for (let r = 0; r <= rows; r++) { ctx.beginPath(); ctx.moveTo(pfX, pfY + r * tile); ctx.lineTo(pfX + cols * tile, pfY + r * tile); ctx.stroke(); }
    // stack
    const stack = [
      [0,0,0,1,1,0,0,0,0,0],
      [0,0,1,1,1,0,0,0,0,0],
      [0,2,2,0,0,0,3,3,0,0],
      [4,2,2,5,5,3,3,6,6,0],
      [4,4,4,5,5,6,6,6,7,7],
    ];
    const keyArr = ["I","O","T","S","Z","J","L"];
    for (let r = 0; r < stack.length; r++) {
      for (let c = 0; c < cols; c++) {
        const v = stack[stack.length - 1 - r][c];
        if (!v) continue;
        drawBlock(ctx, pfX + c * tile, pfY + (rows - 1 - r) * tile, tile, PAL[keyArr[v - 1]]);
      }
    }
    // active piece (T) near top
    drawBlock(ctx, pfX + 3 * tile, pfY + 1 * tile, tile, PAL.T);
    drawBlock(ctx, pfX + 4 * tile, pfY + 1 * tile, tile, PAL.T);
    drawBlock(ctx, pfX + 5 * tile, pfY + 1 * tile, tile, PAL.T);
    drawBlock(ctx, pfX + 4 * tile, pfY + 0 * tile, tile, PAL.T);
  }

  function drawGlyphAtlas(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#0a0d12";
    ctx.fillRect(0, 0, W, H);
    const cellW = 10, cellH = Math.floor(H / 2);
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789SCORELINESLVL";
    ctx.fillStyle = "#e7eaf0";
    ctx.font = "bold 10px ui-monospace, monospace";
    ctx.textBaseline = "top";
    for (let i = 0; i < chars.length; i++) {
      const r = Math.floor(i / Math.floor(W / cellW));
      const c = i % Math.floor(W / cellW);
      ctx.fillStyle = i % 3 === 0 ? "#ff8a3d" : i % 3 === 1 ? "#4dd2e8" : "#e7eaf0";
      ctx.fillText(chars[i], c * cellW + 1, r * cellH + 1);
    }
  }

  function drawParticles(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#000000";
    ctx.fillRect(0, 0, W, H);
    // soft radial sparkle — these will use BLENDMODE_ADD in SDL
    const grad = ctx.createRadialGradient(W / 2, H / 2, 2, W / 2, H / 2, W / 2);
    grad.addColorStop(0, "rgba(255,230,170,1)");
    grad.addColorStop(0.4, "rgba(255,160,60,.6)");
    grad.addColorStop(1, "rgba(0,0,0,0)");
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, W, H);
    // plus a little cross flare
    ctx.strokeStyle = "rgba(255,230,170,.7)";
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(W/2, 4); ctx.lineTo(W/2, H-4);
    ctx.moveTo(4, H/2); ctx.lineTo(W-4, H/2); ctx.stroke();
  }

  function drawHud(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#0f141b";
    ctx.fillRect(0, 0, W, H);
    ctx.strokeStyle = "#2a323d";
    ctx.lineWidth = 1;
    ctx.strokeRect(2, 2, W - 4, H - 4);
    ctx.fillStyle = "#4dd2e8";
    ctx.font = "bold 12px ui-monospace, monospace";
    ctx.fillText("SCORE", 8, 10);
    ctx.fillStyle = "#e7eaf0";
    ctx.font = "bold 16px ui-monospace, monospace";
    ctx.fillText("013440", 8, 26);
    ctx.fillStyle = "#ff8a3d";
    ctx.font = "bold 10px ui-monospace, monospace";
    ctx.fillText("LINES 042", 8, 52);
    ctx.fillText("LVL   04", 8, 66);
    ctx.fillStyle = "#c678dd";
    ctx.fillText("NEXT", 8, 86);
    // mini piece
    const pal = PAL.L;
    const t = 6;
    const ox = 8, oy = 96;
    [[0,0],[1,0],[2,0],[2,-1]].forEach(([c,r]) => drawBlock(ctx, ox + c * t, oy - r * t, t, pal));
  }

  function drawStarfield(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    const grd = ctx.createLinearGradient(0, 0, 0, H);
    grd.addColorStop(0, "#05080f");
    grd.addColorStop(1, "#0a1220");
    ctx.fillStyle = grd;
    ctx.fillRect(0, 0, W, H);
    let s = 1337;
    function r() { s = (s * 1664525 + 1013904223) >>> 0; return s / 0xffffffff; }
    for (let i = 0; i < 160; i++) {
      const x = Math.floor(r() * W), y = Math.floor(r() * H);
      const b = r();
      ctx.fillStyle = `rgba(${140 + b*90}, ${140 + b*60}, ${180 + b*60}, ${0.3 + b*0.6})`;
      ctx.fillRect(x, y, 1, 1);
      if (b > 0.85) ctx.fillRect(x, y+1, 1, 1);
    }
  }

  // Composite of the whole ttytris frame into one kitty image
  function drawComposite(canvas) {
    const W = canvas.width, H = canvas.height;
    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    // starfield bg
    const tmp = document.createElement("canvas");
    tmp.width = 64; tmp.height = Math.floor(64 * H / W);
    drawStarfield(tmp);
    ctx.drawImage(tmp, 0, 0, W, H);

    // playfield area (left-center)
    const pfW = Math.floor(W * 0.45), pfH = Math.floor(H * 0.9);
    const pfX = Math.floor(W * 0.12), pfY = Math.floor(H * 0.05);
    ctx.fillStyle = "#0a0d12";
    ctx.fillRect(pfX, pfY, pfW, pfH);
    ctx.strokeStyle = "rgba(255,255,255,.1)";
    ctx.strokeRect(pfX, pfY, pfW, pfH);
    // grid
    const cols = 10, rows = 20;
    const cw = Math.floor(pfW / cols), ch = Math.floor(pfH / rows);
    ctx.strokeStyle = "rgba(255,255,255,.04)";
    for (let c = 1; c < cols; c++) { ctx.beginPath(); ctx.moveTo(pfX + c * cw, pfY); ctx.lineTo(pfX + c * cw, pfY + rows * ch); ctx.stroke(); }
    for (let r = 1; r < rows; r++) { ctx.beginPath(); ctx.moveTo(pfX, pfY + r * ch); ctx.lineTo(pfX + cols * cw, pfY + r * ch); ctx.stroke(); }
    // stack
    const stack = [
      [0,0,0,1,1,0,0,0,0,0],
      [0,0,1,1,1,0,0,0,0,0],
      [0,2,2,0,0,0,3,3,0,0],
      [4,2,2,5,5,3,3,6,6,0],
      [4,4,4,5,5,6,6,6,7,7],
      [4,4,4,5,5,6,6,6,7,7],
    ];
    const keyArr = ["I","O","T","S","Z","J","L"];
    for (let r = 0; r < stack.length; r++) {
      for (let c = 0; c < cols; c++) {
        const v = stack[stack.length - 1 - r][c];
        if (!v) continue;
        drawBlock(ctx, pfX + c * cw, pfY + (rows - 1 - r) * ch, Math.min(cw, ch), PAL[keyArr[v - 1]]);
      }
    }
    // falling piece
    const s = Math.min(cw, ch);
    [[3,4],[4,4],[5,4],[4,3]].forEach(([c,r]) => drawBlock(ctx, pfX + c * cw, pfY + r * ch, s, PAL.T));

    // particles sparkle (the BLENDMODE_ADD culprit)
    ctx.globalCompositeOperation = "lighter";
    for (let i = 0; i < 14; i++) {
      const x = pfX + cw * (2 + (i % 9));
      const y = pfY + ch * (10 + ((i * 3) % 6));
      const r = Math.max(4, Math.floor(Math.min(cw, ch) * 0.6));
      const g = ctx.createRadialGradient(x + r/2, y + r/2, 1, x + r/2, y + r/2, r);
      g.addColorStop(0, "rgba(255,230,170,.9)");
      g.addColorStop(1, "rgba(255,140,40,0)");
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(x + r/2, y + r/2, r, 0, Math.PI*2); ctx.fill();
    }
    ctx.globalCompositeOperation = "source-over";

    // HUD (right)
    const hx = Math.floor(W * 0.64), hy = pfY, hw = Math.floor(W * 0.24), hh = pfH;
    ctx.fillStyle = "#0f141b";
    ctx.fillRect(hx, hy, hw, hh);
    ctx.strokeStyle = "#2a323d";
    ctx.strokeRect(hx, hy, hw, hh);
    ctx.fillStyle = "#4dd2e8"; ctx.font = "bold 10px ui-monospace,monospace"; ctx.fillText("SCORE", hx + 6, hy + 14);
    ctx.fillStyle = "#e7eaf0"; ctx.font = "bold 16px ui-monospace,monospace"; ctx.fillText("013440", hx + 6, hy + 32);
    ctx.fillStyle = "#ff8a3d"; ctx.font = "bold 10px ui-monospace,monospace";
    ctx.fillText("LINES  042", hx + 6, hy + 58);
    ctx.fillText("LVL    04",  hx + 6, hy + 72);
    ctx.fillStyle = "#c678dd";
    ctx.fillText("NEXT", hx + 6, hy + 96);
    const ox = hx + 10, oy = hy + 118, t = 10;
    [[0,0],[1,0],[2,0],[2,-1]].forEach(([c,r]) => drawBlock(ctx, ox + c * t, oy - r * t, t, PAL.L));
    ctx.fillStyle = "#c678dd";
    ctx.fillText("HOLD", hx + 6, hy + 172);
    [[0,0],[1,0],[0,-1],[1,-1]].forEach(([c,r]) => drawBlock(ctx, ox + c * t, oy + 64 - r * t, t, PAL.O));

    // score bar bottom
    ctx.fillStyle = "rgba(255,138,61,.9)";
    ctx.fillRect(hx + 6, hy + hh - 14, Math.floor((hw - 12) * 0.4), 6);
    ctx.fillStyle = "rgba(255,138,61,.25)";
    ctx.fillRect(hx + 6 + Math.floor((hw - 12) * 0.4), hy + hh - 14, (hw - 12) - Math.floor((hw - 12) * 0.4), 6);
  }

  const DRAWERS = {
    "playfield.blocks": drawBlocksAtlas,
    "glyphs.atlas": drawGlyphAtlas,
    "particles.sparkle": drawParticles,
    "hud.panel": drawHud,
    "bg.starfield": drawStarfield,
    "composite_fullscreen": drawComposite,
    "composite": drawComposite,
    "sprite": drawBlocksAtlas, // default sprite preview
  };

  function Preview({ kind, width = 96, height = 84, rounded = true, className = "" }) {
    const ref = React.useRef(null);
    React.useEffect(() => {
      if (!ref.current) return;
      const dpr = window.devicePixelRatio || 1;
      ref.current.width = Math.floor(width * dpr);
      ref.current.height = Math.floor(height * dpr);
      const ctx = ref.current.getContext("2d");
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ref.current.style.width = width + "px";
      ref.current.style.height = height + "px";
      const fn = DRAWERS[kind] || drawBlocksAtlas;
      const proxy = { width, height, getContext: (t) => ctx };
      fn(proxy);
    }, [kind, width, height]);
    return (
      <canvas ref={ref} className={"checker " + className}
              style={{ borderRadius: rounded ? 4 : 0, border: "1px solid var(--line)", imageRendering: "pixelated" }} />
    );
  }

  // Cat-bridge logo: a stylized cat silhouette crossing an arched bridge
  function Logo({ size = 22 }) {
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" className="catbridge" aria-label="Katzensteg logo">
        <defs>
          <linearGradient id="kb-g" x1="0" x2="1" y1="0" y2="0">
            <stop offset="0" stopColor="#4dd2e8" />
            <stop offset="1" stopColor="#ff8a3d" />
          </linearGradient>
        </defs>
        {/* Bridge arch */}
        <path d="M2 18 Q12 7 22 18" fill="none" stroke="url(#kb-g)" strokeWidth="1.6" strokeLinecap="round"/>
        <line x1="2" y1="18" x2="22" y2="18" stroke="url(#kb-g)" strokeWidth="1.2" strokeLinecap="round"/>
        {/* Cat silhouette walking over */}
        <g fill="#e7eaf0">
          {/* body */}
          <path d="M9.5 12.3 Q12 10.8 14.5 12.3 L14.5 13.4 Q12 12.4 9.5 13.4 Z"/>
          {/* head */}
          <path d="M14.5 11.9 L16 10.6 L16.3 11.2 L16.8 10.5 L17 11.5 L16 12.4 Z"/>
          {/* tail */}
          <path d="M9.5 12.8 Q7.8 12 7.5 10.5 L8.2 10.4 Q8.4 11.8 9.7 12.3 Z"/>
          {/* legs */}
          <rect x="10.2" y="13.1" width="0.7" height="1.8"/>
          <rect x="13.2" y="13.1" width="0.7" height="1.8"/>
        </g>
      </svg>
    );
  }

  window.Sprites = { Preview, Logo, PAL };
})();
