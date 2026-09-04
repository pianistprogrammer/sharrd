import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Activity,
  Apple,
  CheckCircle2,
  Check,
  ChevronDown,
  ChevronUp,
  Clipboard,
  Cpu,
  Eraser,
  FolderOpen,
  HardDrive,
  MonitorCog,
  Network,
  Play,
  Server,
  Settings2,
  Shield,
  Square,
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
  const activeSessionRef = useRef<string | null>(null);
  const waitsForServerRef = useRef(false);

  useEffect(() => {
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

  const chooseModelPath = async () => {
    setError(null);
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

  const serverUrl = getServerUrl(options, hostInfo);
  const showServerUrl = running && options.role === "host" && options.mode === "server";

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

  return (
    <main className="app-shell">
      <header className="topbar">
        <div>
          <h1>Sharrd</h1>
        </div>
        <div className="machine-strip">
          <StatusPill ready={ready} label={status} />
          <button className="secondary-button" onClick={() => setLogsOpen((open) => !open)} type="button">
            {logsOpen ? <ChevronUp size={18} /> : <ChevronDown size={18} />}
            <span>{logsOpen ? "Hide logs" : "Show logs"}</span>
          </button>
          <div className="host-pill">
            <MonitorCog size={16} />
            <span>{hostInfo ? `${hostInfo.os} / ${hostInfo.arch}` : "Desktop app"}</span>
          </div>
        </div>
      </header>

      {showServerUrl ? (
        <section className={ready ? "server-card running" : "server-card"}>
          <div>
            <p className="eyebrow">Server URL</p>
            <strong>{serverUrl}</strong>
          </div>
          <div className="server-actions">
            <button className="secondary-button" onClick={copyServerUrl} type="button">
              {copyStatus === "copied" ? <Check size={18} /> : <Clipboard size={18} />}
              <span>{copyStatus === "copied" ? "Copied" : "Copy"}</span>
            </button>
          </div>
        </section>
      ) : null}

      <section className="workspace">
        <aside className="control-rail">
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

          <div className="action-row">
            <button className="primary-button" disabled={!canStart} onClick={start} type="button">
              <Play size={18} />
              <span>{options.role === "host" ? "Start" : "Share"}</span>
            </button>
            <button className="stop-button" disabled={!running} onClick={stop} type="button">
              <Square size={17} />
              <span>Stop</span>
            </button>
          </div>
        </aside>

          <section className="config-panel">
            <div className="section-heading">
              <div>
                <p className="eyebrow">Configuration</p>
                <h2>{options.role === "host" ? "Start a distributed GGUF model" : "Offer this machine as a worker"}</h2>
              </div>
              <Shield size={22} />
            </div>

            {error ? <Alert message={error} /> : null}
            {options.role === "host" && options.modelPath.trim().length === 0 ? (
              <Alert message="A GGUF model path is required for the model starter." tone="warn" />
            ) : null}

            <div className="form-grid">
              {options.role === "host" ? (
                <Field label="GGUF model path" className="span-2">
                  <div className="path-picker">
                    <input
                      placeholder={options.targetOs === "windows" ? "/c/models/model.gguf" : "/Users/me/Models/model.gguf"}
                      value={options.modelPath}
                      onChange={(event) => updateOption("modelPath", event.target.value)}
                    />
                    <button className="browse-button" onClick={chooseModelPath} title="Choose GGUF model" type="button">
                      <FolderOpen size={18} />
                      <span>Browse</span>
                    </button>
                  </div>
                </Field>
              ) : null}

              <Field label="llama.cpp directory">
                <input
                  placeholder={defaultLlamaPlaceholder(options)}
                  value={options.llamaDir}
                  onChange={(event) => updateOption("llamaDir", event.target.value)}
                />
              </Field>

              {options.role === "host" ? (
                <>
                  <Field label="Context">
                    <input
                      inputMode="numeric"
                      value={options.context}
                      onChange={(event) => updateOption("context", event.target.value)}
                    />
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
                <Field label="RPC port">
                  <input
                    inputMode="numeric"
                    value={options.rpcPort}
                    onChange={(event) => updateOption("rpcPort", event.target.value)}
                  />
                </Field>
              )}

              <Field label="Discovery port">
                <input
                  inputMode="numeric"
                  value={options.discoveryPort}
                  onChange={(event) => updateOption("discoveryPort", event.target.value)}
                />
              </Field>

              {options.stack === "nvidia" && options.role === "host" ? (
                <Field label="Manual RPC endpoints" className="span-2">
                  <input
                    placeholder="192.168.1.11:50052,192.168.1.12:50052"
                    value={options.manualRpcServers}
                    onChange={(event) => updateOption("manualRpcServers", event.target.value)}
                  />
                </Field>
              ) : null}
            </div>

            <div className="toggle-row">
              <Toggle
                checked={options.useCache}
                label="RPC cache"
                onChange={(checked) => updateOption("useCache", checked)}
              />
              <Toggle
                checked={options.useAllWorkers}
                disabled={options.role === "worker"}
                label="Use all discovered workers"
                onChange={(checked) => updateOption("useAllWorkers", checked)}
              />
            </div>
          </section>

          <section className="side-stack">
            <section className="summary-panel">
              <div className="section-heading compact-heading">
                <div>
                  <p className="eyebrow">Preset</p>
                  <h2>{preview ? presetTitle(options) : "Not selected"}</h2>
                </div>
                <CheckCircle2 size={20} />
              </div>

              <div className="requirements">
                {preview?.requirements.map((item) => (
                  <div className="requirement" key={item}>
                    <CheckCircle2 size={16} />
                    <span>{item}</span>
                  </div>
                ))}
              </div>
            </section>
          </section>

          {logsOpen ? (
            <section className="log-panel">
              <div className="section-heading compact-heading">
                <div>
                  <p className="eyebrow">Live output</p>
                  <h2>{logs.length ? `${logs.length} lines` : "No output yet"}</h2>
                </div>
                <button className="icon-button" onClick={() => setLogs([])} title="Clear logs" type="button">
                  <Eraser size={18} />
                </button>
              </div>
              <div className="log-window">
                {logs.length === 0 ? (
                  <p className="empty-log">Logs appear here when a session starts.</p>
                ) : (
                  logs.map((entry, index) => (
                    <div className={`log-line ${entry.stream}`} key={`${entry.sessionId}-${index}`}>
                      <span>{entry.stream}</span>
                      <code>{entry.line}</code>
                    </div>
                  ))
                )}
              </div>
            </section>
          ) : null}
      </section>
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

function StatusPill({ label, ready }: { label: string; ready: boolean }) {
  return (
    <div className={ready ? "status-pill running" : "status-pill"}>
      <span />
      <strong>{label}</strong>
    </div>
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

function defaultLlamaPlaceholder(options: LaunchOptions) {
  if (options.targetOs === "windows") return "/c/llama.cpp";
  return "$HOME/llama.cpp";
}

function getServerUrl(options: LaunchOptions, hostInfo: HostInfo | null) {
  const bind = options.serverHost.trim();
  const host = bind === "" || bind === "0.0.0.0" || bind === "::" ? hostInfo?.networkHost || "localhost" : bind;
  return `http://${host}:${options.serverPort || "8080"}`;
}

function isServerReadyLine(line: string) {
  const normalized = line.toLowerCase();
  if (normalized.startsWith("llama-server:")) return false;
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

function presetTitle(options: LaunchOptions) {
  const role = options.role === "host" ? "Model starter" : "GPU worker";
  const stack = options.stack === "apple" ? "Apple Silicon" : "NVIDIA CUDA";
  const os = options.targetOs === "macos" ? "macOS" : options.targetOs === "windows" ? "Windows" : "Linux";
  return `${role} / ${os} / ${stack}`;
}

export default App;
