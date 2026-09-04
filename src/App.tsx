import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Activity,
  Apple,
  CheckCircle2,
  Cpu,
  FolderOpen,
  HardDrive,
  MonitorCog,
  Network,
  Play,
  Radio,
  Server,
  Settings2,
  Shield,
  Square,
  Terminal,
  Trash2,
  TriangleAlert,
  type LucideIcon,
} from "lucide-react";
import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";

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
  serverHost: "127.0.0.1",
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
  const [status, setStatus] = useState("Ready");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    invoke<HostInfo>("detect_host")
      .then((info) => {
        setHostInfo(info);
        setOptions((current) => ({
          ...current,
          stack: info.defaultStack,
          targetOs: info.defaultStack === "apple" ? "macos" : info.defaultTargetOs,
          context: info.defaultStack === "apple" ? "8192" : "4096",
          serverHost: info.defaultStack === "apple" ? "127.0.0.1" : "0.0.0.0",
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
      }),
      listen<SessionEvent>("session-ended", (event) => {
        setRunning(false);
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
          next.serverHost = current.serverHost === "0.0.0.0" ? "127.0.0.1" : current.serverHost;
        } else if (current.targetOs === "macos") {
          next.targetOs = "windows";
          next.context = current.context === "8192" ? "4096" : current.context;
          next.serverHost = current.serverHost === "127.0.0.1" ? "0.0.0.0" : current.serverHost;
        }
      }

      if (key === "targetOs" && value === "macos") {
        next.stack = "apple";
        next.serverHost = current.serverHost === "0.0.0.0" ? "127.0.0.1" : current.serverHost;
      }

      if (key === "targetOs" && value !== "macos") {
        next.stack = "nvidia";
        next.serverHost = current.serverHost === "127.0.0.1" ? "0.0.0.0" : current.serverHost;
      }

      return next;
    });
  };

  const start = async () => {
    setError(null);
    setStatus("Starting");
    try {
      const id = await invoke<string>("start_session", { options });
      setSessionId(id);
      setRunning(true);
      setStatus("Running");
    } catch (err) {
      setStatus("Ready");
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
        filters: [{ name: "GGUF models", extensions: ["gguf"] }],
      });

      if (typeof selected === "string") {
        updateOption("modelPath", selected);
      }
    } catch (err) {
      setError(String(err));
    }
  };

  return (
    <main className="app-shell">
      <header className="topbar">
        <div>
          <p className="eyebrow">llama.cpp RPC launcher</p>
          <h1>Sharrd</h1>
        </div>
        <div className="machine-strip">
          <StatusPill running={running} label={status} />
          <div className="host-pill">
            <MonitorCog size={16} />
            <span>{hostInfo ? `${hostInfo.os} / ${hostInfo.arch}` : "Desktop app"}</span>
          </div>
        </div>
      </header>

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

        <section className="main-grid">
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

              <Field label="Shell">
                <input
                  placeholder={options.targetOs === "windows" ? "bash.exe" : "bash"}
                  value={options.shellPath}
                  onChange={(event) => updateOption("shellPath", event.target.value)}
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
                <Radio size={20} />
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

            <section className="summary-panel command-panel">
              <div className="section-heading compact-heading">
                <div>
                  <p className="eyebrow">Launch preview</p>
                  <h2>{preview?.shell ?? "Shell"}</h2>
                </div>
                <Terminal size={20} />
              </div>
              <pre>{preview?.command ?? "Select a supported preset."}</pre>
              <div className="env-list">
                {preview?.environment.slice(0, 8).map((item) => (
                  <code key={item.key}>{item.key}</code>
                ))}
              </div>
            </section>
          </section>

          <section className="log-panel">
            <div className="section-heading compact-heading">
              <div>
                <p className="eyebrow">Live output</p>
                <h2>{logs.length ? `${logs.length} lines` : "No output yet"}</h2>
              </div>
              <button className="icon-button" onClick={() => setLogs([])} title="Clear logs" type="button">
                <Trash2 size={18} />
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
        </section>
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

function StatusPill({ label, running }: { label: string; running: boolean }) {
  return (
    <div className={running ? "status-pill running" : "status-pill"}>
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

function presetTitle(options: LaunchOptions) {
  const role = options.role === "host" ? "Model starter" : "GPU worker";
  const stack = options.stack === "apple" ? "Apple Silicon" : "NVIDIA CUDA";
  const os = options.targetOs === "macos" ? "macOS" : options.targetOs === "windows" ? "Windows" : "Linux";
  return `${role} / ${os} / ${stack}`;
}

export default App;
