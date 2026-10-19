import { afterEach, beforeEach, describe, expect, jest, test } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import puppy from "../Support/omp-puppy";

type Handler = (event: unknown, ctx: ExtensionContext) => unknown;

// Exercise the extension's real registered callbacks and real filesystem writes.
// Only the host event dispatcher/context is substituted; no writer is mocked.
function host(options: { hasUI?: boolean; kind?: "main" | "sub" } = {}) {
	const handlers = new Map<string, Handler>();
	let sessionId = "session-one";
	let name: string | undefined = "Puppy integration";
	let idle = true;
	// Host supplies a larger context; this seam implements every field Puppy consumes.
	const context = {
		hasUI: options.hasUI ?? true,
		agent: { kind: options.kind ?? "main", id: "test", name: "test", depth: 0 },
		cwd: "/workspace/puppy",
		sessionManager: { getSessionId: () => sessionId },
		isIdle: () => idle,
	} as ExtensionContext;
	// Registration is captured here instead of loading the interactive omp runtime.
	const api = {
		on: (event: string, handler: Handler) => handlers.set(event, handler),
		getSessionName: () => name,
	} as unknown as ExtensionAPI;
	puppy(api);
	return {
		context,
		emit(event: string, payload: Record<string, unknown> = {}) {
			const handler = handlers.get(event);
			if (!handler) throw new Error(`Missing handler: ${event}`);
			return handler({ type: event, ...payload }, context);
		},
		setIdle(value: boolean) { idle = value; },
		setSession(value: string) { sessionId = value; },
		setName(value: string | undefined) { name = value; },
	};
}

function assistant(stopReason = "stop", text = "**Done**: [updated files](https://example.com).") {
	return {
		role: "assistant",
		stopReason,
		content: [{ type: "thinking", thinking: "Do not persist private reasoning" }, { type: "text", text }],
	};
}

let root: string;
let directory: string;
let filename: string;
let previousDirectory: string | undefined;

beforeEach(() => {
	jest.useFakeTimers();
	root = mkdtempSync(join(tmpdir(), "puppy-omp-test-"));
	directory = join(root, "sessions");
	filename = join(directory, `${process.pid}.json`);
	previousDirectory = process.env.PUPPY_OMP_SESSIONS_DIR;
	process.env.PUPPY_OMP_SESSIONS_DIR = directory;
});

afterEach(() => {
	jest.clearAllTimers();
	jest.useRealTimers();
	if (previousDirectory === undefined) delete process.env.PUPPY_OMP_SESSIONS_DIR;
	else process.env.PUPPY_OMP_SESSIONS_DIR = previousDirectory;
	rmSync(root, { recursive: true, force: true });
});

function persisted() {
	return JSON.parse(readFileSync(filename, "utf8"));
}

describe("omp Puppy lifecycle publication", () => {
	test("startup is idle, contains process identity, and does not claim completion", () => {
		const omp = host();
		const before = Date.now();
		omp.emit("session_start");
		const state = persisted();
		expect(state).toMatchObject({
			schemaVersion: 1,
			pid: process.pid,
			sessionId: "session-one",
			cwd: "/workspace/puppy",
			name: "Puppy integration",
			status: "idle",
		});
		expect(Math.abs(state.processStartedAt - (Date.now() - process.uptime() * 1000))).toBeLessThan(100);
		expect(state.statusUpdatedAt).toBeGreaterThanOrEqual(before);
		expect(state.statusUpdatedAt).toBeLessThanOrEqual(Date.now());
		expect(state.completedAt).toBeUndefined();
		expect(state.summary).toBeUndefined();
		expect(statSync(filename).mode & 0o777).toBe(0o600);
		expect(readdirSync(directory)).toEqual([`${process.pid}.json`]);
	});

	test("terminal success publishes a short plain summary and next run clears completion", () => {
		const omp = host();
		omp.emit("session_start");
		omp.emit("agent_start");
		expect(persisted().status).toBe("busy");
		const before = Date.now();
		omp.emit("agent_end", { messages: [assistant("error"), assistant(), { role: "toolResult", content: [] }] });
		const complete = persisted();
		expect(complete.status).toBe("idle");
		expect(complete.completedAt).toBeGreaterThanOrEqual(before);
		expect(complete.completedAt).toBeLessThanOrEqual(Date.now());
		expect(complete.summary).toBe("Done: updated files.");
		expect(readFileSync(filename, "utf8")).not.toContain("private reasoning");
		omp.emit("agent_end", { messages: [assistant("stop", "Duplicate end")] });
		expect(persisted()).toEqual(complete);
		omp.emit("agent_start");
		expect(persisted().status).toBe("busy");
		expect(persisted().completedAt).toBeUndefined();
		expect(persisted().summary).toBeUndefined();
		expect(readdirSync(directory)).toEqual([`${process.pid}.json`]);
	});

	test("summary is bounded, strips controls, and is absent for non-text output", () => {
		const omp = host();
		omp.emit("agent_start");
		omp.emit("agent_end", { messages: [assistant("stop", `# Result\n\u001b[31m${"long ".repeat(100)}\u001b[0m`)] });
		const summary = persisted().summary;
		expect(summary.length).toBe(240);
		expect(summary.startsWith("Result long")).toBe(true);
		expect(summary.endsWith("…")).toBe(true);
		expect(summary).not.toContain("\u001b");
		omp.emit("agent_start");
		omp.emit("agent_end", { messages: [{ role: "assistant", stopReason: "stop", content: [{ type: "thinking", thinking: "secret" }] }] });
		expect(persisted().completedAt).toBeNumber();
		expect(persisted().summary).toBeUndefined();
	});

	for (const flags of [{ willContinue: true }, { awaitingAsyncWork: true }, { willContinue: true, awaitingAsyncWork: true }]) {
		test(`nonterminal settle remains busy: ${JSON.stringify(flags)}`, () => {
			const omp = host();
			omp.emit("agent_start");
			const busy = persisted();
			omp.emit("agent_end", { messages: [assistant()], ...flags });
			expect(persisted()).toEqual(busy);
			omp.emit("agent_end", { messages: [assistant()] });
			expect(persisted().completedAt).toBeNumber();
		});
	}

	test("terminal end before prompt unwind completes once the host becomes idle", () => {
		const omp = host();
		omp.emit("agent_start");
		omp.setIdle(false);
		omp.emit("agent_end", { messages: [assistant()] });
		jest.advanceTimersByTime(100);
		expect(persisted().status).toBe("busy");
		expect(persisted().completedAt).toBeUndefined();
		omp.setIdle(true);
		jest.advanceTimersByTime(100);
		expect(persisted().status).toBe("idle");
		expect(persisted().completedAt).toBeNumber();
		expect(persisted().summary).toBe("Done: updated files.");
	});

	for (const event of ["agent_start", "session_switch", "session_shutdown"]) {
		test(`${event} cancels a pending terminal publication`, () => {
			const omp = host();
			omp.emit("agent_start");
			omp.setIdle(false);
			omp.emit("agent_end", { messages: [assistant()] });
			omp.emit(event);
			omp.setIdle(true);
			jest.advanceTimersByTime(100);
			if (event === "session_shutdown") {
				expect(existsSync(filename)).toBe(false);
			} else {
				expect(persisted().status).toBe(event === "agent_start" ? "busy" : "idle");
				expect(persisted().completedAt).toBeUndefined();
			}
		});
	}

	for (const [reason, status] of [["aborted", "interrupted"], ["error", "error"], ["length", "idle"], ["toolUse", "idle"]]) {
		test(`${reason} is not completion`, () => {
			const omp = host();
			omp.emit("agent_start");
			omp.emit("agent_end", { messages: [assistant(), assistant(reason)] });
			expect(persisted().status).toBe(status);
			expect(persisted().completedAt).toBeUndefined();
			expect(persisted().summary).toBeUndefined();
		});
	}

	test("no assistant response cannot claim completion", () => {
		const omp = host();
		omp.emit("agent_start");
		omp.emit("agent_end", { messages: [{ role: "user", content: "hello" }] });
		expect(persisted().status).toBe("idle");
		expect(persisted().completedAt).toBeUndefined();
	});

	for (const event of ["session_start", "session_switch", "session_branch", "session_tree"]) {
		test(`${event} clears completion and refreshes identity`, () => {
			const omp = host();
			omp.emit("agent_start");
			omp.emit("agent_end", { messages: [assistant()] });
			const started = persisted().processStartedAt;
			omp.setSession("session-two");
			omp.setName(undefined);
			omp.context.cwd = "/workspace/other";
			omp.emit(event);
			const reset = persisted();
			expect(reset).toMatchObject({ sessionId: "session-two", cwd: "/workspace/other", processStartedAt: started, status: "idle" });
			expect(reset.name).toBeUndefined();
			expect(reset.completedAt).toBeUndefined();
			expect(reset.summary).toBeUndefined();
			omp.emit("agent_end", { messages: [assistant()] });
			expect(persisted()).toEqual(reset);
			omp.emit("agent_start");
			omp.emit("agent_end", { messages: [assistant()] });
			expect(persisted().completedAt).toBeNumber();
		});
	}

	test("changed session identity rejects an old run even without a switch notification", () => {
		const omp = host();
		omp.emit("agent_start");
		const oldRun = persisted();
		omp.setSession("session-two");
		omp.emit("agent_end", { messages: [assistant()] });
		expect(persisted()).toEqual(oldRun);
	});

	for (const options of [{ hasUI: false }, { kind: "sub" as const }, { hasUI: false, kind: "sub" as const }]) {
		test(`headless/subagent callbacks never publish or remove the main session: ${JSON.stringify(options)}`, () => {
			const ignored = host(options);
			ignored.emit("session_start");
			ignored.emit("agent_start");
			ignored.emit("agent_end", { messages: [assistant()] });
			expect(existsSync(directory)).toBe(false);
			const main = host();
			main.emit("agent_start");
			const state = persisted();
			ignored.emit("session_switch");
			ignored.emit("session_branch");
			ignored.emit("session_tree");
			ignored.emit("session_shutdown");
			expect(persisted()).toEqual(state);
		});
	}

	test("shutdown removes its snapshot and tolerates repeated cleanup", () => {
		const omp = host();
		omp.emit("session_start");
		expect(existsSync(filename)).toBe(true);
		omp.emit("session_shutdown");
		expect(existsSync(filename)).toBe(false);
		expect(() => omp.emit("session_shutdown")).not.toThrow();
		expect(readdirSync(directory)).toEqual([]);
	});

	test("filesystem failure never escapes and a later event can recover", () => {
		writeFileSync(directory, "not a directory");
		const omp = host();
		expect(() => omp.emit("session_start")).not.toThrow();
		expect(() => omp.emit("agent_start")).not.toThrow();
		expect(() => omp.emit("agent_end", { messages: [assistant()] })).not.toThrow();
		expect(() => omp.emit("session_shutdown")).not.toThrow();
		rmSync(directory);
		omp.emit("agent_start");
		omp.emit("agent_end", { messages: [assistant()] });
		expect(persisted().completedAt).toBeNumber();
		expect(readdirSync(directory)).toEqual([`${process.pid}.json`]);
	});
});
