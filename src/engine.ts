import { spawn } from "node:child_process";
import { accessSync, constants, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

/** Minimal shape of `ovp inspect --json` we depend on. */
export type OvpState = {
  schema_version?: number;
  meta?: {
    level?: string;
    latency_ms?: number;
    coverage?: number;
    confidence?: number;
    truncated?: boolean;
    escalation?: string | null;
    tokens_est?: number;
    class_counts?: Record<string, number>;
    hidden?: Record<string, number>;
    cache?: { ocr?: string; state?: string };
  };
  text?: Array<{ text: string; noise?: boolean; cls?: string; bbox: number[] }>;
  regions?: Array<{ kind: string; bbox: number[] }>;
  source?: Record<string, unknown>;
  state?: Record<string, unknown>;
};

export type RunResult = { code: number; stdout: string; stderr: string; ms: number };

export type Level = "fast" | "normal";

export type InspectOtpions = {
  target: "screen" | "window" | "file";
  path?: string;
  windowId?: number;
  level?: Level;
  maxChars?: number;
  grep?: string;
  region?: string;
  headlineOnly?: boolean;
  json?: boolean;
  cache?: boolean;
};

function isExecutable(p: string): boolean {
  try {
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Binary resolution order (documented in README):
 *   configured path -> OVP_BIN -> <pluginRoot>/bin/ovp -> ovp on PATH
 */
export function resolveBinary(opts: {
  configuredPath?: string;
  pluginRoot?: string;
  env?: NodeJS.ProcessEnv;
  pathEntries?: string[];
}): { path: string | null; tried: string[] } {
  const tried: string[] = [];
  const env = opts.env ?? process.env;
  const add = (candidate: string | undefined): string | null => {
    if (!candidate) return null;
    tried.push(candidate);
    return isExecutable(candidate) ? candidate : null;
  };

  let hit = add(opts.configuredPath);
  if (hit) return { path: hit, tried };

  hit = add(env.OVP_BIN);
  if (hit) return { path: hit, tried };

  if (opts.pluginRoot) {
    hit = add(join(opts.pluginRoot, "bin", "ovp"));
    if (hit) return { path: hit, tried };
    hit = add(join(opts.pluginRoot, ".build", "release", "ovp"));
    if (hit) return { path: hit, tried };
  }

  const entries = opts.pathEntries ?? (env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const dir of entries) {
    const candidate = join(dir, "ovp");
    if (existsSync(candidate)) {
      hit = add(candidate);
      if (hit) return { path: hit, tried };
    }
  }

  return { path: null, tried };
}

export function buildInspectArgs(o: InspectOtpions): string[] {
  const args = ["inspect"];
  if (o.target === "screen") args.push("--screen");
  else if (o.target === "window") args.push("--window", String(o.windowId ?? 0));
  else args.push(o.path ?? "");

  if (o.level) args.push("--level", o.level);
  if (typeof o.maxChars === "number") args.push("--max-chars", String(o.maxChars));
  if (o.grep) args.push("--grep", o.grep);
  if (o.region) args.push("--region", o.region);
  if (o.headlineOnly) args.push("--headline-only");
  if (o.json) args.push("--json");
  if (o.cache === false) args.push("--no-cache");
  return args;
}

export function runOvp(bin: string, args: string[], timeoutMs: number, signal?: AbortSignal): Promise<RunResult> {
  const started = Date.now();
  return new Promise((resolve) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      resolve({ code: 124, stdout, stderr: `${stderr}\novp: timed out after ${timeoutMs}ms`, ms: Date.now() - started });
    }, timeoutMs);
    const onAbort = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill("SIGKILL");
      resolve({ code: 130, stdout, stderr: "ovp: aborted", ms: Date.now() - started });
    };
    signal?.addEventListener("abort", onAbort, { once: true });

    child.stdout?.on("data", (d) => (stdout += String(d)));
    child.stderr?.on("data", (d) => (stderr += String(d)));
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: 127, stdout, stderr: `${stderr}\novp: ${err.message}`, ms: Date.now() - started });
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      resolve({ code: code ?? -1, stdout, stderr, ms: Date.now() - started });
    });
  });
}

/** `--json` prints exactly one JSON object; tolerate leading warning lines. */
export function parseOvpJson(stdout: string): OvpState | null {
  const start = stdout.indexOf("{");
  const end = stdout.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(stdout.slice(start, end + 1)) as OvpState;
  } catch {
    return null;
  }
}

const TEXT_MARKERS = [
  "You are a text-only model.",
  "HEADLINE:",
  "GREP ",
  "REGION ",
];

/** Extract the compact-text half when the engine was called with `--both`. */
export function parseOvpText(stdout: string): string {
  for (const marker of TEXT_MARKERS) {
    const i = stdout.indexOf(marker);
    if (i >= 0) return stdout.slice(i).trim();
  }
  return stdout.trim();
}

/** Persist a buffer for engines that take a file path. Caller removes the directory. */
export function stageBuffer(buffer: Buffer, fileName: string): { dir: string; path: string } {
  const dir = mkdtempSync(join(tmpdir(), "ovp-in-"));
  const safe = fileName.replace(/[^\w.\-]+/g, "_") || "input.png";
  const path = join(dir, safe);
  writeFileSync(path, buffer);
  return { dir, path };
}

export function cleanupDir(dir: string): void {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    /* best effort */
  }
}

/**
 * Escalation triggers are computed by the engine (meta.escalation) because they
 * came from measured real-scene comparisons; the plugin only surfaces them.
 */
export function escalationOf(state: OvpState | null): string | null {
  return state?.meta?.escalation ?? null;
}
