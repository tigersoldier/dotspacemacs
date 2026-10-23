import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createInterface } from "node:readline";

const MESSAGE_LINE = /^[ \t]*\{[ \t]*"type"[ \t]*:[ \t]*"message"/;
const SESSION_INFO_LINE = /^[ \t]*\{[ \t]*"type"[ \t]*:[ \t]*"session_info"/;
const MAX_METADATA_PREFIX_BYTES = 16 * 1024;

function parseObject(line) {
  try {
    const value = JSON.parse(line);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

function messageText(message) {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join(" ");
}

function sameVersion(before, after) {
  return before.size === after.size && before.mtimeMs === after.mtimeMs;
}

async function scanFile(file) {
  let before;
  try {
    before = await stat(file);
  } catch {
    return { path: file, valid: false, stable: false };
  }

  let header = null;
  let name = null;
  let nameFound = false;
  let firstMessage = null;
  let fallbackMessage = null;
  let previewAttempts = 0;
  let firstLine = true;
  let scannedBytes = 0;

  try {
    const input = createReadStream(file, {
      encoding: "utf8",
      highWaterMark: MAX_METADATA_PREFIX_BYTES,
    });
    const lines = createInterface({ input, crlfDelay: Infinity });
    for await (let line of lines) {
      if (firstLine) {
        line = line.replace(/^\uFEFF/, "");
        firstLine = false;
      }
      scannedBytes += Buffer.byteLength(line, "utf8") + 1;

      if (!header) {
        if (!/^[ \t\r]*$/.test(line)) {
          const candidate = parseObject(line);
          if (candidate?.type === "session") {
            header = candidate;
          } else {
            lines.close();
            input.destroy();
            break;
          }
        }
      } else if (MESSAGE_LINE.test(line)) {
        const preview = firstMessage === null && previewAttempts < 5;
        if (preview) previewAttempts++; // Malformed messages consume an attempt.
        if (preview) {
          const entry = parseObject(line);
          if (entry) {
            const message = entry.message;
            const text = messageText(message);
            if (message?.role === "user" && text !== "") {
              firstMessage = text;
            } else if (fallbackMessage === null) {
              fallbackMessage = text;
            }
          }
        }
      } else if (!nameFound && SESSION_INFO_LINE.test(line)) {
        const entry = parseObject(line);
        if (entry) {
          const raw = typeof entry.name === "string" ? entry.name.trim() : "";
          name = raw || null;
          nameFound = true;
        }
      }

      const previewComplete = firstMessage !== null || previewAttempts >= 5;
      if (scannedBytes >= MAX_METADATA_PREFIX_BYTES
          || (header !== null && nameFound && previewComplete)) {
        lines.close();
        input.destroy();
        break;
      }
    }
  } catch {
    return { path: file, valid: false, stable: false };
  }

  let after;
  try {
    after = await stat(file);
  } catch {
    return { path: file, valid: false, stable: false };
  }
  if (!sameVersion(before, after)) {
    return { path: file, valid: false, stable: false };
  }

  const first = firstMessage || fallbackMessage || null;
  return {
    path: file,
    valid: header !== null,
    stable: true,
    cwd: typeof header?.cwd === "string" && header.cwd !== ""
      ? header.cwd
      : null,
    name,
    firstMessage: first,
  };
}

/**
 * Scan a bounded prefix of manifest-listed JSONL files for picker metadata.
 * The first session_info name wins; message counts are not extracted.
 * Files stop once the header, name, and preview are found, or after the
 * 16 KiB prefix budget (one long line may cross it). A row with stable=false
 * must not be cached because the file changed or disappeared during the scan.
 */
export async function scanSessionFiles(files, { concurrency = 8 } = {}) {
  if (!Array.isArray(files) || files.some((file) => typeof file !== "string")) {
    throw new TypeError("files must be an array of paths");
  }
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    throw new RangeError("concurrency must be a positive integer");
  }

  const rows = files.map(() => undefined);
  let next = 0;
  async function worker() {
    for (;;) {
      const index = next++;
      if (index >= files.length) return;
      rows[index] = await scanFile(files[index]);
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(concurrency, files.length) }, worker),
  );
  return rows;
}
