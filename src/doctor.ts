import { resolveBinary, runOvp } from "./engine.js";

export type DoctorCheck = {
  id: string;
  ok: boolean;
  detail: string;
  fix?: string;
};

export type DoctorReport = {
  ok: boolean;
  binary: string | null;
  triedPaths: string[];
  checks: DoctorCheck[];
};

const PERM_FIX =
  "System Settings -> Privacy & Security -> grant this to the process that runs OpenClaw " +
  "(the Gateway/node binary). Child processes inherit the grant, so ovp does not need its own entry.";

/**
 * Preflight for the two things that silently break macOS screen reading:
 * Accessibility (AX tree / control reads) and Screen Recording (window list + capture).
 *
 * Only run on darwin; other platforms fail fast with a clear message.
 */
export async function runDoctor(opts: {
  configuredPath?: string;
  pluginRoot?: string;
  timeoutMs?: number;
}): Promise<DoctorReport> {
  const timeoutMs = opts.timeoutMs ?? 20000;
  const checks: DoctorCheck[] = [];

  if (process.platform !== "darwin") {
    return {
      ok: false,
      binary: null,
      triedPaths: [],
      checks: [
        {
          id: "platform",
          ok: false,
          detail: `platform is ${process.platform}; this plugin is macOS-only`,
          fix: "Use a macOS host for OVP. Cross-platform backends are out of scope.",
        },
      ],
    };
  }

  const { path: bin, tried } = resolveBinary({
    configuredPath: opts.configuredPath,
    pluginRoot: opts.pluginRoot,
  });

  if (!bin) {
    return {
      ok: false,
      binary: null,
      triedPaths: tried,
      checks: [
        {
          id: "engine",
          ok: false,
          detail: `ovp binary not found (tried: ${tried.join(", ") || "nothing"})`,
          fix: "Run `npm run build:engine` (needs Xcode Command Line Tools) or set config path / OVP_BIN.",
        },
      ],
    };
  }

  const version = await runOvp(bin, ["version"], timeoutMs);
  checks.push({
    id: "engine",
    ok: version.code === 0 && version.stdout.includes("ovp"),
    detail: version.code === 0 ? version.stdout.trim() : `exit ${version.code}: ${version.stderr.trim()}`,
    fix: version.code === 0 ? undefined : "Rebuild the engine: `npm run build:engine`.",
  });

  const ax = await runOvp(bin, ["ax-check"], Math.max(timeoutMs, 30000));
  const axLine = ax.stdout.split("\n").find((l) => l.startsWith("AX trusted:")) ?? "";
  const axTrusted = axLine.includes("true");
  checks.push({
    id: "accessibility",
    ok: axTrusted,
    detail: axTrusted
      ? "Accessibility granted — AX roles/titles/actions are available"
      : `Accessibility NOT granted (${axLine.trim() || "no output"}) — control reads will be empty`,
    fix: axTrusted ? undefined : `Enable Accessibility for the OpenClaw process. ${PERM_FIX}`,
  });

  const wins = await runOvp(bin, ["windows"], timeoutMs);
  const rows = wins.stdout.split("\n").filter((l) => l.trim().length > 0);
  const namedRows = rows.filter((l) => {
    const parts = l.split("\t");
    return (parts[1] ?? "").trim().length > 0;
  });
  const screenOk = wins.code === 0 && namedRows.length > 0;
  checks.push({
    id: "screen_recording",
    ok: screenOk,
    detail: screenOk
      ? `window list readable (${namedRows.length}/${rows.length} rows named)`
      : `window list returned ${rows.length} rows, none with an owner name — usually missing Screen Recording permission`,
    fix: screenOk ? undefined : `Enable Screen Recording for the OpenClaw process. ${PERM_FIX}`,
  });

  if (screenOk) {
    const smoke = await runOvp(
      bin,
      ["inspect", "--screen", "--headline-only", "--max-chars", "800", "--no-cache"],
      Math.max(timeoutMs, 30000),
    );
    const head = smoke.stdout.split("\n").find((l) => l.startsWith("HEADLINE:"));
    checks.push({
      id: "capture_smoke",
      ok: smoke.code === 0 && Boolean(head),
      detail: head ? head.slice(0, 160) : `exit ${smoke.code}: ${smoke.stderr.trim().slice(0, 160)}`,
      fix: smoke.code === 0 && head ? undefined : "Screen capture failed; re-check Screen Recording permission.",
    });
  }

  return { ok: checks.every((c) => c.ok), binary: bin, triedPaths: tried, checks };
}

export function formatDoctor(report: DoctorReport): string {
  const lines = [
    `OVP doctor — ${report.ok ? "OK" : "PROBLEMS FOUND"}`,
    `engine: ${report.binary ?? "(not found)"}`,
  ];
  for (const c of report.checks) {
    lines.push(`${c.ok ? "  ok  " : "  FAIL"} ${c.id}: ${c.detail}`);
    if (!c.ok && c.fix) lines.push(`        fix: ${c.fix}`);
  }
  if (!report.ok && report.triedPaths.length > 0) {
    lines.push(`searched: ${report.triedPaths.join(", ")}`);
  }
  return lines.join("\n");
}
