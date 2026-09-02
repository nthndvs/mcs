import { renderMarkdown } from "./markdown";

export interface PdfSection {
  title: string;
  markdown: string;
}

/**
 * Export selected responses to a PDF via the system print dialog
 * ("Save as PDF"). Content is rendered as real text — never images —
 * and the Synthesis section is always placed first when selected.
 */
export function exportPdf(sections: PdfSection[], prompt: string): void {
  const ordered = [...sections].sort((a, b) =>
    a.title === "Synthesis" ? -1 : b.title === "Synthesis" ? 1 : 0
  );
  const body = ordered
    .map(
      (s) => `
      <section>
        <h1>${escapeHtml(s.title)}</h1>
        <div class="content">${renderMarkdown(s.markdown)}</div>
      </section>`
    )
    .join('\n<hr class="break" />\n');

  const html = `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>Model Compare — Export</title>
<style>
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         margin: 48px; color: #111; line-height: 1.55; font-size: 11pt; }
  header.meta { border-bottom: 2px solid #333; margin-bottom: 24px; padding-bottom: 12px; }
  header.meta .prompt { white-space: pre-wrap; color: #333; }
  h1 { font-size: 16pt; margin: 0 0 12px; }
  h2, h3 { margin: 18px 0 8px; }
  table { border-collapse: collapse; width: 100%; margin: 12px 0; }
  th, td { border: 1px solid #999; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #f0f0f0; }
  code { font-family: Consolas, "Courier New", monospace; background: #f4f4f4; padding: 1px 4px; border-radius: 3px; }
  pre { background: #f4f4f4; padding: 12px; border-radius: 6px; overflow-wrap: break-word; white-space: pre-wrap; }
  pre code { background: none; padding: 0; }
  blockquote { border-left: 3px solid #ccc; margin: 8px 0; padding: 4px 12px; color: #444; }
  hr.break { border: none; page-break-after: always; }
  a { color: #1a56db; text-decoration: none; }
</style>
</head>
<body>
<header class="meta">
  <h1>Model Compare Studio</h1>
  <p><strong>Exported:</strong> ${escapeHtml(new Date().toLocaleString())}</p>
  <p class="prompt"><strong>Prompt:</strong> ${escapeHtml(prompt)}</p>
</header>
${body}
</body>
</html>`;

  const win = window.open("", "_blank");
  if (!win) return;
  win.document.write(html);
  win.document.close();
  win.focus();
  setTimeout(() => win.print(), 350);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
