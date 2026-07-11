import { useState, useRef, useEffect } from "react";
import {
  Menu, Plus, ChevronDown, ChevronRight, ChevronLeft, ChevronUp, X, RotateCw,
  Maximize2, Minimize2, CircleCheck, CircleX, Send, Keyboard
} from "lucide-react";

// ---------- design tokens ----------
const C = {
  bg: "#0B0D11",
  panel: "#12161E",
  panel2: "#171C26",
  line: "#212836",
  text: "#E8EDF4",
  mono: "#C9D4E3",
  dim: "#68738A",
  blue: "#6FA8FF",
  green: "#4FBE8B",
  red: "#E06C75",
  amber: "#E0AC5F",
};
const MONO = "'SF Mono', ui-monospace, Menlo, 'JetBrains Mono', monospace";
const UI = "-apple-system, 'SF Pro Text', 'Hiragino Sans', system-ui, sans-serif";

// ---------- fake tmux data ----------
const SESSIONS = [
  {
    name: "main",
    windows: [
      { id: 0, name: "zsh", type: "chat" },
      { id: 1, name: "claude", type: "claude" },
      { id: 2, name: "monitor", type: "split" },
    ],
  },
  { name: "deploy", windows: [{ id: 0, name: "ansible", type: "chat" }] },
  { name: "logs", windows: [{ id: 0, name: "tail", type: "split" }] },
];

const INITIAL_BLOCKS = [
  {
    cmd: "git pull --rebase",
    out: "remote: Enumerating objects: 12, done.\nUnpacking objects: 100% (12/12), done.\nSuccessfully rebased and updated refs/heads/main.",
    exit: 0, dur: "1.2s", collapsed: false,
  },
  {
    cmd: "npm run build",
    out: "> app@0.4.1 build\n> vite build\n\nvite v6.0.3 building for production...\n✓ 214 modules transformed.\ndist/index.html          0.46 kB\ndist/assets/index.js   142.11 kB │ gzip: 45.90 kB\n✓ built in 3.42s",
    exit: 0, dur: "14.8s", collapsed: true,
  },
  {
    cmd: "systemctl restart nginx",
    out: "Failed to restart nginx.service: Access denied\nSee system logs and 'systemctl status nginx.service' for details.",
    exit: 1, dur: "0.1s", collapsed: false,
  },
];

function runFake(input) {
  const cmd = input.trim();
  const head = cmd.split(" ")[0];
  if (cmd === "ls")
    return { out: "Makefile      README.md    docs\npackage.json  server       src", exit: 0 };
  if (cmd === "pwd") return { out: "/home/yuki/projects/sshapp", exit: 0 };
  if (cmd === "whoami") return { out: "yuki", exit: 0 };
  if (cmd === "uptime")
    return { out: " 21:44:02 up 14 days,  3:12,  1 user,  load average: 0.21, 0.18, 0.11", exit: 0 };
  if (cmd === "git status")
    return { out: "On branch main\nYour branch is up to date with 'origin/main'.\n\nnothing to commit, working tree clean", exit: 0 };
  if (head === "echo") return { out: cmd.slice(5), exit: 0 };
  return { out: `zsh: command not found: ${head}`, exit: 127 };
}

// ---------- small pieces ----------
function ExitChip({ code }) {
  const ok = code === 0;
  return (
    <span
      className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md"
      style={{
        fontSize: 10, fontFamily: MONO,
        color: ok ? C.green : C.red,
        background: ok ? "rgba(79,190,139,0.12)" : "rgba(224,108,117,0.12)",
      }}
    >
      {ok ? <CircleCheck size={11} /> : <CircleX size={11} />}
      {ok ? "0" : code}
    </span>
  );
}

function Block({ b, onToggle, onRerun }) {
  return (
    <div className="flex gap-2.5">
      <div
        className="w-1 rounded-full shrink-0"
        style={{ background: b.exit === 0 ? C.green : C.red, opacity: 0.85 }}
      />
      <div
        className="flex-1 rounded-xl overflow-hidden"
        style={{ background: C.panel2, border: `1px solid ${C.line}` }}
      >
        <button
          onClick={onToggle}
          className="w-full flex items-center gap-2 px-3 py-2.5 text-left"
        >
          <span style={{ color: C.blue, fontFamily: MONO, fontSize: 13 }}>❯</span>
          <span
            className="flex-1 truncate"
            style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: C.text }}
          >
            {b.cmd}
          </span>
          <span style={{ fontFamily: MONO, fontSize: 10, color: C.dim }}>{b.dur}</span>
          <ExitChip code={b.exit} />
          <span
            className="p-1 rounded-md"
            style={{ color: C.dim }}
            onClick={(e) => { e.stopPropagation(); onRerun(); }}
            role="button"
            aria-label="再実行"
          >
            <RotateCw size={13} />
          </span>
        </button>
        {!b.collapsed && (
          <pre
            className="px-3 pb-3 pt-0 overflow-x-auto whitespace-pre-wrap"
            style={{ fontFamily: MONO, fontSize: 12, lineHeight: 1.55, color: C.mono, margin: 0 }}
          >
            {b.out}
          </pre>
        )}
        {b.collapsed && (
          <div className="px-3 pb-2.5" style={{ fontSize: 11, color: C.dim, fontFamily: UI }}>
            {b.out.split("\n").length} 行の出力 — タップで展開
          </div>
        )}
      </div>
    </div>
  );
}

function PaneShell({ id, title, expanded, anyExpanded, onExpand, children }) {
  if (anyExpanded && !expanded) return null;
  return (
    <div
      className={`flex flex-col overflow-hidden ${expanded ? "flex-1" : ""}`}
      style={{
        background: C.panel, border: "1px solid #2E3850", borderRadius: 18,
        boxShadow: "0 16px 44px rgba(0,0,0,0.65)", margin: "4px 2px",
        minHeight: expanded ? 0 : 150,
      }}
    >
      <div
        className="flex items-center gap-2 px-3 py-1.5 shrink-0"
        style={{ borderBottom: `1px solid ${C.line}` }}
      >
        <span style={{ fontFamily: MONO, fontSize: 10, color: C.blue }}>{id}</span>
        <span className="flex-1" style={{ fontFamily: MONO, fontSize: 11, color: C.dim }}>
          {title}
        </span>
        <button onClick={onExpand} style={{ color: C.dim }} aria-label="ペインを拡大">
          {expanded ? <Minimize2 size={13} /> : <Maximize2 size={13} />}
        </button>
      </div>
      <div className="flex-1 overflow-auto">{children}</div>
    </div>
  );
}

function HtopPane() {
  const cpus = [34, 61, 12, 48];
  const procs = [
    ["  312", "yuki", "12.4", "node server.js"],
    [" 8841", "yuki", " 8.9", "claude"],
    ["    1", "root", " 0.1", "systemd"],
    ["  977", "yuki", " 0.0", "tmux: server"],
  ];
  return (
    <div className="p-3" style={{ fontFamily: MONO, fontSize: 11, lineHeight: 1.7 }}>
      {cpus.map((v, i) => (
        <div key={i} className="flex items-center gap-2">
          <span style={{ color: C.dim }}>CPU{i}</span>
          <div className="flex-1 h-2 rounded-sm overflow-hidden" style={{ background: "#1A2130" }}>
            <div
              className="h-full"
              style={{ width: `${v}%`, background: v > 55 ? C.amber : C.green }}
            />
          </div>
          <span style={{ color: C.mono, width: 34, textAlign: "right" }}>{v}%</span>
        </div>
      ))}
      <div className="flex items-center gap-2 mt-1">
        <span style={{ color: C.dim }}>Mem </span>
        <div className="flex-1 h-2 rounded-sm overflow-hidden" style={{ background: "#1A2130" }}>
          <div className="h-full" style={{ width: "42%", background: C.blue }} />
        </div>
        <span style={{ color: C.mono }}>6.7G/16G</span>
      </div>
      <div className="mt-2" style={{ color: C.dim }}>  PID USER  CPU%  Command</div>
      {procs.map((p, i) => (
        <div key={i} style={{ color: i === 0 ? C.text : C.mono }}>
          {p[0]} {p[1]}  {p[2]}  {p[3]}
        </div>
      ))}
    </div>
  );
}

function TailPane() {
  const rows = [
    ["21:43:58", "INFO ", "request GET /api/health 200 3ms"],
    ["21:44:01", "INFO ", "request GET /api/items 200 41ms"],
    ["21:44:07", "WARN ", "slow query: items_by_tag (312ms)"],
    ["21:44:12", "INFO ", "ws client connected (3 total)"],
    ["21:44:19", "ERROR", "upstream timeout: billing-svc"],
    ["21:44:20", "INFO ", "retrying billing-svc (1/3)"],
  ];
  const col = (l) => (l === "ERROR" ? C.red : l === "WARN " ? C.amber : C.green);
  return (
    <div className="p-3" style={{ fontFamily: MONO, fontSize: 11, lineHeight: 1.8 }}>
      {rows.map((r, i) => (
        <div key={i} className="whitespace-nowrap">
          <span style={{ color: C.dim }}>{r[0]} </span>
          <span style={{ color: col(r[1]) }}>{r[1]}</span>
          <span style={{ color: C.mono }}> {r[2]}</span>
        </div>
      ))}
      <div style={{ color: C.dim }}>▍</div>
    </div>
  );
}

function ClaudePane() {
  return (
    <div className="p-3 h-full flex flex-col" style={{ fontFamily: MONO, fontSize: 12 }}>
      <div style={{ color: C.amber }}>✳ Claude Code v2.1 — sshapp</div>
      <div className="mt-2" style={{ color: C.mono, lineHeight: 1.6 }}>
        ⏺ SwiftTermのフォント自動フィットを実装しました。{"\n"}
        変更: <span style={{ color: C.blue }}>TerminalView.swift</span> (+48 −6)
      </div>
      <div
        className="mt-auto rounded-lg px-3 py-2"
        style={{ border: `1px solid ${C.line}`, color: C.dim }}
      >
        › 指示を入力…
      </div>
      <div className="mt-2" style={{ fontSize: 10, color: C.dim, fontFamily: UI }}>
        TUIフォールバック表示（グリッドをそのまま描画）
      </div>
    </div>
  );
}

function PsqlPane() {
  return (
    <pre className="p-3 m-0" style={{ fontFamily: MONO, fontSize: 11.5, lineHeight: 1.6, color: C.mono }}>
{`app_db=# SELECT status, count(*)
         FROM jobs GROUP BY 1;
 status  | count
---------+-------
 done    |  4102
 running |    17
 failed  |     3
(3 rows)

app_db=# ▍`}
    </pre>
  );
}

function MiniShell({ id }) {
  return (
    <div className="p-3" style={{ fontFamily: MONO, fontSize: 12, lineHeight: 1.8 }}>
      <div style={{ color: C.dim }}>split-window で作成された新規ペイン（{id}）</div>
      <div>
        <span style={{ color: C.blue }}>❯</span> <span style={{ color: C.dim }}>▍</span>
      </div>
    </div>
  );
}

const CARD_SHADOW = "0 16px 44px rgba(0,0,0,0.65)";

function PaneDeck({ showToast }) {
  const [panes, setPanes] = useState([
    { id: "%1", title: "htop", x: 0, y: 0, kind: "htop" },
    { id: "%2", title: "tail -f /var/log/app.log", x: 0, y: 1, kind: "tail" },
    { id: "%3", title: "psql app_db", x: 1, y: 0, kind: "psql" },
  ]);
  const [focus, setFocus] = useState({ x: 0, y: 0 });
  const [offset, setOffset] = useState({ dx: 0, dy: 0 });
  const [dragging, setDragging] = useState(false);
  const nextId = useRef(4);
  const start = useRef(null);
  const offRef = useRef({ dx: 0, dy: 0 });
  const moved = useRef(false);

  const M = 8;        // デッキ外周マージン
  const PEEK = 16;    // 隣カードが覗く量（1枚目）
  const EXTRA = 8;    // 2枚目以降が追加で覗く量
  const UNDER = 12;   // 隣カードがフォーカスカードの下に潜る量
  const CROSS = 26;   // 覗きカードを交差軸方向に狭める量
  const STEP = 6;     // 奥のカードほどさらに狭める量

  const band = (n) => (n ? PEEK + (n - 1) * EXTRA : 0);

  const at = (x, y) => panes.find((p) => p.x === x && p.y === y);
  const above = panes.filter((p) => p.x === focus.x && p.y < focus.y).sort((a, b) => a.y - b.y);
  const below = panes.filter((p) => p.x === focus.x && p.y > focus.y).sort((a, b) => a.y - b.y);
  const lefts = panes.filter((p) => p.y === focus.y && p.x < focus.x).sort((a, b) => a.x - b.x);
  const rights = panes.filter((p) => p.y === focus.y && p.x > focus.x).sort((a, b) => a.x - b.x);

  const move = (dx, dy) => {
    const nx = focus.x + dx, ny = focus.y + dy;
    const t = at(nx, ny);
    if (t) {
      setFocus({ x: nx, y: ny });
      showToast(`select-pane -t ${t.id} を送信`);
    } else {
      const id = `%${nextId.current++}`;
      const flag = dx !== 0 ? "-h" : "-v";
      const back = dx < 0 || dy < 0 ? " -b" : "";
      setPanes((ps) => [...ps, { id, title: "zsh", x: nx, y: ny, kind: "shell" }]);
      setFocus({ x: nx, y: ny });
      showToast(`split-window ${flag}${back} を送信 → ${id} を作成`);
    }
  };

  const onPointerDown = (e) => {
    start.current = { x: e.clientX, y: e.clientY };
    moved.current = false;
    setDragging(true);
    e.currentTarget.setPointerCapture?.(e.pointerId);
  };
  const onPointerMove = (e) => {
    if (!start.current) return;
    const dx = e.clientX - start.current.x;
    const dy = e.clientY - start.current.y;
    if (Math.abs(dx) + Math.abs(dy) > 8) moved.current = true;
    const o = Math.abs(dx) > Math.abs(dy) ? { dx, dy: 0 } : { dx: 0, dy };
    offRef.current = o;
    setOffset(o);
  };
  const endDrag = () => {
    const o = offRef.current;
    start.current = null;
    offRef.current = { dx: 0, dy: 0 };
    setOffset({ dx: 0, dy: 0 });
    setDragging(false);
    if (Math.abs(o.dx) > 50) move(o.dx < 0 ? 1 : -1, 0);
    else if (Math.abs(o.dy) > 50) move(0, o.dy < 0 ? 1 : -1);
  };

  const body = (p) =>
    p.kind === "htop" ? <HtopPane /> :
    p.kind === "tail" ? <TailPane /> :
    p.kind === "psql" ? <PsqlPane /> : <MiniShell id={p.id} />;

  const ease = "cubic-bezier(.3,.9,.3,1)";
  const trans = dragging
    ? "none"
    : `top .32s ${ease}, bottom .32s ${ease}, left .32s ${ease}, right .32s ${ease}, width .32s ${ease}, height .32s ${ease}, transform .32s ${ease}`;

  const Card = ({ p, style, z, peek }) => (
    <div
      onClick={
        peek
          ? () => {
              if (moved.current) return;
              setFocus({ x: p.x, y: p.y });
              showToast(`select-pane -t ${p.id} を送信`);
            }
          : undefined
      }
      style={{
        position: "absolute",
        background: C.panel2,
        border: `1px solid ${peek ? "#2A3242" : "#2E3850"}`,
        borderRadius: 18,
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        transition: trans,
        zIndex: z,
        boxShadow: CARD_SHADOW,
        cursor: peek ? "pointer" : "default",
        ...style,
      }}
    >
      <div
        className="flex items-center gap-2 px-3 shrink-0"
        style={{ height: 40, borderBottom: `1px solid ${C.line}` }}
      >
        <span style={{ fontFamily: MONO, fontSize: 10, color: C.blue }}>{p.id}</span>
        <span
          className="flex-1 truncate"
          style={{ fontFamily: MONO, fontSize: 11, color: peek ? C.dim : C.mono }}
        >
          {p.title}
        </span>
      </div>
      <div className="flex-1" style={{ overflow: "hidden", opacity: peek ? 0.4 : 1 }}>
        {body(p)}
      </div>
    </div>
  );

  const cards = [];
  const bAbove = band(above.length);
  const bBelow = band(below.length);
  const bLeft = band(lefts.length);
  const bRight = band(rights.length);

  // 上：カードの下辺だけがフォーカスカードの上端から覗く
  above.forEach((p, i) => {
    const q = above.length - 1 - i; // 0 = フォーカスに最も近い
    const bottomEdge = M + bAbove + UNDER - q * EXTRA;
    const side = M + CROSS + q * STEP;
    cards.push(
      <Card key={p.id} p={p} peek z={above.length - 1 - q}
        style={{
          bottom: `calc(100% - ${bottomEdge}px)`,
          top: -(200), left: side, right: side,
        }} />
    );
  });
  // 下：カードの上辺だけが覗く
  below.forEach((p, j) => {
    const q = j; // 0 = 最も近い
    const topEdge = M + bBelow + UNDER - q * EXTRA;
    const side = M + CROSS + q * STEP;
    cards.push(
      <Card key={p.id} p={p} peek z={below.length - 1 - q}
        style={{
          top: `calc(100% - ${topEdge}px)`,
          bottom: -(200), left: side, right: side,
        }} />
    );
  });
  // 左：カードの右辺だけが覗く
  lefts.forEach((p, i) => {
    const q = lefts.length - 1 - i;
    const rightEdge = M + bLeft + UNDER - q * EXTRA;
    const side = M + CROSS + q * STEP;
    cards.push(
      <Card key={p.id} p={p} peek z={lefts.length - 1 - q}
        style={{
          right: `calc(100% - ${rightEdge}px)`,
          left: -(200), top: side, bottom: side,
        }} />
    );
  });
  // 右：カードの左辺だけが覗く
  rights.forEach((p, k) => {
    const q = k;
    const leftEdge = M + bRight + UNDER - q * EXTRA;
    const side = M + CROSS + q * STEP;
    cards.push(
      <Card key={p.id} p={p} peek z={rights.length - 1 - q}
        style={{
          left: `calc(100% - ${leftEdge}px)`,
          right: -(200), top: side, bottom: side,
        }} />
    );
  });
  // 斜め位置は畳む
  panes
    .filter((p) => p.x !== focus.x && p.y !== focus.y)
    .forEach((p) => {
      cards.push(
        <Card key={p.id} p={p} peek z={0}
          style={{ inset: 24, opacity: 0, pointerEvents: "none" }} />
      );
    });

  // フォーカスカード：隣がある側だけ最小限の帯を空け、最大サイズを保つ
  const f = at(focus.x, focus.y);
  if (f) {
    cards.push(
      <Card key={f.id} p={f} z={40}
        style={{
          top: M + bAbove,
          bottom: M + bBelow,
          left: M + bLeft,
          right: M + bRight,
          transform: `translate(${offset.dx * 0.95}px, ${offset.dy * 0.95}px)`,
        }} />
    );
  }

  return (
    <div
      className="flex-1 relative min-h-0"
      style={{ touchAction: "none", overflow: "hidden" }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
    >
      {cards}
    </div>
  );
}

// ---------- main ----------
export default function App() {
  const [drawer, setDrawer] = useState(false);
  const [sess, setSess] = useState("main");
  const [win, setWin] = useState(0);
  const [openSess, setOpenSess] = useState({ main: true });
  const [blocks, setBlocks] = useState(INITIAL_BLOCKS);
  const [input, setInput] = useState("");
  const [expanded, setExpanded] = useState(null);
  const [toast, setToast] = useState(null);
  const scrollRef = useRef(null);

  const session = SESSIONS.find((s) => s.name === sess);
  const window_ = session.windows.find((w) => w.id === win) || session.windows[0];

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: 999999, behavior: "smooth" });
  }, [blocks]);

  const showToast = (msg) => {
    setToast(msg);
    setTimeout(() => setToast(null), 2600);
  };

  const selectWindow = (sName, wId) => {
    setSess(sName); setWin(wId); setDrawer(false); setExpanded(null);
    const w = SESSIONS.find((s) => s.name === sName).windows.find((x) => x.id === wId);
    if (w?.type === "split")
      showToast("resize-pane -Z を送信 — フォーカスペインを全画面同期");
  };

  const run = (cmd) => {
    if (!cmd.trim()) return;
    const r = runFake(cmd);
    setBlocks((b) => [...b, { cmd: cmd.trim(), out: r.out, exit: r.exit, dur: "0.2s", collapsed: false }]);
    setInput("");
  };

  const keys = ["esc", "tab", "ctrl", "C-b", "↑", "↓", "←", "→"];

  return (
    <div className="h-screen w-full flex flex-col" style={{ background: C.bg, fontFamily: UI, color: C.text }}>

      {/* header */}
      <div className="flex items-center gap-2 px-3 pt-3 pb-2 shrink-0">
        <button
          onClick={() => setDrawer(true)}
          className="p-2 rounded-xl"
          style={{ background: C.panel, border: `1px solid ${C.line}` }}
          aria-label="セッション一覧"
        >
          <Menu size={17} />
        </button>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1.5">
            <span className="truncate" style={{ fontSize: 15, fontWeight: 700 }}>
              {sess}
            </span>
            <span style={{ color: C.dim, fontSize: 13 }}>· {window_.name}</span>
          </div>
          <div className="flex items-center gap-1.5" style={{ fontSize: 10.5, color: C.dim }}>
            <span className="w-1.5 h-1.5 rounded-full" style={{ background: C.green }} />
            dev-box · tmux -CC 接続中
          </div>
        </div>
      </div>

      {/* window tabs */}
      <div className="flex gap-1.5 px-3 pb-2 overflow-x-auto shrink-0">
        {session.windows.map((w) => {
          const active = w.id === window_.id;
          return (
            <button
              key={w.id}
              onClick={() => selectWindow(sess, w.id)}
              className="px-3 py-1.5 rounded-lg whitespace-nowrap"
              style={{
                fontFamily: MONO, fontSize: 12,
                color: active ? C.text : C.dim,
                background: active ? C.panel2 : "transparent",
                border: `1px solid ${active ? C.blue + "55" : C.line}`,
              }}
            >
              {w.id}:{w.name}
            </button>
          );
        })}
        <button
          className="px-2.5 py-1.5 rounded-lg"
          style={{ color: C.dim, border: `1px dashed ${C.line}` }}
          onClick={() => showToast("new-window を送信")}
          aria-label="新規ウィンドウ"
        >
          <Plus size={13} />
        </button>
      </div>

      {/* content */}
      <div className="flex-1 min-h-0 px-3 pb-2 flex flex-col gap-2">
        {window_.type === "chat" && (
          <div
            className="flex-1 min-h-0 flex flex-col overflow-hidden"
            style={{
              background: C.panel, border: "1px solid #2E3850", borderRadius: 18,
              boxShadow: "0 16px 44px rgba(0,0,0,0.65)", margin: "4px 2px",
            }}
          >
            <div
              className="flex items-center gap-2 px-3 shrink-0"
              style={{ height: 40, borderBottom: `1px solid ${C.line}` }}
            >
              <span style={{ fontFamily: MONO, fontSize: 10, color: C.blue }}>%0</span>
              <span className="flex-1 truncate" style={{ fontFamily: MONO, fontSize: 11, color: C.mono }}>
                zsh — ~/projects/sshapp
              </span>
            </div>
            <div ref={scrollRef} className="flex-1 overflow-y-auto flex flex-col gap-2.5 p-3">
              {blocks.map((b, i) => (
                <Block
                  key={i}
                  b={b}
                  onToggle={() =>
                    setBlocks((bs) => bs.map((x, j) => (j === i ? { ...x, collapsed: !x.collapsed } : x)))
                  }
                  onRerun={() => run(b.cmd)}
                />
              ))}
            </div>
          </div>
        )}

        {window_.type === "split" && (
          <PaneDeck key={`${sess}:${window_.id}`} showToast={showToast} />
        )}

        {window_.type === "claude" && (
          <div className="flex-1 min-h-0">
            <PaneShell
              id="%0" title="claude" expanded anyExpanded={false} onExpand={() => {}}
            >
              <ClaudePane />
            </PaneShell>
          </div>
        )}
      </div>

      {/* key accessory bar */}
      <div className="flex gap-1.5 px-3 pb-2 overflow-x-auto shrink-0">
        {keys.map((k) => (
          <button
            key={k}
            className="px-3 py-1.5 rounded-lg shrink-0"
            style={{
              fontFamily: MONO, fontSize: 11.5, color: C.mono,
              background: C.panel, border: `1px solid ${C.line}`,
            }}
            onClick={() => showToast(`キー送信: ${k}`)}
          >
            {k}
          </button>
        ))}
      </div>

      {/* input bar */}
      <div className="flex items-center gap-2 px-3 pb-4 shrink-0">
        {window_.type === "chat" ? (
          <>
            <div
              className="flex-1 flex items-center gap-2 rounded-2xl px-3.5 py-2.5"
              style={{ background: C.panel2, border: `1px solid ${C.line}` }}
            >
              <span style={{ color: C.blue, fontFamily: MONO }}>❯</span>
              <input
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && run(input)}
                placeholder="コマンドを入力（ls, git status…）"
                className="flex-1 bg-transparent outline-none"
                style={{ fontFamily: MONO, fontSize: 14, color: C.text }}
              />
            </div>
            <button
              onClick={() => run(input)}
              className="p-3 rounded-2xl"
              style={{ background: C.blue, color: "#0B0D11" }}
              aria-label="実行"
            >
              <Send size={16} />
            </button>
          </>
        ) : (
          <div
            className="flex-1 flex items-center gap-2 rounded-2xl px-3.5 py-2.5"
            style={{ background: C.panel, border: `1px dashed ${C.line}`, color: C.dim, fontSize: 12.5 }}
          >
            <Keyboard size={15} />
            TUIモード — キー入力を直接ペインに送信
          </div>
        )}
      </div>

      {/* toast */}
      {toast && (
        <div
          className="absolute left-1/2 -translate-x-1/2 px-4 py-2 rounded-xl z-30"
          style={{
            top: 118, background: "#1C2330", border: `1px solid ${C.line}`,
            color: C.mono, fontSize: 12, fontFamily: MONO, maxWidth: "88%",
          }}
        >
          {toast}
        </div>
      )}

      {/* sidebar drawer */}
      {drawer && (
        <div className="absolute inset-0 z-20 flex">
          <div
            className="h-full w-72 max-w-[80%] flex flex-col p-3 gap-1 overflow-y-auto"
            style={{ background: C.panel, borderRight: `1px solid ${C.line}` }}
          >
            <div className="flex items-center justify-between px-1 pb-2">
              <span style={{ fontSize: 13, fontWeight: 700 }}>セッション</span>
              <button onClick={() => setDrawer(false)} style={{ color: C.dim }} aria-label="閉じる">
                <X size={16} />
              </button>
            </div>
            {SESSIONS.map((s) => (
              <div key={s.name}>
                <button
                  onClick={() => setOpenSess((o) => ({ ...o, [s.name]: !o[s.name] }))}
                  className="w-full flex items-center gap-1.5 px-2 py-2 rounded-lg"
                  style={{ color: s.name === sess ? C.text : C.mono }}
                >
                  {openSess[s.name] ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                  <span style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600 }}>{s.name}</span>
                  <span className="ml-auto" style={{ fontSize: 10, color: C.dim }}>
                    {s.windows.length}w
                  </span>
                </button>
                {openSess[s.name] &&
                  s.windows.map((w) => {
                    const active = s.name === sess && w.id === window_.id;
                    return (
                      <button
                        key={w.id}
                        onClick={() => selectWindow(s.name, w.id)}
                        className="w-full text-left pl-8 pr-2 py-1.5 rounded-lg"
                        style={{
                          fontFamily: MONO, fontSize: 12.5,
                          color: active ? C.blue : C.dim,
                          background: active ? "rgba(111,168,255,0.08)" : "transparent",
                        }}
                      >
                        {w.id}:{w.name}
                      </button>
                    );
                  })}
              </div>
            ))}
            <button
              className="mt-2 flex items-center gap-1.5 px-2 py-2 rounded-lg"
              style={{ color: C.dim, border: `1px dashed ${C.line}`, fontSize: 12.5 }}
              onClick={() => showToast("new-session を送信")}
            >
              <Plus size={14} /> 新しいセッション
            </button>
          </div>
          <div className="flex-1" style={{ background: "rgba(0,0,0,0.5)" }} onClick={() => setDrawer(false)} />
        </div>
      )}
    </div>
  );
}
