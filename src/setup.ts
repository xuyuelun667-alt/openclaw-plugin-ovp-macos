import { spawnSync } from "node:child_process";

/**
 * `openclaw ovp setup` — wire OVP into this OpenClaw install.
 *
 * The plugin does not silently mutate config on load: the user runs this command, it prints a
 * plan, and only then writes anything (unless --dry-run). Each write goes through the `openclaw
 * config set` CLI so the change is validated and audited by the host, exactly as if the user had
 * typed it.
 */

export type OvpConfigSnapshot = {
  imageModelPrimary?: string;
  mediaImageMaxChars?: number;
  mediaPreferredModel?: string;
  alsoAllow?: string[];
  explicitMediaModels: boolean;
};

export type ConfigOp = {
  path: string;
  /** JSON value to pass to `openclaw config set --strict-json`. */
  value: string;
  why: string;
};

export const PROVIDER_REF = "ovp-macos/ovp-local";
export const TOOL_NAME = "visual_inspect";
export const RUNTIME_MAX_CHARS = 1500;

/** Pure planning step: given the current config, what (minimally) still has to change? */
export function planSetup(snapshot: OvpConfigSnapshot): ConfigOp[] {
  const ops: ConfigOp[] = [];

  if (snapshot.imageModelPrimary !== PROVIDER_REF) {
    ops.push({
      path: "agents.defaults.imageModel.primary",
      value: JSON.stringify(PROVIDER_REF),
      why: `route inbound images to the local engine (currently ${snapshot.imageModelPrimary ?? "unset"})`,
    });
  }

  if (snapshot.mediaImageMaxChars !== RUNTIME_MAX_CHARS) {
    ops.push({
      path: "tools.media.image.maxChars",
      value: JSON.stringify(RUNTIME_MAX_CHARS),
      why: `the image-understanding default (500) truncates the compact state; fixed overhead is already ~460`,
    });
  }

  if (snapshot.mediaPreferredModel !== "ovp-macos") {
    ops.push({
      path: "tools.media.image.preferredModel",
      value: JSON.stringify("ovp-macos"),
      why: "keep the local provider first in the candidate order",
    });
  }

  const allow = snapshot.alsoAllow ?? [];
  if (!allow.includes(TOOL_NAME)) {
    ops.push({
      path: "tools.alsoAllow",
      value: JSON.stringify([...allow, TOOL_NAME]),
      why: `make the ${TOOL_NAME} tool visible to agents (plugin tools are not part of the coding profile)`,
    });
  }

  return ops;
}

/** Warnings that are not config writes but matter for a working install. */
export function setupWarnings(snapshot: OvpConfigSnapshot): string[] {
  const out: string[] = [];
  if (snapshot.explicitMediaModels) {
    out.push(
      "tools.media.models[] is set: an explicit model list takes precedence over `preferredModel` " +
        "and `imageModel`, so images may bypass this plugin. Remove the stale entry (for example a " +
        "hand-written CLI entry) if you want OVP to handle them.",
    );
  }
  return out;
}

function runOpenclaw(args: string[]): { ok: boolean; out: string } {
  const res = spawnSync("openclaw", args, { encoding: "utf8", timeout: 30000 });
  const out = `${res.stdout ?? ""}${res.stderr ?? ""}`.trim();
  return { ok: res.status === 0, out };
}

/** Read the current config through the host CLI so we never guess at the shape. */
export function readSnapshot(): OvpConfigSnapshot {
  const get = (path: string): unknown => {
    const r = runOpenclaw(["config", "get", path, "--json"]);
    if (!r.ok) return undefined;
    try {
      return JSON.parse(r.out);
    } catch {
      return undefined;
    }
  };

  const imageModel = get("agents.defaults.imageModel") as { primary?: string } | undefined;
  const mediaImage = get("tools.media.image") as { maxChars?: number; preferredModel?: string } | undefined;
  const mediaModels = get("tools.media.models");
  const allow = get("tools.alsoAllow");

  return {
    imageModelPrimary: imageModel?.primary,
    mediaImageMaxChars: mediaImage?.maxChars,
    mediaPreferredModel: mediaImage?.preferredModel,
    alsoAllow: Array.isArray(allow) ? (allow as string[]) : undefined,
    explicitMediaModels: Array.isArray(mediaModels) && mediaModels.length > 0,
  };
}

export type ApplyResult = { path: string; ok: boolean; detail: string };

export function applyOps(ops: ConfigOp[], dryRun: boolean): ApplyResult[] {
  if (dryRun) return ops.map((op) => ({ path: op.path, ok: true, detail: `would set ${op.value}` }));
  return ops.map((op) => {
    const r = runOpenclaw(["config", "set", op.path, op.value, "--strict-json"]);
    return { path: op.path, ok: r.ok, detail: r.ok ? `set ${op.value}` : r.out.slice(0, 200) };
  });
}

/** Config writes need a gateway restart to reach a running gateway; say so plainly. */
export function restartHint(): string {
  return [
    "Next: restart the gateway so the running process picks up the new config:",
    "  openclaw daemon restart",
    "Then verify with:  openclaw ovp doctor",
  ].join("\n");
}
