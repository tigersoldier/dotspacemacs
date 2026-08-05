// render.cjs — markdown-it renderer replicating VS Code's markdown engine.
// Reads Markdown from stdin, writes an HTML *fragment* to stdout.
//
// Replicates extensions/markdown-language-features/src/markdownEngine.ts:
//   - markdown-it with html, linkify, typographer, breaks
//   - highlight.js for fenced code blocks (highlighted at render time)
//   - data-line / code-line source-map plugin (block-level line attrs)
//   - heading_open id slugs
//   - hljs class on fenced code blocks
//   - VS Code's normalizeHighlightLang quirks (shell->sh, tsx->jsx, c#->cs, ...)
//
// Requires the Node packages `markdown-it` and `highlight.js` to be resolvable
// (e.g. installed globally and NODE_PATH pointed at the global node_modules).

const MarkdownIt = require('markdown-it');
const hljs = require('highlight.js');

function normalizeHighlightLang(lang) {
  switch ((lang || '').toLowerCase()) {
    case 'shell':      return 'sh';
    case 'py3':        return 'python';
    case 'tsx':
    case 'typescriptreact':
      return 'jsx';
    case 'json5':
    case 'jsonc':      return 'json';
    case 'c#':
    case 'csharp':     return 'cs';
    default:           return lang;
  }
}

function getMarkdownOptions() {
  // We do NOT use markdown-it's `highlight` option; `addFencedRenderer`
  // below replaces the `fence` rule and does the highlighting itself so the
  // output carries an `hljs` class on <pre> (matches VS Code's CSS selectors).
  return {
    html: true,
    linkify: true,
    typographer: true,
    breaks: false,
  };
}

// VS Code's pluginSourceMap: tag every block token with data-line + code-line + dir=auto.
function pluginSourceMap(md) {
  md.core.ruler.push('source_map_data_attribute', (state) => {
    for (const token of state.tokens) {
      if (token.map && token.type !== 'inline') {
        token.attrSet('data-line', String(token.map[0]));
        token.attrJoin('class', 'code-line');
        token.attrJoin('dir', 'auto');
      }
    }
  });
  const originalHtmlBlock = md.renderer.rules['html_block'];
  if (originalHtmlBlock) {
    md.renderer.rules['html_block'] = (tokens, idx, options, env, self) =>
      `<div ${self.renderAttrs(tokens[idx])} ></div>\n` +
      originalHtmlBlock(tokens, idx, options, env, self);
  }
}

// GitHub-ish slugifier (VS Code uses its own SlugBuilder; close approximation).
function slugify(text) {
  return String(text)
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-');
}

function tokenToPlainText(token) {
  if (token.children) return token.children.map(tokenToPlainText).join('');
  switch (token.type) {
    case 'text':
    case 'emoji':
    case 'code_inline':
      return token.content;
    default:
      return '';
  }
}

function addNamedHeaders(md) {
  const original = md.renderer.rules.heading_open;
  const seen = new Map();
  md.renderer.rules.heading_open = (tokens, idx, options, env, self) => {
    const title = tokenToPlainText(tokens[idx + 1]);
    let slug = slugify(title);
    const count = seen.get(slug) || 0;
    seen.set(slug, count + 1);
    if (count > 0) slug = `${slug}-${count}`;
    tokens[idx].attrSet('id', slug);
    return original ? original(tokens, idx, options, env, self)
                    : self.renderToken(tokens, idx, options);
  };
}

// Emit `<pre class="hljs language-X"><code>...</code></pre>` (VS Code's shape).
function addFencedRenderer(md) {
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const info = token.info ? md.utils.unescapeAll(token.info).trim() : '';
    const langName = info ? info.split(/\s+/g)[0] : '';
    const normalized = normalizeHighlightLang(langName);
    let highlighted = '';
    if (normalized && hljs.getLanguage(normalized)) {
      try {
        highlighted = hljs.highlight(token.content, { language: normalized, ignoreIllegals: true }).value;
      } catch (e) { /* fall through to escaped */ }
    }
    const codeContent = highlighted || md.utils.escapeHtml(token.content);
    const langClass = langName ? ` language-${md.utils.escapeHtml(langName)}` : '';
    const extraClasses = (token.attrGet('class') || '');
    const classes = `hljs${langClass}${extraClasses ? ' ' + extraClasses : ''}`;
    token.attrSet('class', classes);
    const attrs = self.renderAttrs(token);
    return `<pre${attrs}><code>${codeContent}</code></pre>\n`;
  };
}

const md = new MarkdownIt(getMarkdownOptions());
md.linkify.set({ fuzzyLink: false });
pluginSourceMap(md);
addNamedHeaders(md);
addFencedRenderer(md);

// Read all of stdin, render the fragment to stdout.
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => { input += chunk; });
process.stdin.on('end', () => {
  process.stdout.write(md.render(input));
});
