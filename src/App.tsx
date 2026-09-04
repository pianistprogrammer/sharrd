import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import {
  Activity,
  Apple,
  BarChart3,
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

type DistributionItem = {
  label: string;
  detail: string;
  percent?: number;
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
  const distribution = useMemo(() => getLoadDistribution(logs), [logs]);
  const activeRequirements = preview?.requirements ?? [];
  const modelName = useMemo(() => getModelDisplayName(options.modelPath), [options.modelPath]);

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
      <div className="desktop-window">
        <header className="titlebar">
          <div className="brand-cluster">
            <div className="traffic-lights" aria-label="Window controls">
              <span />
              <span />
              <span />
            </div>
            <div className="brand-mark">
              <Boxes size={16} />
              <strong>Sharrd</strong>
              <span>v0.1.0</span>
            </div>
          </div>

          <div className="cluster-status">
            <StatusPill ready={ready} label={status} />
            {showServerUrl ? (
              <>
                <span className="status-divider" />
                <code>{serverUrl}</code>
              </>
            ) : null}
          </div>

          <div className="title-actions">
            <button className="secondary-button" onClick={() => setLogsOpen((open) => !open)} type="button">
              {logsOpen ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
              <span>{logsOpen ? "Hide logs" : "Show logs"}</span>
            </button>
            <div className="host-pill">
              <MonitorCog size={15} />
              <span>{hostInfo ? `${hostInfo.os} / ${hostInfo.arch}` : "Desktop app"}</span>
            </div>
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

            <div className="rail-status-card">
              <span className={running ? "small-dot active" : "small-dot"} />
              <div>
                <strong>{running ? "Session active" : "Standing by"}</strong>
                <span>{options.stack === "apple" ? "Bonjour / Metal RPC" : "LAN RPC discovery"}</span>
              </div>
            </div>
          </aside>

          <section className="workbench">
            <div className="system-bar">
              <div className="requirement-strip">
                <span className="system-label">System State</span>
                {activeRequirements.slice(0, 4).map((item) => (
                  <span className="requirement-chip" key={item}>
                    <CheckCircle2 size={13} />
                    {item}
                  </span>
                ))}
              </div>

              <div className="action-row">
                <button className="stop-button" disabled={!running} onClick={stop} type="button">
                  <Square size={15} />
                  <span>Stop</span>
                </button>
                <button className="primary-button" disabled={!canStart} onClick={start} type="button">
                  <Play size={16} />
                  <span>{options.role === "host" ? "Distribute & Run" : "Share GPU"}</span>
                </button>
              </div>
            </div>

            <div className="content-grid">
              <section className="config-panel">
                <div className="section-heading">
                  <div>
                    <p className="eyebrow">Engine configuration</p>
                    <h2>{options.role === "host" ? "Start a distributed GGUF model" : "Offer this machine as a worker"}</h2>
                  </div>
                  <Shield size={21} />
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

                  <Field label="llama.cpp directory" className={options.role === "host" ? "span-2" : "span-3"}>
                    <input
                      placeholder={defaultLlamaPlaceholder(options)}
                      value={options.llamaDir}
                      onChange={(event) => updateOption("llamaDir", event.target.value)}
                    />
                  </Field>

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
                  <Toggle
                    checked={options.useCache}
                    label="RPC memory cache"
                    onChange={(checked) => updateOption("useCache", checked)}
                  />
                  <Toggle
                    checked={options.useAllWorkers}
                    disabled={options.role === "worker"}
                    label="Auto-attach workers"
                    onChange={(checked) => updateOption("useAllWorkers", checked)}
                  />
                </div>
              </section>

              <aside className="side-stack">
                {showServerUrl ? (
                  <section className={ready ? "server-card running" : "server-card"}>
                    <div>
                      <p className="eyebrow">Server URL</p>
                      <strong>{serverUrl}</strong>
                    </div>
                    <button className="secondary-button copy-button" onClick={copyServerUrl} type="button">
                      {copyStatus === "copied" ? <Check size={16} /> : <Clipboard size={16} />}
                      <span>{copyStatus === "copied" ? "Copied" : "Copy"}</span>
                    </button>
                  </section>
                ) : null}

                {options.role === "host" ? <DistributionCard distribution={distribution} running={running} /> : null}

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
                <div className="section-heading compact-heading">
                  <div>
                    <p className="eyebrow">Live output</p>
                    <h2>{logs.length ? `${logs.length} lines` : "No output yet"}</h2>
                  </div>
                  <button className="icon-button" onClick={() => setLogs([])} title="Clear logs" type="button">
                    <Eraser size={17} />
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
        </div>

        <footer className="footerbar">
          <span>
            <span className={running ? "small-dot active" : "small-dot"} />
            {running ? "Engine active" : "Engine idle"}
          </span>
          {options.role === "host" ? (
            <span className="footer-model" title={options.modelPath}>Model: {modelName}</span>
          ) : null}
          <span>Context: {options.context || "auto"}</span>
          <span>Discovery: UDP {options.discoveryPort || "50053"}</span>
          <span>{options.role === "host" ? "Starter" : "Worker"}</span>
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

function DistributionCard({ distribution, running }: { distribution: DistributionItem[]; running: boolean }) {
  return (
    <section className="distribution-card">
      <div className="section-heading compact-heading">
        <div>
          <p className="eyebrow">Load distribution</p>
          <h2>llama.cpp automatic split</h2>
        </div>
        <BarChart3 size={19} />
      </div>

      {distribution.length > 0 ? (
        <div className="distribution-list">
          {distribution.map((item) => (
            <div className="distribution-row" key={`${item.label}-${item.detail}`}>
              <div className="distribution-copy">
                <strong>{item.label}</strong>
                <span>{item.detail}</span>
              </div>
              {typeof item.percent === "number" ? <span className="distribution-value">{item.percent}%</span> : null}
              <div className="distribution-meter" aria-hidden="true">
                <span style={{ width: `${Math.max(8, item.percent ?? 100)}%` }} />
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="distribution-empty">
          <Layers3 size={22} />
          <strong>{running ? "Waiting for split data" : "Ready to capture split"}</strong>
          <span>{running ? "The allocation will appear when llama.cpp prints the tensor or layer split." : "Start a model to see the host and worker allocation."}</span>
        </div>
      )}
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
    { label: "Local host", detail: "Included in llama.cpp split" },
    ...endpoints.map((endpoint, index) => ({
      label: `Worker ${index + 1}`,
      detail: endpoint,
    })),
  ];
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
  }));
}

function presetTitle(options: LaunchOptions) {
  const role = options.role === "host" ? "Model starter" : "GPU worker";
  const stack = options.stack === "apple" ? "Apple Silicon" : "NVIDIA CUDA";
  const os = options.targetOs === "macos" ? "macOS" : options.targetOs === "windows" ? "Windows" : "Linux";
  return `${role} / ${os} / ${stack}`;
}

export default App;
