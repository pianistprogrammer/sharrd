import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Activity,
  Apple,
  Boxes,
  CheckCircle2,
  Check,
  ChevronDown,
  ChevronUp,
  Clipboard,
  Cpu,
  Eraser,
  FolderOpen,
  HardDrive,
  Layers3,
  Moon,
  Network,
  Play,
  RotateCcw,
  Search,
  Server,
  Settings2,
  Square,
  Sun,
  Terminal,
  TriangleAlert,
  type LucideIcon,
} from "lucide-react";
import type { ReactNode } from "react";
import { useEffect, useMemo, useRef, useState } from "react";

type Role = "host" | "worker";
type Stack = "apple" | "nvidia";
type TargetOs = "macos" | "windows" | "linux";
type Mode = "server" | "cli";

type LaunchOptions = {
  role: Role;
  stack: Stack;
  targetOs: TargetOs;
  shellPath: string;
  llamaDir: string;
  modelPath: string;
  context: string;
  serverHost: string;
  serverPort: string;
  rpcPort: string;
  discoveryPort: string;
  discoverySeconds: string;
  mode: Mode;
  useAllWorkers: boolean;
  useCache: boolean;
  manualRpcServers: string;
};

type HostInfo = {
  os: string;
  arch: string;
  defaultStack: Stack;
  defaultTargetOs: TargetOs;
  networkHost: string;
};

type EnvVar = {
  key: string;
  value: string;
};

type LaunchPreview = {
  shell: string;
  command: string;
  environment: EnvVar[];
  requirements: string[];
  notes: string[];
};

type LogEvent = {
  sessionId: string;
  stream: "stdout" | "stderr" | "system";
  line: string;
};

type SessionEvent = {
  sessionId: string;
  status: string;
  code?: number | null;
};

type DistributionItem = {
  label: string;
  detail: string;
  percent?: number;
  exact?: boolean;
};

type WorkerNode = {
  label: string;
  endpoint: string;
};

type StageState = "pending" | "active" | "complete" | "blocked";

type SystemStage = {
  label: string;
  detail: string;
  state: StageState;
};

type TauriWindow = Window & {
  __TAURI_INTERNALS__?: unknown;
};

const defaultOptions: LaunchOptions = {
  role: "host",
  stack: "apple",
  targetOs: "macos",
  shellPath: "",
  llamaDir: "",
  modelPath: "",
  context: "8192",
  serverHost: "0.0.0.0",
  serverPort: "8080",
  rpcPort: "50052",
  discoveryPort: "50053",
  discoverySeconds: "4",
  mode: "server",
  useAllWorkers: true,
  useCache: true,
  manualRpcServers: "",
};

const roleOptions = [
  {
    value: "host" as Role,
    label: "Start model",
    icon: Server,
  },
  {
    value: "worker" as Role,
    label: "Share GPU",
    icon: Network,
  },
];

const stackOptions = [
  {
    value: "apple" as Stack,
    label: "Apple Silicon",
    icon: Apple,
  },
  {
    value: "nvidia" as Stack,
    label: "NVIDIA CUDA",
    icon: Cpu,
  },
];

const osOptions = [
  { value: "macos" as TargetOs, label: "macOS" },
  { value: "windows" as TargetOs, label: "Windows" },
  { value: "linux" as TargetOs, label: "Linux" },
];

const modeOptions = [
  { value: "server" as Mode, label: "Server" },
  { value: "cli" as Mode, label: "CLI" },
];

function getSystemTheme(): "dark" | "light" {
  if (typeof window === "undefined") return "dark";
  return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

function App() {
  const [options, setOptions] = useState<LaunchOptions>(defaultOptions);
  const [hostInfo, setHostInfo] = useState<HostInfo | null>(null);
  const [preview, setPreview] = useState<LaunchPreview | null>(null);
  const [logs, setLogs] = useState<LogEvent[]>([]);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [ready, setReady] = useState(false);
  const [status, setStatus] = useState("Ready");
  const [error, setError] = useState<string | null>(null);
  const [logsOpen, setLogsOpen] = useState(false);
  const [copyStatus, setCopyStatus] = useState<"idle" | "copied">("idle");
  const [copyLogsStatus, setCopyLogsStatus] = useState<"idle" | "copied">("idle");
  const [logFilter, setLogFilter] = useState("");
  const [autoscroll, setAutoscroll] = useState(true);
  const [systemTheme, setSystemTheme] = useState<"dark" | "light">(() => getSystemTheme());
  const [themeOverride, setThemeOverride] = useState<"dark" | "light" | null>(null);
  const activeSessionRef = useRef<string | null>(null);
  const waitsForServerRef = useRef(false);
  const modelPathInputRef = useRef<HTMLInputElement | null>(null);
  const rpcPortInputRef = useRef<HTMLInputElement | null>(null);
  const logWindowRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!isTauriRuntime()) {
      setHostInfo({
        os: "browser",
        arch: "preview",
        defaultStack: "apple",
        defaultTargetOs: "macos",
        networkHost: "192.168.1.24",
      });
      setStatus("Browser preview");
      return;
    }

    invoke<HostInfo>("detect_host")
      .then((info) => {
        setHostInfo(info);
        setOptions((current) => ({
          ...current,
          stack: info.defaultStack,
          targetOs: info.defaultStack === "apple" ? "macos" : info.defaultTargetOs,
          context: info.defaultStack === "apple" ? "8192" : "4096",
          serverHost: "0.0.0.0",
        }));
      })
      .catch(() => {
        setStatus("Browser preview");
      });
  }, []);

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: light)");
    const updateSystemTheme = () => setSystemTheme(media.matches ? "light" : "dark");

    updateSystemTheme();
    media.addEventListener("change", updateSystemTheme);
    return () => media.removeEventListener("change", updateSystemTheme);
  }, []);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        focusPrimaryInput();
      }
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  useEffect(() => {
    const unlisteners = Promise.all([
      listen<LogEvent>("session-log", (event) => {
        setLogs((current) => [...current.slice(-799), event.payload]);
        if (
          event.payload.sessionId === activeSessionRef.current &&
          waitsForServerRef.current &&
          isServerReadyLine(event.payload.line)
        ) {
          setReady(true);
          setStatus("Running");
        }
      }),
      listen<SessionEvent>("session-ended", (event) => {
        if (event.payload.sessionId !== activeSessionRef.current) return;

        setRunning(false);
        setReady(false);
        activeSessionRef.current = null;
        waitsForServerRef.current = false;
        setSessionId(null);
        const code = event.payload.code;
        setStatus(code == null ? event.payload.status : `${event.payload.status} (${code})`);
      }),
    ]);

    return () => {
      unlisteners.then((items) => items.forEach((unlisten) => unlisten()));
    };
  }, []);

  useEffect(() => {
    if (!isTauriRuntime()) {
      setPreview(buildBrowserPreview(options));
      setError(null);
      return;
    }

    invoke<LaunchPreview>("build_preview", { options })
      .then((nextPreview) => {
        setPreview(nextPreview);
        setError(null);
      })
      .catch((err) => {
        setPreview(null);
        setError(String(err));
      });
  }, [options]);

  const canStart = useMemo(() => {
    if (running || error) return false;
    if (options.role === "host" && options.modelPath.trim().length === 0) return false;
    return Boolean(preview);
  }, [error, options.modelPath, options.role, preview, running]);

  const updateOption = <Key extends keyof LaunchOptions>(key: Key, value: LaunchOptions[Key]) => {
    setOptions((current) => {
      const next = { ...current, [key]: value };

      if (key === "stack") {
        if (value === "apple") {
          next.targetOs = "macos";
          next.context = current.context === "4096" ? "8192" : current.context;
        } else if (current.targetOs === "macos") {
          next.targetOs = "windows";
          next.context = current.context === "8192" ? "4096" : current.context;
        }
      }

      if (key === "targetOs" && value === "macos") {
        next.stack = "apple";
      }

      if (key === "targetOs" && value !== "macos") {
        next.stack = "nvidia";
      }

      return next;
    });
  };

  const start = async () => {
    setError(null);
    setLogs([]);
    setStatus("Starting");
    setReady(false);
    try {
      const id = await invoke<string>("start_session", { options });
      const waitsForServer = options.role === "host" && options.mode === "server";
      activeSessionRef.current = id;
      waitsForServerRef.current = waitsForServer;
      setSessionId(id);
      setRunning(true);
      setReady(!waitsForServer);
      setStatus(waitsForServer ? "Loading" : "Running");
    } catch (err) {
      setStatus("Ready");
      setReady(false);
      setError(String(err));
    }
  };

  const stop = async () => {
    if (!sessionId) return;
    setStatus("Stopping");
    try {
      await invoke("stop_session", { sessionId });
    } catch (err) {
      setError(String(err));
      setStatus("Running");
    }
  };

  const restart = async () => {
    if (!running || !sessionId) return;
    setStatus("Restarting");
    try {
      await invoke("stop_session", { sessionId });
      activeSessionRef.current = null;
      waitsForServerRef.current = false;
      setSessionId(null);
      setRunning(false);
      setReady(false);
      window.setTimeout(() => {
        void start();
      }, 700);
    } catch (err) {
      setError(String(err));
      setStatus("Running");
    }
  };

  const chooseModelPath = async () => {
    setError(null);
    if (!isTauriRuntime()) {
      updateOption("modelPath", "/Users/me/Models/Meta-Llama-3.1-70B-Instruct.Q4_K_M.gguf");
      return;
    }

    try {
      const selected = await open({
        multiple: false,
        directory: false,
      });

      if (typeof selected === "string") {
        updateOption("modelPath", selected);
      }
    } catch (err) {
      setError(String(err));
    }
  };

  const sessionLogs = useMemo(
    () => (sessionId ? logs.filter((entry) => entry.sessionId === sessionId) : logs),
    [logs, sessionId],
  );
  const serverUrl = getServerUrl(options, hostInfo);
  const serverListening = useMemo(() => hasLog(sessionLogs, (line) => isServerReadyLine(line)), [sessionLogs]);
  const sessionLive = Boolean(sessionId) && running;
  const showServerUrl = options.role === "host" && options.mode === "server" && sessionLive;
  const distribution = useMemo(() => getLoadDistribution(sessionLogs), [sessionLogs]);
  const workerNodes = useMemo(() => getWorkerNodes(sessionLogs), [sessionLogs]);
  const filteredLogs = useMemo(() => filterLogs(logs, logFilter), [logFilter, logs]);
  const sessionPid = useMemo(() => getSessionPid(logs, sessionId), [logs, sessionId]);
  const activeRequirements = preview?.requirements ?? [];
  const systemStages = useMemo(
    () => getSystemStages(options, sessionLogs, sessionLive, ready || serverListening, status, error),
    [error, options, ready, serverListening, sessionLive, sessionLogs, status],
  );
  const modelName = useMemo(() => getModelDisplayName(options.modelPath), [options.modelPath]);
  const clusterLabel = getClusterLabel(options, sessionLive, workerNodes.length);
  const theme = themeOverride ?? systemTheme;

  useEffect(() => {
    if (serverListening && sessionLive && waitsForServerRef.current && !ready) {
      setReady(true);
      setStatus("Running");
    }
  }, [ready, serverListening, sessionLive]);

  useEffect(() => {
    if (!autoscroll || !logsOpen) return;
    const element = logWindowRef.current;
    if (!element) return;
    element.scrollTop = element.scrollHeight;
  }, [autoscroll, filteredLogs.length, logsOpen]);

  const focusPrimaryInput = () => {
    const input = options.role === "host" ? modelPathInputRef.current : rpcPortInputRef.current;
    input?.focus();
    input?.select();
  };

  const copyServerUrl = async () => {
    setError(null);
    try {
      await navigator.clipboard.writeText(serverUrl);
      setCopyStatus("copied");
      window.setTimeout(() => setCopyStatus("idle"), 1400);
    } catch (err) {
      setError(`Could not copy the server URL: ${String(err)}`);
    }
  };

  const copyLogs = async () => {
    setError(null);
    try {
      await navigator.clipboard.writeText(logs.map((entry) => `${entry.stream.toUpperCase()} ${entry.line}`).join("\n"));
      setCopyLogsStatus("copied");
      window.setTimeout(() => setCopyLogsStatus("idle"), 1400);
    } catch (err) {
      setError(`Could not copy logs: ${String(err)}`);
    }
  };

  return (
    <main className={theme === "light" ? "app-shell light-theme" : "app-shell"}>
      <div className="desktop-window">
        <header className="titlebar">
          <div className="brand-cluster">
            <div className="brand-mark">
              <Boxes size={16} />
              <strong>Sharrd</strong>
              <span>v1.4.2-dist</span>
            </div>
          </div>

          <div className="cluster-status">
            <StatusPill ready={ready} label={status} />
            {showServerUrl ? (
              <>
                <span className="status-divider" />
                <code>{serverUrl}</code>
                <button className="cluster-copy-button" onClick={copyServerUrl} type="button">
                  {copyStatus === "copied" ? <Check size={13} /> : <Clipboard size={13} />}
                  <span>{copyStatus === "copied" ? "Copied" : "Copy"}</span>
                </button>
              </>
            ) : null}
            {!showServerUrl ? <strong className="cluster-copy">{clusterLabel}</strong> : null}
          </div>

          <div className="title-actions">
            <button className="quick-find-button" onClick={focusPrimaryInput} type="button">
              <Search size={14} />
              <span>Quick Find</span>
              <kbd>⌘K</kbd>
            </button>
            <button
              aria-label="Toggle color theme"
              className="theme-button"
              onClick={() => setThemeOverride(theme === "dark" ? "light" : "dark")}
              type="button"
            >
              {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}
            </button>
          </div>
        </header>

        <div className="app-body">
          <aside className="control-rail">
            <div className="rail-section-label">Core engine</div>
            <Panel title="Role" icon={Activity}>
              <Segmented
                items={roleOptions}
                value={options.role}
                onChange={(value) => updateOption("role", value)}
              />
            </Panel>

            <Panel title="Stack" icon={HardDrive}>
              <Segmented
                items={stackOptions}
                value={options.stack}
                onChange={(value) => updateOption("stack", value)}
              />
            </Panel>

            <Panel title="Operating system" icon={Settings2}>
              <div className="os-grid">
                {osOptions.map((item) => {
                  const disabled = options.stack === "apple" && item.value !== "macos";
                  return (
                    <button
                      className={item.value === options.targetOs ? "os-button active" : "os-button"}
                      disabled={disabled}
                      key={item.value}
                      onClick={() => updateOption("targetOs", item.value)}
                      type="button"
                    >
                      {item.label}
                    </button>
                  );
                })}
              </div>
            </Panel>

            <Panel title="Run mode" icon={Terminal}>
              <Segmented
                compact
                disabled={options.role === "worker"}
                items={modeOptions}
                value={options.mode}
                onChange={(value) => updateOption("mode", value)}
              />
            </Panel>

            <div className="worker-block">
              <div className="rail-section-label">Active workers</div>
              <div className="worker-list">
                {workerNodes.length > 0 ? (
                  workerNodes.map((worker) => (
                    <div className="worker-card" key={worker.endpoint}>
                      <div>
                        <strong>{worker.label}</strong>
                        <span className="small-dot active" />
                      </div>
                      <code>{worker.endpoint}</code>
                      <p>
                        <span>RPC device</span>
                        <strong>Ready</strong>
                      </p>
                    </div>
                  ))
                ) : (
                  <div className="worker-card empty">
                    <div>
                      <strong>No worker yet</strong>
                      <span className="small-dot" />
                    </div>
                    <code>{options.stack === "apple" ? "Bonjour discovery" : "UDP discovery"}</code>
                    <p>
                      <span>{sessionLive ? "Waiting" : "Standby"}</span>
                      <strong>{sessionLive ? "Scanning" : "Idle"}</strong>
                    </p>
                  </div>
                )}
              </div>
            </div>

            <div className="rail-status-card">
              <span className={sessionLive ? "small-dot active" : "small-dot"} />
              <div>
                <strong>{sessionLive ? "Session active" : "Standing by"}</strong>
                <span>{options.stack === "apple" ? "Bonjour / Metal RPC" : "LAN RPC discovery"}</span>
              </div>
            </div>
          </aside>

          <section className="workbench">
            <div className="system-bar">
              <div className="requirement-strip">
                <span className="system-label">System State</span>
                {systemStages.map((stage) => (
                  <StageChip key={stage.label} stage={stage} />
                ))}
              </div>

              <div className="action-row">
                <button className="icon-button restart-button" disabled={!sessionId || !sessionLive} onClick={restart} title="Restart cluster pipeline" type="button">
                  <RotateCcw size={15} />
                </button>
                {sessionLive ? (
                  <button className="stop-button primary-stop-button" disabled={!sessionId} onClick={stop} type="button">
                    <Square size={15} />
                    <span>Stop Engine</span>
                  </button>
                ) : (
                  <button className="primary-button" disabled={!canStart} onClick={start} type="button">
                    <Play size={16} />
                    <span>{options.role === "host" ? "Distribute & Run" : "Share GPU"}</span>
                  </button>
                )}
              </div>
            </div>

            <div className="content-grid">
              <div className="main-stack">
              <section className="config-panel">
                <div className="section-heading">
                  <div>
                    <p className="eyebrow">Engine Configuration & Topology</p>
                    <h2>{options.role === "host" ? "Start a distributed GGUF model" : "Offer this machine as a worker"}</h2>
                  </div>
                  <span className="card-meta">llama.cpp cluster-native RPC</span>
                </div>

                {error ? <Alert message={error} /> : null}
                {options.role === "host" && options.modelPath.trim().length === 0 ? (
                  <Alert message="A GGUF model path is required for the model starter." tone="warn" />
                ) : null}

                <div className="form-grid">
                  {options.role === "host" ? (
                    <Field label="GGUF model path" className="span-4">
                      <div className="path-picker">
                        <input
                          ref={modelPathInputRef}
                          placeholder={options.targetOs === "windows" ? "/c/models/model.gguf" : "/Users/me/Models/model.gguf"}
                          value={options.modelPath}
                          onChange={(event) => updateOption("modelPath", event.target.value)}
                        />
                        <button className="browse-button" onClick={chooseModelPath} title="Choose GGUF model" type="button">
                          <FolderOpen size={17} />
                          <span>Browse</span>
                        </button>
                      </div>
                    </Field>
                  ) : null}

                  {options.role === "host" ? (
                    <>
                      <Field label="Context" className="span-2">
                        <div className="field-with-actions">
                          <input
                            inputMode="numeric"
                            value={options.context}
                            onChange={(event) => updateOption("context", event.target.value)}
                          />
                          <div className="mini-choices">
                            {["4096", "8192", "16384", "32768"].map((value) => (
                              <button
                                className={options.context === value ? "mini-choice active" : "mini-choice"}
                                key={value}
                                onClick={() => updateOption("context", value)}
                                type="button"
                              >
                                {Number(value) / 1024}k
                              </button>
                            ))}
                          </div>
                        </div>
                      </Field>

                      <Field label="Server bind">
                        <input
                          value={options.serverHost}
                          onChange={(event) => updateOption("serverHost", event.target.value)}
                        />
                      </Field>

                      <Field label="Server port">
                        <input
                          inputMode="numeric"
                          value={options.serverPort}
                          onChange={(event) => updateOption("serverPort", event.target.value)}
                        />
                      </Field>

                      <Field label="Discovery seconds">
                        <input
                          inputMode="numeric"
                          value={options.discoverySeconds}
                          onChange={(event) => updateOption("discoverySeconds", event.target.value)}
                        />
                      </Field>
                    </>
                  ) : (
                    <Field label="RPC port" className="span-2">
                      <input
                        ref={rpcPortInputRef}
                        inputMode="numeric"
                        value={options.rpcPort}
                        onChange={(event) => updateOption("rpcPort", event.target.value)}
                      />
                    </Field>
                  )}

                  <Field label="Discovery Port (RPC)" className={options.role === "worker" ? "span-2" : undefined}>
                    <input
                      inputMode="numeric"
                      value={options.discoveryPort}
                      onChange={(event) => updateOption("discoveryPort", event.target.value)}
                    />
                  </Field>

                  {options.stack === "nvidia" && options.role === "host" ? (
                    <Field label="Manual RPC endpoints" className="span-4">
                      <input
                        placeholder="192.168.1.11:50052,192.168.1.12:50052"
                        value={options.manualRpcServers}
                        onChange={(event) => updateOption("manualRpcServers", event.target.value)}
                      />
                    </Field>
                  ) : null}
                </div>

                <div className="toggle-row">
                  <div className="toggle-controls">
                    <Toggle
                      checked={options.useCache}
                      label="RPC Memory Cache"
                      onChange={(checked) => updateOption("useCache", checked)}
                    />
                    <Toggle
                      checked={options.useAllWorkers}
                      disabled={options.role === "worker"}
                      label="Auto-attach all discovered LAN workers"
                      onChange={(checked) => updateOption("useAllWorkers", checked)}
                    />
                  </div>
                  <div className="allocation-summary">
                    Active RPC workers: <strong>{workerNodes.length}</strong>
                  </div>
                </div>

                {options.role === "host" ? (
                  <DistributionCard
                    distribution={distribution}
                    modelPath={options.modelPath}
                    running={sessionLive}
                  />
                ) : null}
              </section>

              </div>

              <aside className="side-stack">
                <section className="summary-panel">
                  <div className="section-heading compact-heading">
                    <div>
                      <p className="eyebrow">Preset</p>
                      <h2>{preview ? presetTitle(options) : "Not selected"}</h2>
                    </div>
                    <CheckCircle2 size={19} />
                  </div>

                  {options.role === "host" ? (
                    <div className="model-chip">
                      <span>Model</span>
                      <strong title={options.modelPath}>{modelName}</strong>
                    </div>
                  ) : null}

                  <div className="requirements">
                    {preview?.requirements.map((item) => (
                      <div className="requirement" key={item}>
                        <CheckCircle2 size={15} />
                        <span>{item}</span>
                      </div>
                    ))}
                  </div>
                </section>

              </aside>
            </div>

            {logsOpen ? (
              <section className="log-panel">
                <div className="terminal-toolbar">
                  <div className="terminal-title-row">
                    <span className={ready ? "small-dot active" : "small-dot"} />
                    <strong>Live Output</strong>
                    <span className="line-counter">{filteredLogs.length} lines</span>
                    {sessionPid ? <span className="pid-label">Process ID: {sessionPid}</span> : null}
                  </div>
                  <div className="terminal-actions">
                    <label className="log-filter">
                      <Search size={14} />
                      <input
                        placeholder="Filter stream logs..."
                        value={logFilter}
                        onChange={(event) => setLogFilter(event.target.value)}
                      />
                    </label>
                    <button className={autoscroll ? "terminal-button active" : "terminal-button"} onClick={() => setAutoscroll((value) => !value)} title="Autoscroll logs" type="button">
                      <ChevronDown size={13} />
                      <span>Auto</span>
                    </button>
                    <button className="icon-button" onClick={copyLogs} title="Copy raw logs" type="button">
                      {copyLogsStatus === "copied" ? <Check size={17} /> : <Clipboard size={17} />}
                    </button>
                    <button className="icon-button" onClick={() => setLogs([])} title="Clear logs" type="button">
                      <Eraser size={17} />
                    </button>
                    <button className="icon-button" onClick={() => setLogsOpen(false)} title="Hide logs" type="button">
                      <ChevronUp size={17} />
                    </button>
                  </div>
                </div>
                <div className={autoscroll ? "log-window autoscroll" : "log-window"} ref={logWindowRef}>
                  {filteredLogs.length === 0 ? (
                    <p className="empty-log">Logs appear here when a session starts.</p>
                  ) : (
                    filteredLogs.map((entry, index) => (
                      <div className={`log-line ${entry.stream}`} key={`${entry.sessionId}-${index}`}>
                        <span>{entry.stream}</span>
                        <code>{entry.line}</code>
                      </div>
                    ))
                  )}
                </div>
              </section>
            ) : (
              <button className="show-log-strip" onClick={() => setLogsOpen(true)} type="button">
                <Terminal size={16} />
                <span>Show Live Output</span>
                <ChevronDown size={16} />
              </button>
            )}
          </section>
        </div>

        <footer className="footerbar">
          <div>
            <span>
              <span className={sessionLive ? "small-dot active" : "small-dot"} />
              <strong>{sessionLive ? "Engine Active" : "Engine Idle"}</strong>
            </span>
            {options.role === "host" ? (
              <span className="footer-model" title={options.modelPath}>Model: {modelName}</span>
            ) : null}
            <span>Context: <strong>{options.context || "auto"} ctx</strong></span>
          </div>
          <div>
            <span>Workers: <strong>{workerNodes.length}</strong></span>
            <span className="footer-separator">|</span>
            <span>Discovery: <strong>UDP:{options.discoveryPort || "50053"}</strong></span>
            <span className="footer-separator">|</span>
            <span>Host: <strong>{hostInfo ? `${hostInfo.os} ${hostInfo.arch}` : "Detecting"}</strong></span>
          </div>
        </footer>
      </div>
    </main>
  );
}

type SegmentItem<T extends string> = {
  value: T;
  label: string;
  icon?: LucideIcon;
};

function Segmented<T extends string>({
  compact,
  disabled,
  items,
  onChange,
  value,
}: {
  compact?: boolean;
  disabled?: boolean;
  items: SegmentItem<T>[];
  onChange: (value: T) => void;
  value: T;
}) {
  return (
    <div className={compact ? "segmented compact" : "segmented"}>
      {items.map((item) => {
        const Icon = item.icon;
        return (
          <button
            className={item.value === value ? "segment active" : "segment"}
            disabled={disabled}
            key={item.value}
            onClick={() => onChange(item.value)}
            type="button"
          >
            {Icon ? <Icon size={17} /> : null}
            <span>{item.label}</span>
          </button>
        );
      })}
    </div>
  );
}

function Panel({
  children,
  icon: Icon,
  title,
}: {
  children: ReactNode;
  icon: LucideIcon;
  title: string;
}) {
  return (
    <section className="rail-panel">
      <div className="rail-title">
        <Icon size={16} />
        <span>{title}</span>
      </div>
      {children}
    </section>
  );
}

function Field({
  children,
  className,
  label,
}: {
  children: ReactNode;
  className?: string;
  label: string;
}) {
  return (
    <label className={className ? `field ${className}` : "field"}>
      <span>{label}</span>
      {children}
    </label>
  );
}

function Toggle({
  checked,
  disabled,
  label,
  onChange,
}: {
  checked: boolean;
  disabled?: boolean;
  label: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className={disabled ? "toggle disabled" : "toggle"}>
      <input
        checked={checked}
        disabled={disabled}
        onChange={(event) => onChange(event.target.checked)}
        type="checkbox"
      />
      <span />
      <strong>{label}</strong>
    </label>
  );
}

function DistributionCard({
  distribution,
  modelPath,
  running,
}: {
  distribution: DistributionItem[];
  modelPath: string;
  running: boolean;
}) {
  const segments = getTopologySegments(distribution);
  const hasTopology = segments.length > 0;
  const exactSplit = distribution.some((item) => item.exact);

  return (
    <section className="topology-card">
      <div className="topology-header">
        <div className="topology-title">
          <Layers3 size={19} />
          <span>Model Sharding Topology</span>
        </div>
        <span className="topology-format">{getQuantizationLabel(modelPath)}</span>
      </div>

      <div className="topology-balance-row">
        <span>Distributed Layer Balance</span>
        <strong>{exactSplit ? "llama.cpp Split Detected" : hasTopology ? "Workers Connected" : running ? "Awaiting Layer Split" : "Ready To Capture Split"}</strong>
      </div>

      <div className={hasTopology ? "topology-balance-bar" : "topology-balance-bar pending"} aria-hidden="true">
        {hasTopology ? (
          segments.map((segment) => (
            <span
              className={`topology-segment ${segment.tone}`}
              key={`${segment.label}-${segment.detail}`}
              style={{ width: `${segment.percent}%` }}
            />
          ))
        ) : null}
      </div>

      {hasTopology ? (
        <div className="topology-segment-labels">
          {segments.map((segment) => (
            <div key={`${segment.label}-${segment.detail}-label`} style={{ width: `${segment.percent}%` }}>
              <strong>{segment.label}</strong>
              <span>{segment.detail}</span>
            </div>
          ))}
        </div>
      ) : null}

      <div className="topology-legend">
        {hasTopology ? (
          segments.map((segment) => (
            <span key={`${segment.label}-${segment.percent}`}>
              <i className={segment.tone} />
              {segment.label} {segment.detail ? `(${segment.detail})` : null}
            </span>
          ))
        ) : (
          <span>
            <i className="lavender" />
            {running ? "Waiting for worker discovery and llama.cpp allocation output" : "Start the model to capture host and worker shards"}
          </span>
        )}
      </div>
      {hasTopology && !exactSplit ? (
        <p className="topology-note">Connected workers are shown now. Exact layer percentages appear only if llama.cpp prints split details during model load.</p>
      ) : null}
    </section>
  );
}

function StatusPill({ label, ready }: { label: string; ready: boolean }) {
  return (
    <div className={ready ? "status-pill running" : "status-pill"}>
      <span />
      <strong>{label}</strong>
    </div>
  );
}

function StageChip({ stage }: { stage: SystemStage }) {
  return (
    <span className={`stage-chip ${stage.state}`} title={stage.detail}>
      {stage.state === "complete" ? <CheckCircle2 size={13} /> : null}
      {stage.state === "blocked" ? <TriangleAlert size={13} /> : null}
      {stage.state === "active" ? <span className="stage-spinner" /> : null}
      {stage.state === "pending" ? <span className="stage-dot" /> : null}
      <span>{stage.label}</span>
    </span>
  );
}

function Alert({ message, tone = "error" }: { message: string; tone?: "error" | "warn" }) {
  return (
    <div className={tone === "warn" ? "alert warn" : "alert"}>
      <TriangleAlert size={18} />
      <span>{message}</span>
    </div>
  );
}

function isTauriRuntime() {
  return typeof window !== "undefined" && Boolean((window as TauriWindow).__TAURI_INTERNALS__);
}

function buildBrowserPreview(options: LaunchOptions): LaunchPreview {
  const os = options.targetOs === "macos" ? "macOS" : options.targetOs === "windows" ? "Windows" : "Linux";
  const stack = options.stack === "apple" ? "Apple Silicon / Metal" : "NVIDIA CUDA";
  const script = `${options.role === "host" ? "start" : "share"}-${os.toLowerCase()}-${options.stack}`;

  return {
    shell: options.targetOs === "windows" ? "Git Bash" : "/bin/bash",
    command: `${script} ${options.role === "host" ? "--model <selected.gguf>" : "--rpc-port " + options.rpcPort}`,
    environment: [],
    requirements: [stack, "llama.cpp", options.role === "host" ? "GGUF model file" : "RPC worker mode", "LAN discovery"],
    notes: ["Browser design preview only; launch commands run inside the desktop app."],
  };
}

function getSystemStages(
  options: LaunchOptions,
  logs: LogEvent[],
  running: boolean,
  ready: boolean,
  status: string,
  error: string | null,
): SystemStage[] {
  const serverReady = hasLog(logs, (line) => isServerReadyLine(line));
  const blocked = !running && !ready && !serverReady && (Boolean(error) || /\b(error|failed|abort|exited \([1-9])/i.test(status) || hasLog(logs, isFatalLogLine));
  const started = running || logs.length > 0;

  const definitions = options.role === "host"
    ? [
        { label: "Discover workers", detail: "Find reachable llama.cpp RPC workers on the LAN." },
        { label: "Prepare llama.cpp", detail: "Clone, update, and build llama.cpp with the selected backend." },
        { label: "Check model", detail: "Validate the selected GGUF model before launch." },
        { label: "Serve model", detail: "Start llama-server and wait until it is ready for requests." },
      ]
    : [
        { label: "Prepare worker", detail: "Check local GPU, tools, and llama.cpp workspace." },
        { label: "Build RPC backend", detail: "Compile llama.cpp with RPC and the selected GPU backend." },
        { label: "Advertise on LAN", detail: "Publish this machine so model starters can discover it." },
        { label: "RPC online", detail: "Start the RPC server and listen for distributed inference work." },
      ];

  const completeFlags = options.role === "host"
    ? [
        ready || serverReady || hasLog(logs, /rpc worker\(s\):|using manual rpc endpoint|\[2\/|\[3\/|\[4\/|\[5\/|\[6\//i),
        ready || serverReady || hasLog(logs, /\[4\/|\[5\/|\[6\/|checking model|model\s*:/i),
        ready || serverReady || hasLog(logs, /\[5\/|\[6\/|starting distributed inference|llama-server:/i),
        ready || serverReady || (options.mode === "cli" && running && hasLog(logs, /starting distributed inference/i)),
      ]
    : [
        hasLog(logs, /\[2\/|\[3\/|\[4\/|\[5\/|building .*rpc|cloning\/updating llama\.cpp/i),
        hasLog(logs, /\[3\/4\]|\[4\/5\]|advertising this worker|starting automatic discovery responder|starting rpc worker/i),
        hasLog(logs, /\[4\/4\]|\[5\/5\]|starting rpc worker|rpc endpoint/i),
        hasLog(logs, /this .* sharing .* gpu|rpc endpoint\s*:|use only on a trusted lan|starting rpc worker/i),
      ];

  const firstIncomplete = completeFlags.findIndex((complete) => !complete);
  const activeIndex = firstIncomplete === -1 ? definitions.length - 1 : firstIncomplete;

  return definitions.map((stage, index) => {
    let state: StageState = "pending";
    if (completeFlags[index]) state = "complete";
    if (started && !completeFlags[index] && index === activeIndex) state = "active";
    if (blocked && !completeFlags[index] && index === activeIndex) state = "blocked";
    if (!started && index === 0) state = "pending";
    if (ready && index === definitions.length - 1) state = "complete";

    return { ...stage, state };
  });
}

function hasLog(logs: LogEvent[], pattern: RegExp | ((line: string) => boolean)) {
  if (pattern instanceof RegExp) return logs.some((entry) => pattern.test(entry.line));
  return logs.some((entry) => pattern(entry.line));
}

function isFatalLogLine(line: string) {
  const normalized = line.toLowerCase();
  if (normalized.includes("cors is set") || normalized.includes("security risk") || normalized.includes("more info:")) return false;
  return /\b(error|failed|abort|fatal)\b/.test(normalized);
}

function getTopologySegments(distribution: DistributionItem[]) {
  const items = distribution.filter((item) => item.label.trim().length > 0);
  if (items.length === 0) return [];

  const fallbackPercent = 100 / items.length;
  const total = items.reduce((sum, item) => sum + (item.percent ?? fallbackPercent), 0) || 100;
  const tones = ["lavender", "green", "amber", "cyan"];

  return items.map((item, index) => ({
    label: item.label,
    detail: item.detail,
    percent: Math.max(5, Math.round(((item.percent ?? fallbackPercent) / total) * 100)),
    tone: tones[index % tones.length],
  }));
}

function getQuantizationLabel(value: string) {
  const match = value.match(/\bQ(\d)(?:_|-|\b)/i);
  if (match) return `${match[1]}-bit Quantized (GGUF)`;
  return "GGUF Shard Plan";
}

function getModelDisplayName(modelPath: string) {
  const trimmed = modelPath.trim();
  if (!trimmed) return "No model selected";

  const parts = trimmed
    .replace(/\\/g, "/")
    .split("/")
    .filter(Boolean)
    .map((part) => {
      try {
        return decodeURIComponent(part);
      } catch {
        return part;
      }
    });

  const hfModelFolder = [...parts].reverse().find((part) => part.startsWith("models--"));
  if (hfModelFolder) return hfModelFolder.replace(/^models--/, "").replace(/--/g, "/");

  const ggufFile = [...parts].reverse().find((part) => part.toLowerCase().endsWith(".gguf"));
  if (ggufFile) return cleanModelName(ggufFile);

  const readablePart = [...parts].reverse().find((part) => !isHashSegment(part) && !["snapshots", "blobs", "refs"].includes(part));
  return readablePart ? cleanModelName(readablePart) : "Selected model";
}

function cleanModelName(name: string) {
  return name.replace(/\.(gguf|bin|safetensors)$/i, "");
}

function isHashSegment(value: string) {
  return /^[a-f0-9]{24,}$/i.test(value) || /^[a-z0-9]{40,}$/i.test(value);
}

function getServerUrl(options: LaunchOptions, hostInfo: HostInfo | null) {
  const bind = options.serverHost.trim();
  const host = bind === "" || bind === "0.0.0.0" || bind === "::" ? hostInfo?.networkHost || "localhost" : bind;
  return `http://${host}:${options.serverPort || "8080"}`;
}

function isServerReadyLine(line: string) {
  const normalized = line.toLowerCase();
  return (
    normalized.includes("server is listening") ||
    normalized.includes("server listening") ||
    normalized.includes("server started") ||
    normalized.includes("listening on") ||
    normalized.includes("listening at") ||
    normalized.includes("listening, hostname") ||
    normalized.includes("http server listening")
  );
}

function getLoadDistribution(logs: LogEvent[]): DistributionItem[] {
  for (const entry of [...logs].reverse()) {
    const parsed = parseDistributionLine(entry.line);
    if (parsed.length > 0) return parsed;
  }

  const rpcLine = [...logs].reverse().find((entry) => entry.line.toLowerCase().includes("rpc worker(s):"));
  if (!rpcLine) return [];

  const endpoints = rpcLine.line
    .replace(/^.*rpc worker\(s\):/i, "")
    .split(",")
    .map((endpoint) => endpoint.trim())
    .filter(Boolean);

  if (endpoints.length === 0) return [];

  return [
    { label: "Host", detail: "auto" },
    ...endpoints.map((endpoint, index) => ({
      label: `Worker ${index + 1}`,
      detail: endpoint,
    })),
  ];
}

function getWorkerNodes(logs: LogEvent[]): WorkerNode[] {
  const rpcLine = [...logs].reverse().find((entry) => entry.line.toLowerCase().includes("rpc worker(s):"));
  if (!rpcLine) return [];

  return rpcLine.line
    .replace(/^.*rpc worker\(s\):/i, "")
    .split(",")
    .map((endpoint) => endpoint.trim())
    .filter(Boolean)
    .map((endpoint, index) => ({
      label: `Worker ${index + 1}`,
      endpoint,
    }));
}

function filterLogs(logs: LogEvent[], filter: string) {
  const query = filter.trim().toLowerCase();
  if (!query) return logs;
  return logs.filter((entry) => `${entry.stream} ${entry.line}`.toLowerCase().includes(query));
}

function getSessionPid(logs: LogEvent[], sessionId: string | null) {
  if (!sessionId) return null;
  const startLine = logs.find(
    (entry) => entry.sessionId === sessionId && entry.stream === "system" && entry.line.startsWith("Started session as process "),
  );
  return startLine?.line.match(/process\s+(\d+)/)?.[1] ?? null;
}

function getClusterLabel(options: LaunchOptions, running: boolean, workerCount: number) {
  if (!running) return "Ready for local cluster";
  if (options.role === "worker") return "RPC worker online";
  if (workerCount === 0) return "Local engine active";
  return `${workerCount + 1} Nodes Clustered`;
}

function parseDistributionLine(line: string): DistributionItem[] {
  const normalized = line.toLowerCase();
  if (!normalized.includes("split") || (!normalized.includes("worker") && !normalized.includes("device"))) {
    return [];
  }

  const matches = [...line.matchAll(/(?:worker|device)\s*([\w.-]+)\s*(?:->|:|=)\s*(\d+(?:\.\d+)?)\s*%/gi)];
  if (matches.length === 0) return [];

  return matches.map((match) => ({
    label: match[1].match(/^\d+$/) ? `Worker ${Number(match[1]) + 1}` : match[1],
    detail: "Layer allocation",
    percent: Math.round(Number(match[2])),
    exact: true,
  }));
}

function presetTitle(options: LaunchOptions) {
  const role = options.role === "host" ? "Model starter" : "GPU worker";
  const stack = options.stack === "apple" ? "Apple Silicon" : "NVIDIA CUDA";
  const os = options.targetOs === "macos" ? "macOS" : options.targetOs === "windows" ? "Windows" : "Linux";
  return `${role} / ${os} / ${stack}`;
}

export default App;
