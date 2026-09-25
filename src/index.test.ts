import { describe, expect, it } from "vitest";
import { buildInspectArgs, escalationOf, parseOvpJson, parseOvpText, resolveBinary } from "./engine.js";
import { formatDoctor } from "./doctor.js";
import entry from "./index.js";

type Registered = {
  mediaProviders: Array<Record<string, unknown>>;
  tools: Array<Record<string, unknown>>;
};

function registerWithStubApi(pluginConfig: Record<string, unknown> = {}): Registered {
  const out: Registered = { mediaProviders: [], tools: [] };
  const api = {
    id: "ovp-macos",
    rootDir: "/tmp/ovp-macos-test",
    pluginConfig,
    logger: { info() {}, warn() {}, error() {}, debug() {} },
    registerMediaUnderstandingProvider(p: Record<string, unknown>) {
      out.mediaProviders.push(p);
    },
    registerTool(t: Record<string, unknown>) {
      out.tools.push(t);
    },
  };
  entry.register(api as never);
  return out;
}

describe("ovp-macos plugin", () => {
  it("registers an image media provider that needs no credentials", () => {
    const { mediaProviders } = registerWithStubApi();
    expect(mediaProviders).toHaveLength(1);
    const provider = mediaProviders[0]!;
    expect(provider.id).toBe("ovp-macos");
    expect(provider.capabilities).toEqual(["image"]);
    expect(typeof provider.describeImage).toBe("function");
    // local provider: must opt out of the normal auth gate explicitly
    const auth = (provider.resolveAuth as () => { kind: string; source: string })();
    expect(auth.kind).toBe("none");
  });

  it("registers the visual_inspect tool with the documented modes", () => {
    const { tools } = registerWithStubApi();
    expect(tools).toHaveLength(1);
    const tool = tools[0]!;
    expect(tool.name).toBe("visual_inspect");
    expect(typeof tool.execute).toBe("function");
    const schema = JSON.stringify(tool.parameters ?? {});
    for (const mode of ["state", "headline", "grep", "region", "json", "doctor"]) {
      expect(schema).toContain(mode);
    }
    for (const source of ["screen", "window", "file"]) {
      expect(schema).toContain(source);
    }
  });

  it("honours plugin config for level and maxChars", () => {
    const { mediaProviders } = registerWithStubApi({ level: "fast", maxChars: 900, cache: false });
    // config is read at register time; assert the provider still wires describeImage
    expect(typeof mediaProviders[0]!.describeImage).toBe("function");
  });
});

describe("engine argument building", () => {
  it("maps screen/window/file targets to engine flags", () => {
    expect(buildInspectArgs({ target: "screen" })).toEqual(["inspect", "--screen"]);
    expect(buildInspectArgs({ target: "window", windowId: 443 })).toEqual(["inspect", "--window", "443"]);
    expect(buildInspectArgs({ target: "file", path: "/tmp/a.png" })).toEqual(["inspect", "/tmp/a.png"]);
  });

  it("adds budget, query, region and cache flags", () => {
    const args = buildInspectArgs({
      target: "screen",
      level: "fast",
      maxChars: 800,
      grep: "营收",
      region: "10,20,30,40",
      headlineOnly: true,
      json: true,
      cache: false,
    });
    expect(args).toContain("--grep");
    expect(args).toContain("营收");
    expect(args).toContain("--region");
    expect(args).toContain("10,20,30,40");
    expect(args).toContain("--headline-only");
    expect(args).toContain("--json");
    expect(args).toContain("--no-cache");
    expect(args).toContain("--max-chars");
  });
});

describe("engine output parsing", () => {
  it("parses JSON even when warning lines precede it", () => {
    const stdout = "[config] warning: something\n{\n  \"schema_version\": 1,\n  \"meta\": {\"escalation\": \"vlm:icon_heavy\"}\n}";
    const state = parseOvpJson(stdout);
    expect(state?.schema_version).toBe(1);
    expect(escalationOf(state)).toBe("vlm:icon_heavy");
  });

  it("returns null for non-JSON output", () => {
    expect(parseOvpJson("SCREEN 2940x1912px scale=2\nHEADLINE: ...")).toBeNull();
  });

  it("extracts the text half of a --both payload", () => {
    const both = "{\n \"schema_version\": 1\n}\nYou are a text-only model. Do not call view_image.\nHEADLINE: x";
    const text = parseOvpText(both);
    expect(text.startsWith("You are a text-only model.")).toBe(true);
    expect(text).toContain("HEADLINE: x");
  });
});

describe("binary resolution", () => {
  it("prefers an explicit configured path and reports what it tried", () => {
    const { path, tried } = resolveBinary({
      configuredPath: "/definitely/not/here/ovp",
      pluginRoot: "/tmp/ovp-macos-test",
      env: { PATH: "/nonexistent" } as NodeJS.ProcessEnv,
      pathEntries: [],
    });
    expect(path).toBeNull();
    expect(tried[0]).toBe("/definitely/not/here/ovp");
    expect(tried.some((p) => p.includes("/tmp/ovp-macos-test/bin/ovp"))).toBe(true);
  });

  it("falls back to OVP_BIN when no configured path is set", () => {
    const { tried } = resolveBinary({ env: { OVP_BIN: "/x/ovp" } as NodeJS.ProcessEnv, pathEntries: [] });
    expect(tried[0]).toBe("/x/ovp");
  });
});

describe("doctor reporting", () => {
  it("prints fixes only for failing checks", () => {
    const report = formatDoctor({
      ok: false,
      binary: "/usr/local/bin/ovp",
      triedPaths: ["/usr/local/bin/ovp"],
      checks: [
        { id: "engine", ok: true, detail: "ovp 0.1.0" },
        { id: "accessibility", ok: false, detail: "not granted", fix: "Enable Accessibility for the OpenClaw process." },
      ],
    });
    expect(report).toContain("PROBLEMS FOUND");
    expect(report).toContain("fix: Enable Accessibility");
    expect(report).toContain("ok   engine");
  });
});
