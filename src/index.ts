import { Type } from "typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import {
  buildInspectArgs,
  cleanupDir,
  escalationOf,
  parseOvpJson,
  parseOvpText,
  resolveBinary,
  runOvp,
  stageBuffer,
  type Level,
  type OvpState,
} from "./engine.js";
import { formatDoctor, runDoctor } from "./doctor.js";

const PLUGIN_ID = "ovp-macos";
const PROVIDER_ID = "ovp-macos";
const TOOL_NAME = "visual_inspect";
const DEFAULT_MAX_CHARS = 1500;
const DEFAULT_TIMEOUT_MS = 20000;

type PluginConfig = {
  path?: string;
  level?: Level;
  maxChars?: number;
  timeoutMs?: number;
  cache?: boolean;
};

const MODES = ["state", "headline", "grep", "region", "json", "doctor"] as const;
const SOURCES = ["screen", "window", "file"] as const;
type Mode = (typeof MODES)[number];
type Source = (typeof SOURCES)[number];

type ToolParams = {
  mode?: Mode;
  source?: Source;
  path?: string;
  window_id?: number;
  query?: string;
  region?: string;
  max_chars?: number;
};

const ToolParameters = Type.Object({
  mode: Type.Optional(
    Type.Union(
      MODES.map((m) => Type.Literal(m)),
      {
        description:
          "state = full compact Visual State (default); headline = ~400-char triage; grep = search the cached state for a substring; region = contents of one rect; json = raw Visual State JSON; doctor = permission preflight.",
      },
    ),
  ),
  source: Type.Optional(
    Type.Union(SOURCES.map((s) => Type.Literal(s)), {
      description: "screen = live main display (default); window = one window id; file = an image path.",
    }),
  ),
  path: Type.Optional(Type.String({ description: "Image path when source=file." })),
  window_id: Type.Optional(Type.Integer({ description: "Window id (from `ovp windows`) when source=window." })),
  query: Type.Optional(Type.String({ description: "Substring for mode=grep." })),
  region: Type.Optional(Type.String({ description: "x,y,w,h (pixels) for mode=region." })),
  max_chars: Type.Optional(Type.Integer({ description: "Compact-text budget. Default 1500 (fixed overhead ≈460 chars)." })),
});

function normalizeParams(params: unknown): ToolParams {
  return params && typeof params === "object" ? (params as ToolParams) : {};
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "OVP Visual Preprocessor (macOS)",
  description:
    "Local visual input substitute for text-only agents: Apple Vision OCR + Accessibility structure -> compact, priority-ranked Visual State.",
  register(api) {
    const cfg = (api.pluginConfig ?? {}) as PluginConfig;
    const pluginRoot = api.rootDir;
    const level: Level = cfg.level ?? "normal";
    const maxChars = cfg.maxChars ?? DEFAULT_MAX_CHARS;
    const timeoutMs = cfg.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const useCache = cfg.cache !== false;

    const resolveBin = () => resolveBinary({ configuredPath: cfg.path, pluginRoot }).path;

    // ---- capability 1: image understanding (this is what makes an inbound
    //      screenshot arrive as a Visual State instead of raw bytes) ----
    api.registerMediaUnderstandingProvider({
      id: PROVIDER_ID,
      capabilities: ["image"],
      defaultModels: { image: "ovp-local" },
      autoPriority: { image: 100 },
      resolveAuth: () => ({ kind: "none", source: "local ovp: no credentials, no egress" }),
      describeImage: async (req) => {
        const bin = resolveBin();
        if (!bin) {
          throw new Error("ovp binary not found: run `npm run build:engine`, or set plugin config `path` / OVP_BIN.");
        }
        const staged = stageBuffer(req.buffer, req.fileName || "input.png");
        try {
          const args = buildInspectArgs({
            target: "file",
            path: staged.path,
            level,
            maxChars,
            cache: useCache,
          });
          const result = await runOvp(bin, args, req.timeoutMs ?? timeoutMs, req.signal);
          const text = result.stdout.trim();
          if (result.code !== 0 || !text) {
            throw new Error(`ovp failed (exit ${result.code}): ${result.stderr.trim() || "no output"}`);
          }
          return { text, model: "ovp-local" };
        } finally {
          cleanupDir(staged.dir);
        }
      },
    });

    // ---- capability 2: on-demand inspection (live screen, one window, region,
    //      grep, raw JSON, and the permission preflight) ----
    api.registerTool({
      name: TOOL_NAME,
      label: "Visual inspect (macOS)",
      description:
        "Read the screen, one window, or an image file as a compact Visual State (OCR text + bboxes, Accessibility controls, windows, priority-ranked with an explicit truncation contract). Local only: nothing leaves the machine. Use mode=doctor first if you suspect missing permissions.",
      parameters: ToolParameters,
      execute: async (_toolCallId: string, params: unknown, _signal?: AbortSignal) => {
        const p = normalizeParams(params);
        const mode: Mode = p.mode ?? "state";
        const source: Source = p.source ?? (p.path ? "file" : "screen");

        if (mode === "doctor") {
          const report = await runDoctor({ configuredPath: cfg.path, pluginRoot, timeoutMs });
          return {
            content: [{ type: "text" as const, text: formatDoctor(report) }],
            details: { mode, ok: report.ok, binary: report.binary },
          };
        }

        const bin = resolveBin();
        if (!bin) {
          const text =
            "ovp binary not found. Run `npm run build:engine` (needs Xcode Command Line Tools) or set the plugin `path` config.";
          return { content: [{ type: "text" as const, text }], details: { mode, ok: false } };
        }

        const target = source === "file" ? "file" : source === "window" ? "window" : "screen";
        const args = buildInspectArgs({
          target,
          path: p.path,
          windowId: p.window_id,
          level,
          maxChars: p.max_chars ?? maxChars,
          grep: mode === "grep" ? p.query : undefined,
          region: mode === "region" ? p.region : undefined,
          headlineOnly: mode === "headline",
          json: mode === "json",
          cache: useCache,
        });

        const result = await runOvp(bin, args, timeoutMs);
        if (result.code !== 0) {
          const text = `ovp failed (exit ${result.code}): ${result.stderr.trim() || "no output"}`;
          return { content: [{ type: "text" as const, text }], details: { mode, source, ok: false } };
        }

        if (mode === "json") {
          const state = parseOvpJson(result.stdout);
          return {
            content: [{ type: "text" as const, text: result.stdout.trim() }],
            details: {
              mode,
              source,
              ok: true,
              escalation: escalationOf(state),
              state: state as OvpState | null,
              latency_ms: result.ms,
            },
          };
        }

        const text = result.stdout.trim();
        const escalation = escalationOf(parseOvpJson(text)) ?? escalationFromText(text);
        return {
          content: [{ type: "text" as const, text }],
          details: { mode, source, ok: true, escalation, latency_ms: result.ms },
        };
      },
    });
  },
});

/** Fallback when the caller asked for compact text (no JSON to read). */
function escalationFromText(text: string): string | null {
  const line = text.split("\n").find((l) => l.startsWith("ESCALATE:"));
  if (!line) return null;
  const value = line.slice("ESCALATE:".length).trim().split(" ")[0];
  return value || null;
}
