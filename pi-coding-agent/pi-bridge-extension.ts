// pi bridge extension: lets pi sessions started by the Emacs
// pi-coding-agent frontend (pi --mode rpc subprocesses) drive the
// hosting Emacs.
//
// Tool: emacs_new_session — ask Emacs to open a brand-new pi session
// in another directory: Emacs creates a new perspective (persp-mode
// workspace), starts the session there, applies the pi window layout,
// and switches to it. An optional prompt is delivered to the fresh
// session as its first user message.
//
// Channel: the extension shells out to `emacsclient -e` with a
// base64-encoded JSON request.  The hosting Emacs evaluates
// `pi-coding-agent/open-session-at-directory-bridge' (defined in the
// layer's funcs.el) and returns a JSON string.  The layer ensures an
// Emacs server is running and passes the server socket path to pi in
// the PI_EMACS_SERVER environment variable, so emacsclient targets
// the exact Emacs instance that started this session.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const SERVER_ENV = "PI_EMACS_SERVER";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "emacs_new_session",
    label: "Open New Session in Emacs",
    description:
      "Ask the hosting Emacs (pi-coding-agent frontend) to open a brand-new pi " +
      "session in DIRECTORY: Emacs creates a new perspective (workspace) for it, " +
      "starts the pi session there, applies the pi window layout, and switches to it. " +
      "An optional PROMPT is delivered to the fresh session as its first user message. " +
      "Fails with a clear error when Emacs is unreachable (server not running) or the " +
      "directory already has a live unnamed session (pass NAME for a parallel session).",
    promptSnippet:
      "Open a new pi session in a different directory inside the hosting Emacs",
    promptGuidelines: [
      "Use emacs_new_session when the user wants a fresh session/workspace in another directory (e.g. to switch projects) instead of doing it manually.",
      "Pass an absolute or ~-style path; verify the directory exists (bash: test -d) before calling.",
      "Pass name when the directory already runs a session, to open a parallel named session.",
      "Pass prompt to have Emacs deliver a first user message to the fresh session right after it opens (e.g. a task goal).",
    ],
    parameters: Type.Object({
      directory: Type.String({
        description:
          "Directory to start the new session in (absolute path or ~-style; must exist)",
      }),
      name: Type.Optional(
        Type.String({
          description:
            "Optional session name; required to open a parallel session when the directory already has a live unnamed session",
        }),
      ),
      prompt: Type.Optional(
        Type.String({
          description:
            "Optional first user message to send to the new session once it opens",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, _onUpdate) {
      if (!process.env[SERVER_ENV]) {
        throw new Error(
          "This pi session is not hosted by the Emacs pi-coding-agent frontend (no " +
            SERVER_ENV +
            " env var) — emacs_new_session only works for sessions started from Emacs.",
        );
      }
      if (signal?.aborted) {
        return { content: [{ type: "text", text: "Cancelled" }], details: {} };
      }

      // Base64-encode the JSON payload so it can be embedded in a Lisp
      // string literal without any quoting/escaping hazards (JSON
      // \uXXXX escapes are not valid Emacs Lisp string escapes).
      const payload = JSON.stringify({
        directory: params.directory,
        name: params.name ?? null,
        prompt: params.prompt ?? null,
      });
      const b64 = Buffer.from(payload, "utf8").toString("base64");
      const lisp = `(pi-coding-agent/open-session-at-directory-bridge "${b64}")`;

      const args = ["-q", "--timeout=20"];
      if (process.env[SERVER_ENV]) {
        args.push("-s", process.env[SERVER_ENV]);
      }
      args.push("-e", lisp);

      // The first call into a fresh Emacs can be slow (session setup,
      // grammar checks, ...); a stale/unresponsive server can also
      // fail once and then work.  Retry once before giving up.
      let result = await pi.exec("emacsclient", args, {
        signal,
        timeout: 30000,
      });
      if (result.code !== 0 && !signal?.aborted) {
        await new Promise((r) => setTimeout(r, 3000));
        result = await pi.exec("emacsclient", args, {
          signal,
          timeout: 30000,
        });
      }

      if (result.code !== 0) {
        const why = (result.stderr || result.stdout || "").trim();
        throw new Error(
          "emacsclient failed to reach the hosting Emacs: " +
            (why || "is the Emacs server running?"),
        );
      }

      // emacsclient -e prints the printed representation of the
      // returned Lisp value: a Lisp string, i.e. the JSON text inside
      // quotes.  Parse the outer Lisp string first, then the JSON.
      const raw = result.stdout.trim();
      if (!raw) {
        throw new Error("Emacs returned an empty response");
      }
      let response: { ok: boolean; persp?: string; directory?: string; error?: string };
      try {
        response = JSON.parse(JSON.parse(raw));
      } catch (_e) {
        throw new Error(`Unparseable Emacs response: ${raw.slice(0, 200)}`);
      }
      if (!response.ok) {
        throw new Error(response.error ?? "Emacs refused to open the session");
      }
      return {
        content: [
          {
            type: "text",
            text: `Opened a new pi session in ${response.directory} (perspective: ${response.persp}); Emacs switched to it.`,
          },
        ],
        details: { ok: true, persp: response.persp, directory: response.directory },
      };
    },
  });
}
