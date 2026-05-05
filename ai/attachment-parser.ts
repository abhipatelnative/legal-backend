// Server-side parser for files uploaded into the Global AI Chat.
// Text/PDF/DOCX are parsed to plain text; images are passed through as base64.
// Anything else is marked "skipped" — the caller may still keep the file but
// the prompt will note that no text was extracted.

// pdf-parse and mammoth ship as CommonJS — using require keeps them out of the
// type-checked import graph (their .d.ts versions lag behind reality).
// eslint-disable-next-line @typescript-eslint/no-var-requires
const pdfParse: (buffer: Buffer) => Promise<{ text: string; numpages: number }> = require("pdf-parse");
// eslint-disable-next-line @typescript-eslint/no-var-requires
const mammoth: { extractRawText: (input: { buffer: Buffer }) => Promise<{ value: string }> } = require("mammoth");

export type AttachmentKind = "text" | "pdf" | "docx" | "image" | "other";
export type AttachmentParseStatus = "done" | "failed" | "skipped";

export interface ParsedAttachment {
  kind: AttachmentKind;
  status: AttachmentParseStatus;
  text?: string;
  pageCount?: number;
  error?: string;
}

const TEXT_MIME_PREFIXES = ["text/", "application/json", "application/xml", "application/x-ndjson"];
const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

export function detectKind(mimeType: string): AttachmentKind {
  const mime = mimeType.toLowerCase();
  if (mime.startsWith("image/")) return "image";
  if (mime === "application/pdf") return "pdf";
  if (mime === DOCX_MIME) return "docx";
  if (TEXT_MIME_PREFIXES.some((p) => mime.startsWith(p))) return "text";
  return "other";
}

export async function parseAttachment(buffer: Buffer, mimeType: string): Promise<ParsedAttachment> {
  const kind = detectKind(mimeType);

  if (kind === "image") {
    return { kind, status: "skipped" };
  }

  if (kind === "text") {
    try {
      return { kind, status: "done", text: buffer.toString("utf8") };
    } catch (error: any) {
      return { kind, status: "failed", error: error?.message || "Failed to decode text." };
    }
  }

  if (kind === "pdf") {
    try {
      const result = await pdfParse(buffer);
      return {
        kind,
        status: "done",
        text: (result.text || "").trim(),
        pageCount: result.numpages,
      };
    } catch (error: any) {
      return { kind, status: "failed", error: error?.message || "PDF extraction failed." };
    }
  }

  if (kind === "docx") {
    try {
      const result = await mammoth.extractRawText({ buffer });
      return { kind, status: "done", text: (result.value || "").trim() };
    } catch (error: any) {
      return { kind, status: "failed", error: error?.message || "DOCX extraction failed." };
    }
  }

  return { kind: "other", status: "skipped" };
}
