import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

// ---------------------------------------------------------------------------
// Provider catalog (ported from the macOS app's Provider.swift)
// ---------------------------------------------------------------------------

export interface ProviderSpec {
  id: string;
  name: string;
  models: string[];
  efforts: string[];
  directAPI: boolean;
  effortNote?: string;
}

export const PROVIDERS: ProviderSpec[] = [
  {
    id: "codex",
    name: "Codex",
    models: ["Default", "gpt-6-astra", "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.3-codex", "gpt-5.3-codex-spark"],
    efforts: ["Default", "low", "medium", "high", "xhigh"],
    directAPI: false,
  },
  {
    id: "claude",
    name: "Claude",
    models: ["Default", "opus", "sonnet", "haiku", "claude-fable-5-1", "claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-sonnet-4-6", "claude-sonnet-4-5"],
    efforts: ["Default", "low", "medium", "high", "xhigh", "max"],
    directAPI: false,
  },
  {
    id: "grok",
    name: "Grok",
    models: ["Default", "grok-4.6", "grok-4.5"],
    efforts: ["Default", "low", "medium", "high"],
    directAPI: false,
  },
  {
    id: "glm",
    name: "GLM",
    models: ["Default", "glm-5.3", "glm-5.3-flash", "glm-5.2", "glm-5.1", "glm-5-turbo", "glm-4.7", "glm-4.5-air"],
    efforts: ["Default", "low", "medium", "high", "xhigh", "max"],
    directAPI: false,
  },
  {
    id: "kimi",
    name: "Kimi",
    models: ["Default", "kimi-code/k3", "kimi-code/k3-256k", "kimi-code/kimi-for-coding", "kimi-code/kimi-for-coding-highspeed"],
    efforts: ["Default"],
    directAPI: false,
    effortNote: "Kimi Code does not expose a per-request effort setting.",
  },
  {
    id: "qwen",
    name: "Qwen",
    models: ["Default", "qwen3.8-max", "qwen3.8-max-preview", "qwen3.7-max", "qwen3-max", "qwen3-max-preview", "qwen3-max-2026-01-23", "qwen3.7-plus", "qwen3.6-plus", "qwen3.6-flash", "qwen3.5-plus", "qwen3-coder-plus", "qwen3-coder-next"],
    efforts: ["Default"],
    directAPI: false,
    effortNote: "Qwen Code stores reasoning effort in its own CLI settings.",
  },
  {
    id: "google",
    name: "Google",
    models: [
      "Default",
      "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low",
      "gemini-3.7-flash-high", "gemini-3.7-flash-medium", "gemini-3.7-flash-low",
      "gemini-3.6-flash-high", "gemini-3.6-flash-medium", "gemini-3.6-flash-low",
      "gemini-3.1-pro-high", "gemini-3.1-pro-low",
      "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium",
    ],
    efforts: ["Default", "low", "medium", "high"],
    directAPI: false,
  },
  {
    id: "meta",
    name: "Meta",
    models: ["Default", "muse-spark-1.3-contributor", "muse-spark-1.3", "muse-spark-1.2-contributor", "muse-spark-1.2", "muse-spark-1.1"],
    efforts: ["Default", "low", "medium", "high", "xhigh"],
    directAPI: true,
  },
  {
    id: "deepseek",
    name: "DeepSeek",
    models: ["Default", "deepseek-v4-pro", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"],
    efforts: ["Default", "high", "max"],
    directAPI: true,
  },
];

export const providerSpec = (id: string): ProviderSpec =>
  PROVIDERS.find((p) => p.id === id) ?? PROVIDERS[0];

// ---------------------------------------------------------------------------
// Settings model (persisted via the Rust backend)
// ---------------------------------------------------------------------------

export interface ProviderConfig {
  include: boolean;
  model: string;
  effort: string;
}

export interface Preset {
  name: string;
  providers: Record<string, ProviderConfig>;
  summaryProvider: string;
  summaryModel: string;
  summaryEffort: string;
}

export interface Settings {
  providers: Record<string, ProviderConfig>;
  summaryProvider: string;
  summaryModel: string;
  summaryEffort: string;
  webSearch: boolean;
  allowTools: boolean;
  presets: Preset[];
}

export const defaultProviderConfig = (): ProviderConfig => ({
  include: false,
  model: "Default",
  effort: "Default",
});

export const defaultSettings = (): Settings => ({
  providers: Object.fromEntries(PROVIDERS.map((p) => [p.id, defaultProviderConfig()])),
  summaryProvider: "codex",
  summaryModel: "Default",
  summaryEffort: "Default",
  webSearch: true,
  allowTools: false,
  presets: [],
});

export function applyFastMode(s: Settings): Settings {
  const next = { ...s, providers: { ...s.providers } };
  for (const p of PROVIDERS) {
    next.providers[p.id] = defaultProviderConfig();
  }
  next.providers.meta = { include: true, model: "muse-spark-1.3-contributor", effort: "high" };
  next.providers.google = { include: true, model: "gemini-3.8-flash-high", effort: "high" };
  next.providers.deepseek = { include: true, model: "deepseek-v4-flash", effort: "high" };
  next.providers.grok = { include: true, model: "grok-4.6", effort: "high" };
  next.summaryProvider = "codex";
  next.summaryModel = "gpt-5.6-luna";
  next.summaryEffort = "high";
  return next;
}

// ---------------------------------------------------------------------------
// Engine bridge
// ---------------------------------------------------------------------------

export interface EngineEvent {
  event: string;
  provider?: string;
  status?: string;
  reason?: string;
  error?: string;
  elapsed?: number;
  path?: string;
  message?: string;
  success?: boolean;
}

export interface RunRequest {
  prompt: string;
  providers: string[];
  webSearch: boolean;
  allowTools: boolean;
  contextFile?: string;
  attachments: string[];
  models: Record<string, string>;
  efforts: Record<string, string>;
  summaryModel?: string;
  summaryModelId?: string;
  summaryEffort?: string;
  resultsDir?: string;
}

export const engine = {
  run: (request: RunRequest) => invoke<{ pid: number }>("run_comparison", { request }),
  cancel: (resultsDir: string, provider: string) =>
    invoke<void>("cancel_provider", { resultsDir, provider }),
  readResult: (resultsDir: string, name: string) =>
    invoke<string>("read_result_file", { resultsDir, name }),
  loadSettings: () => invoke<string>("load_settings"),
  saveSettings: (settings: string) => invoke<void>("save_settings", { settings }),
  setApiKey: (name: string, value: string) => invoke<void>("set_api_key", { name, value }),
  hasApiKeys: () => invoke<Record<string, boolean>>("has_api_keys"),
  onEvent: (handler: (e: EngineEvent) => void) =>
    listen<EngineEvent>("engine-event", (ev) => handler(ev.payload)),
};
