import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ResizablePanelGroup as PanelGroup,
  ResizablePanel as Panel,
  ResizableHandle as PanelResizeHandle,
} from "@/components/ui/resizable";
import {
  Check, ChevronsUpDown, FileText, KeyRound, Loader2, Play, Square,
  Sparkles, Zap,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog";
import {
  PROVIDERS, providerSpec, applyFastMode, defaultProviderConfig,
  defaultSettings, engine, type EngineEvent, type Settings,
} from "@/lib/engine";
import { renderMarkdown } from "@/lib/markdown";
import { exportPdf, type PdfSection } from "@/lib/pdf";
import { cn } from "@/lib/utils";

type ProviderStatus = "idle" | "waiting" | "ok" | "error" | "stopped" | "skipped";

interface ProviderResult {
  status: ProviderStatus;
  text?: string;
  error?: string;
  reason?: string;
  elapsed?: number;
  includePdf: boolean;
}

const idleResult = (): ProviderResult => ({ status: "idle", includePdf: true });

// ---------------------------------------------------------------------------

export default function App() {
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [settingsLoaded, setSettingsLoaded] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [followUp, setFollowUp] = useState("");
  const [running, setRunning] = useState(false);
  const [resultsDir, setResultsDir] = useState<string | null>(null);
  const [results, setResults] = useState<Record<string, ProviderResult>>({});
  const [summaryStatus, setSummaryStatus] = useState<ProviderStatus>("idle");
  const [summaryText, setSummaryText] = useState("");
  const [summaryIncludePdf, setSummaryIncludePdf] = useState(true);
  const [lastPrompt, setLastPrompt] = useState("");
  const [presetName, setPresetName] = useState("");

  const runId = useRef(0);
  const resultsDirRef = useRef<string | null>(null);
  resultsDirRef.current = resultsDir;

  // ---- settings persistence ------------------------------------------------
  useEffect(() => {
    engine.loadSettings().then((raw) => {
      try {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === "object" && parsed.providers) {
          const merged = defaultSettings();
          for (const p of PROVIDERS) {
            const saved = parsed.providers[p.id];
            if (saved) merged.providers[p.id] = { ...defaultProviderConfig(), ...saved };
          }
          Object.assign(merged, {
            summaryProvider: parsed.summaryProvider ?? merged.summaryProvider,
            summaryModel: parsed.summaryModel ?? merged.summaryModel,
            summaryEffort: parsed.summaryEffort ?? merged.summaryEffort,
            webSearch: parsed.webSearch ?? true,
            allowTools: parsed.allowTools ?? false,
            presets: Array.isArray(parsed.presets) ? parsed.presets : [],
          });
          setSettings(merged);
        }
      } catch {
        /* corrupted settings — keep defaults */
      }
      setSettingsLoaded(true);
    });
  }, []);

  useEffect(() => {
    if (!settingsLoaded) return;
    const t = setTimeout(() => {
      engine.saveSettings(JSON.stringify(settings)).catch(console.error);
    }, 400);
    return () => clearTimeout(t);
  }, [settings, settingsLoaded]);

  // ---- engine events ---------------------------------------------------------
  useEffect(() => {
    const unlisten = engine.onEvent((e: EngineEvent) => {
      const id = runId.current;
      void id; // events carry no run id; single run at a time is enforced by `running`
      handleEvent(e);
    });
    return () => {
      unlisten.then((fn) => fn());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleEvent = useCallback((e: EngineEvent) => {
    switch (e.event) {
      case "results_dir":
        if (e.path) setResultsDir(e.path);
        break;
      case "start":
        if (e.provider) {
          setResults((r) => ({
            ...r,
            [e.provider!]: { ...(r[e.provider!] ?? idleResult()), status: "waiting" },
          }));
        }
        break;
      case "skip":
        if (e.provider) {
          setResults((r) => ({
            ...r,
            [e.provider!]: { status: "skipped", reason: e.reason, includePdf: false },
          }));
        }
        break;
      case "done": {
        const key = e.provider;
        if (!key) break;
        if (e.status === "ok" && resultsDirRef.current) {
          engine
            .readResult(resultsDirRef.current, `${key}.txt`)
            .then((text) =>
              setResults((r) => ({
                ...r,
                [key]: { status: "ok", text, elapsed: e.elapsed, includePdf: true },
              }))
            )
            .catch(() =>
              setResults((r) => ({
                ...r,
                [key]: { status: "error", error: "could not read result", includePdf: false },
              }))
            );
        } else if (e.status === "stopped") {
          setResults((r) => ({ ...r, [key]: { status: "stopped", includePdf: false } }));
        } else {
          setResults((r) => ({
            ...r,
            [key]: { status: "error", error: e.error ?? "unknown error", includePdf: false },
          }));
        }
        break;
      }
      case "summary_start":
        setSummaryStatus("waiting");
        break;
      case "summary_done":
        if (e.status === "ok" && resultsDirRef.current) {
          engine
            .readResult(resultsDirRef.current, "summary.txt")
            .then((text) => {
              setSummaryText(text);
              setSummaryStatus("ok");
            })
            .catch(() => setSummaryStatus("error"));
        } else {
          setSummaryStatus(e.status === "ok" ? "ok" : "error");
        }
        break;
      case "engine_exit":
      case "run_complete":
        setRunning(false);
        break;
    }
  }, []);

  // ---- actions ---------------------------------------------------------------
  const includedProviders = useMemo(
    () => PROVIDERS.filter((p) => settings.providers[p.id]?.include).map((p) => p.id),
    [settings.providers]
  );

  const run = useCallback(
    async (text: string, isFollowUp: boolean) => {
      if (!text.trim() || running || includedProviders.length === 0) return;
      runId.current += 1;
      setRunning(true);
      setResults({});
      setSummaryStatus("idle");
      setSummaryText("");
      setSummaryIncludePdf(true);
      if (!isFollowUp) setResultsDir(null);
      setLastPrompt(text.trim());

      const models: Record<string, string> = {};
      const efforts: Record<string, string> = {};
      for (const key of includedProviders) {
        const cfg = settings.providers[key];
        if (cfg) {
          models[key] = cfg.model;
          efforts[key] = cfg.effort;
        }
      }

      try {
        await engine.run({
          prompt: text.trim(),
          providers: includedProviders,
          webSearch: settings.webSearch,
          allowTools: settings.allowTools,
          contextFile:
            isFollowUp && resultsDir
              ? `${resultsDir}/conversation-context.txt`
              : undefined,
          attachments: [],
          models,
          efforts,
          summaryModel: settings.summaryProvider || undefined,
          summaryModelId: settings.summaryModel,
          summaryEffort: settings.summaryEffort,
        });
        if (!isFollowUp) setPrompt("");
        else setFollowUp("");
      } catch (err) {
        console.error(err);
        setRunning(false);
      }
    },
    [includedProviders, running, resultsDir, settings]
  );

  const setProviderConfig = (key: string, patch: Partial<Settings["providers"][string]>) =>
    setSettings((s) => ({
      ...s,
      providers: { ...s.providers, [key]: { ...s.providers[key], ...patch } },
    }));

  const selectAll = () =>
    setSettings((s) => ({
      ...s,
      providers: Object.fromEntries(
        PROVIDERS.map((p) => [p.id, { ...s.providers[p.id], include: true }])
      ),
    }));

  const selectNone = () =>
    setSettings((s) => ({
      ...s,
      providers: Object.fromEntries(
        PROVIDERS.map((p) => [p.id, { ...s.providers[p.id], include: false }])
      ),
    }));

  const savePreset = () => {
    const name = presetName.trim();
    if (!name) return;
    setSettings((s) => {
      const preset = {
        name,
        providers: s.providers,
        summaryProvider: s.summaryProvider,
        summaryModel: s.summaryModel,
        summaryEffort: s.summaryEffort,
      };
      const others = s.presets.filter((p) => p.name !== name);
      return { ...s, presets: [...others, preset].slice(-2) }; // two custom slots
    });
    setPresetName("");
  };

  const applyPreset = (name: string) => {
    const preset = settings.presets.find((p) => p.name === name);
    if (!preset) return;
    setSettings((s) => ({
      ...s,
      providers: preset.providers,
      summaryProvider: preset.summaryProvider,
      summaryModel: preset.summaryModel,
      summaryEffort: preset.summaryEffort,
    }));
  };

  const doExportPdf = () => {
    const sections: PdfSection[] = [];
    if (summaryStatus === "ok" && summaryIncludePdf && summaryText) {
      sections.push({ title: "Synthesis", markdown: summaryText });
    }
    for (const key of includedProviders) {
      const r = results[key];
      if (r?.status === "ok" && r.includePdf && r.text) {
        sections.push({ title: providerSpec(key).name, markdown: r.text });
      }
    }
    if (sections.length) exportPdf(sections, lastPrompt);
  };

  const exportableCount =
    (summaryStatus === "ok" && summaryIncludePdf ? 1 : 0) +
    includedProviders.filter(
      (k) => results[k]?.status === "ok" && results[k]?.includePdf
    ).length;

  // ---- render ------------------------------------------------------------------
  return (
    <div className="h-screen w-screen overflow-hidden bg-background text-foreground">
      <PanelGroup orientation="horizontal">
        <Panel defaultSize="24%" minSize="18%" maxSize="36%">
          <Sidebar
            settings={settings}
            setProviderConfig={setProviderConfig}
            setSettings={setSettings}
            selectAll={selectAll}
            selectNone={selectNone}
            presetName={presetName}
            setPresetName={setPresetName}
            savePreset={savePreset}
            applyPreset={applyPreset}
            running={running}
          />
        </Panel>
        <PanelResizeHandle className="w-1 bg-border hover:bg-primary/40 transition-colors" />
        <Panel defaultSize="76%">
          <PanelGroup orientation="vertical" className="h-full">
            <Panel defaultSize="22%" minSize="12%">
              <Composer
                title="Ask The Room"
                value={prompt}
                onChange={setPrompt}
                onSubmit={() => run(prompt, false)}
                running={running}
                disabled={includedProviders.length === 0}
                placeholder="Ask every selected model at once…"
              />
            </Panel>
            <PanelResizeHandle className="h-1 bg-border hover:bg-primary/40 transition-colors" />
            <Panel defaultSize="48%" minSize="20%">
              <ResponseGrid
                results={results}
                included={includedProviders}
                running={running}
                resultsDir={resultsDir}
                onCancel={(key) => resultsDir && engine.cancel(resultsDir, key)}
                onTogglePdf={(key, v) =>
                  setResults((r) => ({ ...r, [key]: { ...r[key], includePdf: v } }))
                }
                exportableCount={exportableCount}
                onExport={doExportPdf}
              />
            </Panel>
            <PanelResizeHandle className="h-1 bg-border hover:bg-primary/40 transition-colors" />
            <Panel defaultSize="30%" minSize="15%">
              <SynthesisPanel
                status={summaryStatus}
                text={summaryText}
                includePdf={summaryIncludePdf}
                onTogglePdf={setSummaryIncludePdf}
                provider={settings.summaryProvider}
                followUp={followUp}
                onFollowUpChange={setFollowUp}
                onFollowUpSubmit={() => run(followUp, true)}
                running={running}
                canFollowUp={!!resultsDir}
              />
            </Panel>
          </PanelGroup>
        </Panel>
      </PanelGroup>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

function Sidebar(props: {
  settings: Settings;
  setProviderConfig: (key: string, patch: Partial<Settings["providers"][string]>) => void;
  setSettings: React.Dispatch<React.SetStateAction<Settings>>;
  selectAll: () => void;
  selectNone: () => void;
  presetName: string;
  setPresetName: (v: string) => void;
  savePreset: () => void;
  applyPreset: (name: string) => void;
  running: boolean;
}) {
  const { settings, setProviderConfig, setSettings, selectAll, selectNone, running } = props;
  const [keyStatus, setKeyStatus] = useState<Record<string, boolean>>({});

  useEffect(() => {
    engine.hasApiKeys().then(setKeyStatus).catch(() => {});
  }, []);

  return (
    <div className="flex h-full flex-col border-r bg-muted/30">
      <div className="flex items-center gap-2 px-4 pt-4 pb-2">
        <Sparkles className="h-5 w-5 text-primary" />
        <h1 className="text-base font-semibold tracking-tight">Model Compare</h1>
      </div>

      <ScrollArea className="flex-1 px-3">
        {/* Quick selects */}
        <div className="flex flex-wrap gap-1.5 py-2">
          <Button size="sm" variant="outline" onClick={selectAll} disabled={running}>All</Button>
          <Button size="sm" variant="outline" onClick={selectNone} disabled={running}>None</Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setSettings((s) => applyFastMode(s))}
            disabled={running}
          >
            <Zap className="mr-1 h-3.5 w-3.5" /> Fast Mode
          </Button>
        </div>

        {/* Custom presets */}
        <div className="flex items-center gap-1.5 py-1">
          <Input
            value={props.presetName}
            onChange={(e) => props.setPresetName(e.target.value)}
            placeholder="Preset name"
            className="h-8 text-xs"
          />
          <Button size="sm" variant="outline" onClick={props.savePreset} disabled={running || !props.presetName.trim()}>
            Save
          </Button>
        </div>
        {settings.presets.length > 0 && (
          <div className="flex flex-wrap gap-1.5 py-1">
            {settings.presets.map((p) => (
              <Button
                key={p.name}
                size="sm"
                variant="ghost"
                className="h-7 px-2 text-xs"
                onClick={() => props.applyPreset(p.name)}
                disabled={running}
              >
                {p.name}
              </Button>
            ))}
          </div>
        )}

        <Separator className="my-2" />

        {/* Providers */}
        <div className="space-y-1 pb-2">
          {PROVIDERS.map((p) => {
            const cfg = settings.providers[p.id];
            const needsKey = p.directAPI || p.id === "glm";
            const keyName = p.id === "glm" ? "zai" : p.id;
            const missingKey = needsKey && keyStatus[keyName] === false;
            return (
              <div
                key={p.id}
                className={cn(
                  "rounded-lg border p-2 transition-colors",
                  cfg.include ? "bg-card border-primary/30" : "bg-transparent"
                )}
              >
                <div className="flex items-center gap-2">
                  <Checkbox
                    checked={cfg.include}
                    onCheckedChange={(v) => setProviderConfig(p.id, { include: !!v })}
                    disabled={running}
                    id={`inc-${p.id}`}
                  />
                  <Label htmlFor={`inc-${p.id}`} className="flex-1 cursor-pointer text-sm font-medium">
                    {p.name}
                  </Label>
                  {missingKey && (
                    <Badge variant="outline" className="text-[10px] text-amber-600 border-amber-400">
                      key missing
                    </Badge>
                  )}
                </div>
                {cfg.include && (
                  <div className="mt-2 grid grid-cols-2 gap-1.5 pl-6">
                    <Select
                      value={cfg.model}
                      onValueChange={(v) => setProviderConfig(p.id, { model: v })}
                      disabled={running}
                    >
                      <SelectTrigger className="h-7 text-xs">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {p.models.map((m) => (
                          <SelectItem key={m} value={m} className="text-xs">{m}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    <Select
                      value={cfg.effort}
                      onValueChange={(v) => setProviderConfig(p.id, { effort: v })}
                      disabled={running || p.efforts.length < 2}
                    >
                      <SelectTrigger className="h-7 text-xs">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {p.efforts.map((e) => (
                          <SelectItem key={e} value={e} className="text-xs">{e}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        <Separator className="my-2" />

        {/* Synthesis picker */}
        <div className="space-y-2 py-2">
          <Label className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Synthesis
          </Label>
          <Select
            value={settings.summaryProvider}
            onValueChange={(v) => {
              const spec = providerSpec(v);
              setSettings((s) => ({
                ...s,
                summaryProvider: v,
                summaryModel: "Default",
                summaryEffort: spec.efforts[0] ?? "Default",
              }));
            }}
            disabled={running}
          >
            <SelectTrigger className="h-8 text-xs">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {PROVIDERS.map((p) => (
                <SelectItem key={p.id} value={p.id} className="text-xs">{p.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <div className="grid grid-cols-2 gap-1.5">
            <Select
              value={settings.summaryModel}
              onValueChange={(v) => setSettings((s) => ({ ...s, summaryModel: v }))}
              disabled={running}
            >
              <SelectTrigger className="h-7 text-xs"><SelectValue /></SelectTrigger>
              <SelectContent>
                {providerSpec(settings.summaryProvider).models.map((m) => (
                  <SelectItem key={m} value={m} className="text-xs">{m}</SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select
              value={settings.summaryEffort}
              onValueChange={(v) => setSettings((s) => ({ ...s, summaryEffort: v }))}
              disabled={running}
            >
              <SelectTrigger className="h-7 text-xs"><SelectValue /></SelectTrigger>
              <SelectContent>
                {providerSpec(settings.summaryProvider).efforts.map((e) => (
                  <SelectItem key={e} value={e} className="text-xs">{e}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>

        <Separator className="my-2" />

        {/* Global toggles + keys */}
        <div className="space-y-3 py-2 pb-4">
          <div className="flex items-center justify-between">
            <Label className="text-sm">Web search</Label>
            <Switch
              checked={settings.webSearch}
              onCheckedChange={(v) => setSettings((s) => ({ ...s, webSearch: v }))}
              disabled={running}
            />
          </div>
          <div className="flex items-center justify-between">
            <Label className="text-sm">Allow tools</Label>
            <Switch
              checked={settings.allowTools}
              onCheckedChange={(v) => setSettings((s) => ({ ...s, allowTools: v }))}
              disabled={running}
            />
          </div>
          <ApiKeysDialog onSaved={() => engine.hasApiKeys().then(setKeyStatus)} />
        </div>
      </ScrollArea>
    </div>
  );
}

function ApiKeysDialog({ onSaved }: { onSaved: () => void }) {
  const [open, setOpen] = useState(false);
  const [values, setValues] = useState<Record<string, string>>({});
  const fields = [
    { name: "meta", label: "Meta API key" },
    { name: "deepseek", label: "DeepSeek API key" },
    { name: "zai", label: "Z.AI (GLM) API key" },
    { name: "tavily", label: "Tavily API key" },
  ];
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" className="w-full">
          <KeyRound className="mr-2 h-3.5 w-3.5" /> API Keys
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>API Keys</DialogTitle>
        </DialogHeader>
        <p className="text-xs text-muted-foreground">
          Stored in your OS credential vault. Leave blank to remove a key.
        </p>
        <div className="space-y-3">
          {fields.map((f) => (
            <div key={f.name} className="space-y-1">
              <Label className="text-xs">{f.label}</Label>
              <Input
                type="password"
                value={values[f.name] ?? ""}
                onChange={(e) => setValues((v) => ({ ...v, [f.name]: e.target.value }))}
                placeholder="••••••••"
              />
            </div>
          ))}
          <Button
            className="w-full"
            onClick={async () => {
              for (const f of fields) {
                const v = values[f.name];
                if (v !== undefined && v !== "") await engine.setApiKey(f.name, v);
              }
              setValues({});
              setOpen(false);
              onSaved();
            }}
          >
            Save to vault
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Composer
// ---------------------------------------------------------------------------

function Composer(props: {
  title: string;
  value: string;
  onChange: (v: string) => void;
  onSubmit: () => void;
  running: boolean;
  disabled?: boolean;
  placeholder: string;
}) {
  return (
    <div className="flex h-full flex-col gap-2 p-4">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold tracking-tight">{props.title}</h2>
      </div>
      <Textarea
        value={props.value}
        onChange={(e) => props.onChange(e.target.value)}
        placeholder={props.placeholder}
        className="min-h-0 flex-1 resize-none text-sm"
        onKeyDown={(e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter") props.onSubmit();
        }}
      />
      <div className="flex items-center justify-between">
        <span className="text-xs text-muted-foreground">
          {props.disabled ? "Select at least one provider" : "Ctrl/⌘ + Enter to send"}
        </span>
        <Button onClick={props.onSubmit} disabled={props.running || props.disabled || !props.value.trim()}>
          {props.running ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <Play className="mr-2 h-4 w-4" />}
          Ask
        </Button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Response grid
// ---------------------------------------------------------------------------

function ResponseGrid(props: {
  results: Record<string, ProviderResult>;
  included: string[];
  running: boolean;
  resultsDir: string | null;
  onCancel: (key: string) => void;
  onTogglePdf: (key: string, v: boolean) => void;
  exportableCount: number;
  onExport: () => void;
}) {
  const visible = props.included;
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between px-4 pt-3 pb-1">
        <h2 className="text-sm font-semibold tracking-tight">Responses</h2>
        <Button
          size="sm"
          variant="outline"
          disabled={props.exportableCount === 0}
          onClick={props.onExport}
        >
          <FileText className="mr-2 h-3.5 w-3.5" />
          Export PDF ({props.exportableCount})
        </Button>
      </div>
      <ScrollArea className="flex-1 px-4 pb-4">
        {visible.length === 0 ? (
          <p className="pt-6 text-center text-sm text-muted-foreground">
            Select providers on the left, then ask a question.
          </p>
        ) : (
          <div className="grid grid-cols-1 gap-3 xl:grid-cols-2">
            {visible.map((key) => (
              <ResponseCard
                key={key}
                providerKey={key}
                result={props.results[key]}
                onCancel={() => props.onCancel(key)}
                onTogglePdf={(v) => props.onTogglePdf(key, v)}
              />
            ))}
          </div>
        )}
      </ScrollArea>
    </div>
  );
}

function ResponseCard(props: {
  providerKey: string;
  result?: ProviderResult;
  onCancel: () => void;
  onTogglePdf: (v: boolean) => void;
}) {
  const spec = providerSpec(props.providerKey);
  const r = props.result ?? idleResult();
  return (
    <div className="flex flex-col rounded-xl border bg-card shadow-sm">
      <div className="flex items-center gap-2 border-b px-3 py-2">
        <span className="text-sm font-semibold">{spec.name}</span>
        <StatusBadge result={r} />
        <div className="ml-auto flex items-center gap-2">
          {r.status === "ok" && (
            <label className="flex items-center gap-1 text-[11px] text-muted-foreground">
              <Checkbox
                checked={r.includePdf}
                onCheckedChange={(v) => props.onTogglePdf(!!v)}
                className="h-3.5 w-3.5"
              />
              PDF
            </label>
          )}
          {r.status === "waiting" && (
            <Button size="icon" variant="ghost" className="h-6 w-6" onClick={props.onCancel} title="Stop waiting">
              <Square className="h-3 w-3" />
            </Button>
          )}
        </div>
      </div>
      <div className="max-h-96 overflow-y-auto px-4 py-3">
        {r.status === "idle" && (
          <p className="text-xs text-muted-foreground">Ready.</p>
        )}
        {r.status === "waiting" && (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" /> Thinking…
          </div>
        )}
        {r.status === "skipped" && (
          <p className="text-xs text-muted-foreground">Skipped: {r.reason}</p>
        )}
        {r.status === "stopped" && (
          <p className="text-xs text-muted-foreground">Stopped waiting.</p>
        )}
        {r.status === "error" && (
          <p className="text-xs text-destructive">{r.error}</p>
        )}
        {r.status === "ok" && r.text && (
          <div
            className="prose prose-sm max-w-none dark:prose-invert prose-pre:whitespace-pre-wrap prose-table:text-xs"
            dangerouslySetInnerHTML={{ __html: renderMarkdown(r.text) }}
          />
        )}
      </div>
    </div>
  );
}

function StatusBadge({ result }: { result: ProviderResult }) {
  switch (result.status) {
    case "waiting":
      return <Badge variant="secondary" className="text-[10px]">running</Badge>;
    case "ok":
      return (
        <Badge variant="default" className="gap-1 text-[10px]">
          <Check className="h-3 w-3" />
          {result.elapsed != null ? `${result.elapsed.toFixed(1)}s` : "done"}
        </Badge>
      );
    case "error":
      return <Badge variant="destructive" className="text-[10px]">error</Badge>;
    case "skipped":
      return <Badge variant="outline" className="text-[10px]">skipped</Badge>;
    case "stopped":
      return <Badge variant="outline" className="text-[10px]">stopped</Badge>;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Synthesis panel with follow-up composer
// ---------------------------------------------------------------------------

function SynthesisPanel(props: {
  status: ProviderStatus;
  text: string;
  includePdf: boolean;
  onTogglePdf: (v: boolean) => void;
  provider: string;
  followUp: string;
  onFollowUpChange: (v: string) => void;
  onFollowUpSubmit: () => void;
  running: boolean;
  canFollowUp: boolean;
}) {
  return (
    <div className="flex h-full flex-col border-t bg-muted/20">
      <div className="flex items-center gap-2 px-4 pt-3 pb-1">
        <h2 className="text-sm font-semibold tracking-tight">
          Synthesis <span className="text-muted-foreground font-normal">({providerSpec(props.provider).name})</span>
        </h2>
        {props.status === "waiting" && <Loader2 className="h-3.5 w-3.5 animate-spin text-muted-foreground" />}
        {props.status === "ok" && (
          <label className="ml-auto flex items-center gap-1 text-[11px] text-muted-foreground">
            <Checkbox
              checked={props.includePdf}
              onCheckedChange={(v) => props.onTogglePdf(!!v)}
              className="h-3.5 w-3.5"
            />
            PDF
          </label>
        )}
      </div>
      <ScrollArea className="min-h-0 flex-1 px-4">
        {props.status === "ok" && props.text ? (
          <div
            className="prose prose-sm max-w-none pb-3 dark:prose-invert prose-pre:whitespace-pre-wrap prose-table:text-xs"
            dangerouslySetInnerHTML={{ __html: renderMarkdown(props.text) }}
          />
        ) : (
          <p className="text-xs text-muted-foreground">
            {props.status === "waiting"
              ? "Synthesizing answers…"
              : props.status === "error"
                ? "Synthesis failed."
                : "The combined answer will appear here."}
          </p>
        )}
      </ScrollArea>
      <Separator />
      <div className="flex items-end gap-2 p-3">
        <Textarea
          value={props.followUp}
          onChange={(e) => props.onFollowUpChange(e.target.value)}
          placeholder={props.canFollowUp ? "Ask a follow-up with full context…" : "Run a comparison first to enable follow-ups"}
          disabled={!props.canFollowUp || props.running}
          className="min-h-[64px] flex-1 resize-none text-sm"
          onKeyDown={(e) => {
            if ((e.metaKey || e.ctrlKey) && e.key === "Enter") props.onFollowUpSubmit();
          }}
        />
        <Button
          onClick={props.onFollowUpSubmit}
          disabled={!props.canFollowUp || props.running || !props.followUp.trim()}
        >
          {props.running ? <Loader2 className="h-4 w-4 animate-spin" /> : <ChevronsUpDown className="mr-1 h-4 w-4 rotate-90" />}
          Follow up
        </Button>
      </div>
    </div>
  );
}
