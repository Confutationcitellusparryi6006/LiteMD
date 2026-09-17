import Foundation
import LiteMDDomain

/// Preview 页面模板。
///
/// 安全边界（spec §127）：
/// - 页面 JavaScript 关闭（`allowsContentJavaScript = false`），Markdown 中的脚本不会执行；
/// - CSP 禁止脚本、iframe、表单与远程字体；图片只允许本地资源协议、http(s) 与 data URI；
/// - 下面的脚本以 WKUserScript 注入独立的 content world，不与页面共享全局对象。
enum PreviewTemplate {
    /// 预览要用的字体。与编辑区保持一致：编辑区换了字体，预览跟着换。
    struct Fonts: Equatable, Sendable {
        /// 需要 `@font-face` 的导入字体：族名 + `Fonts/` 目录里的文件名。
        struct Face: Equatable, Sendable {
            let family: String
            let fileName: String
        }

        /// CSS 字体族，nil 表示沿用样式表里的默认值。
        var body: String?
        var heading: String?
        var code: String?
        var faces: [Face] = []

        static let system = Fonts()
    }

    /// 字体样式：先声明导入字体，再覆盖三个字体变量。
    static func fontStylesheet(_ fonts: Fonts) -> String {
        // 导入的字体只在本进程注册，WKWebView 拿不到，必须经由 litemd-resource 再声明一次。
        let faces = fonts.faces.map { face in
            """
            @font-face { font-family: "\(escape(face.family))"; font-display: block; \
            src: url("\(ResourceSchemeHandler.scheme)://\(ResourceSchemeHandler.fontsHost)/\(face.fileName)"); }
            """
        }
        var variables: [String] = []
        if let body = fonts.body { variables.append("--font-body: \(body);") }
        if let heading = fonts.heading { variables.append("--font-heading: \(heading);") }
        if let code = fonts.code { variables.append("--font-mono: \(code);") }

        let root = variables.isEmpty ? "" : ":root { \(variables.joined(separator: " ")) }"
        return (faces + [root]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 字体族名进 CSS 前要转义引号和反斜杠，避免用户的字体名把样式表拆开。
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 主题颜色变量，覆盖样式表中的默认值。
    static func themeStylesheet(_ theme: ColorTheme) -> String {
        func variables(_ colors: ThemeColors) -> String {
            """
            --color-primary: \(colors.accent);
            --color-selection: \(colors.accentSubtle);
            --color-background: \(colors.background);
            --color-text: \(colors.foreground);
            --color-heading: \(colors.heading);
            --color-text-secondary: \(colors.secondary);
            --color-text-tertiary: \(colors.tertiary);
            --color-surface: \(colors.surface);
            --color-border: \(colors.border);
            --color-mark: \(colors.highlight);
            """
        }
        // 预览页面的外观与主题明暗一致，这里只需要一套变量；深色媒体查询中重复一次以覆盖默认样式。
        return """
        :root { color-scheme: \(theme.isDark ? "dark" : "light"); \(variables(theme.colors)) }
        @media (prefers-color-scheme: dark) { :root { \(variables(theme.colors)) } }
        @media (prefers-color-scheme: light) { :root { \(variables(theme.colors)) } }
        """
    }

    static func page(body: String, theme: ColorTheme, fonts: Fonts) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src litemd-asset: https: http: data:; style-src 'unsafe-inline'; font-src litemd-resource:; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="color-scheme" content="light dark">
        <style>\(stylesheet)</style>
        <style id="katex-css">\(PreviewLibraries.katexStylesheet)</style>
        <style id="litemd-theme">\(themeStylesheet(theme))</style>
        <style id="litemd-fonts">\(fontStylesheet(fonts))</style>
        </head>
        <body>
        <article id="content" class="markdown-body">\(body)</article>
        </body>
        </html>
        """
    }

    /// 注入脚本：增量更新 DOM（避免整页闪烁与图片重载）、按源行号滚动。
    static let script = #"""
    (() => {
      const lineAttribute = / data-line="\d+"/g;
      const signature = (node) => node.nodeType === Node.ELEMENT_NODE
        ? node.outerHTML.replace(lineAttribute, '')
        : node.textContent;

      const syncLines = (target, source) => {
        if (target.nodeType !== Node.ELEMENT_NODE) return;
        if (source.hasAttribute('data-line')) target.setAttribute('data-line', source.getAttribute('data-line'));
        const targets = target.querySelectorAll('[data-line]');
        const sources = source.querySelectorAll('[data-line]');
        for (let i = 0; i < targets.length && i < sources.length; i++) {
          targets[i].setAttribute('data-line', sources[i].getAttribute('data-line'));
        }
      };

      // 代码高亮、公式与图表会改写节点内容；增量更新比较的是渲染前的签名。
      const originalSignature = (node) => node.__litemdSignature ?? signature(node);
      const remember = (node) => { node.__litemdSignature = signature(node); };

      const isDark = () => window.matchMedia('(prefers-color-scheme: dark)').matches;
      let mermaidCounter = 0;
      let mermaidTheme = null;

      const enhance = (node) => {
        if (node.nodeType !== Node.ELEMENT_NODE) return;
        if (window.hljs) {
          const blocks = node.matches('pre > code[class*="language-"]') ? [node] : node.querySelectorAll('pre > code[class*="language-"]');
          for (const code of blocks) {
            const language = (code.className.match(/language-([\w+#-]+)/) || [])[1];
            if (language && hljs.getLanguage(language)) {
              try { hljs.highlightElement(code); } catch (_) {}
            }
          }
        }
        if (window.katex) {
          const formulas = node.matches('.math') ? [node] : node.querySelectorAll('.math');
          for (const element of formulas) {
            const tex = element.__litemdTex ?? element.textContent;
            element.__litemdTex = tex;
            try {
              katex.render(tex, element, { displayMode: element.classList.contains('math-display'), throwOnError: false, output: 'htmlAndMathml' });
            } catch (_) {
              element.classList.add('math-error');
            }
          }
        }
        if (window.mermaid) LiteMD.renderMermaid(node);
      };

      window.LiteMD = {
        setTheme(css) {
          const style = document.getElementById('litemd-theme');
          if (style) style.textContent = css;
        },

        setFonts(css) {
          const style = document.getElementById('litemd-fonts');
          if (style) style.textContent = css;
        },

        prepare() {
          const root = document.getElementById('content');
          if (!root) return;
          for (const node of root.childNodes) {
            remember(node);
            enhance(node);
          }
        },

        hasMermaid() {
          return document.querySelector('.mermaid-block') !== null;
        },

        async renderMermaid(scope, force) {
          if (!window.mermaid) return;
          const theme = isDark() ? 'dark' : 'default';
          if (mermaidTheme !== theme) {
            // 图表使用与界面一致的中性色，而不是 Mermaid 默认的紫色。
            const style = getComputedStyle(document.documentElement);
            const token = (name) => style.getPropertyValue(name).trim();
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'strict',
              theme: 'base',
              fontFamily: getComputedStyle(document.body).fontFamily,
              themeVariables: {
                darkMode: theme === 'dark',
                background: token('--color-background'),
                primaryColor: token('--color-surface'),
                primaryBorderColor: token('--color-border'),
                primaryTextColor: token('--color-text'),
                secondaryColor: token('--color-background'),
                tertiaryColor: token('--color-surface'),
                lineColor: token('--color-text-secondary'),
                textColor: token('--color-text'),
                noteBkgColor: token('--color-mark'),
                noteTextColor: token('--color-text'),
              },
            });
            mermaidTheme = theme;
          }
          const root = scope ?? document;
          const blocks = root.matches?.('.mermaid-block') ? [root] : root.querySelectorAll('.mermaid-block');
          for (const block of blocks) {
            if (block.__litemdRendered === theme && !force) continue;
            const source = block.__litemdSource ?? block.textContent;
            block.__litemdSource = source;
            block.__litemdRendered = theme;
            const id = 'litemd-mermaid-' + (++mermaidCounter);
            try {
              const { svg } = await mermaid.render(id, source);
              block.innerHTML = svg;
              block.classList.remove('mermaid-error');
            } catch (error) {
              block.classList.add('mermaid-error');
              const pre = document.createElement('pre');
              pre.className = 'mermaid-source';
              pre.textContent = source;
              const message = document.createElement('div');
              message.className = 'mermaid-message';
              message.textContent = String(error && error.message ? error.message : error).split('\n')[0];
              block.replaceChildren(message, pre);
            } finally {
              // 清理 Mermaid 渲染时临时插入 body 的节点；生成的 SVG 自身也使用该 id，保留在图表块内的不删除。
              document.getElementById('d' + id)?.remove();
              const leftover = document.getElementById(id);
              if (leftover && !leftover.closest('.mermaid-block')) leftover.remove();
            }
          }
        },

        update(html) {
          const root = document.getElementById('content');
          if (!root) return;
          const next = document.createElement('div');
          next.innerHTML = html;
          const oldNodes = Array.from(root.childNodes);
          const newNodes = Array.from(next.childNodes);

          let start = 0;
          while (start < oldNodes.length && start < newNodes.length && originalSignature(oldNodes[start]) === signature(newNodes[start])) {
            syncLines(oldNodes[start], newNodes[start]);
            start++;
          }
          let oldEnd = oldNodes.length - 1;
          let newEnd = newNodes.length - 1;
          while (oldEnd >= start && newEnd >= start && originalSignature(oldNodes[oldEnd]) === signature(newNodes[newEnd])) {
            syncLines(oldNodes[oldEnd], newNodes[newEnd]);
            oldEnd--;
            newEnd--;
          }

          const anchor = oldEnd + 1 < oldNodes.length ? oldNodes[oldEnd + 1] : null;
          for (let i = start; i <= oldEnd; i++) root.removeChild(oldNodes[i]);
          for (let i = start; i <= newEnd; i++) {
            remember(newNodes[i]);
            root.insertBefore(newNodes[i], anchor);
            enhance(newNodes[i]);
          }
        },

        scrollToLine(line) {
          const blocks = document.querySelectorAll('[data-line]');
          if (blocks.length === 0) return;
          const top = (element) => element.getBoundingClientRect().top + window.scrollY;
          let previous = null;
          let next = null;
          for (const element of blocks) {
            const value = Number(element.getAttribute('data-line'));
            if (value <= line) {
              previous = { element, value };
            } else {
              next = { element, value };
              break;
            }
          }
          let y = 0;
          if (previous && next && next.value > previous.value) {
            const ratio = (line - previous.value) / (next.value - previous.value);
            y = top(previous.element) + (top(next.element) - top(previous.element)) * ratio;
          } else if (previous) {
            const rect = previous.element.getBoundingClientRect();
            y = top(previous.element) + Math.min(rect.height, (line - previous.value) * 24);
          }
          window.scrollTo(0, Math.max(0, y - 16));
        }
      };

      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => LiteMD.renderMermaid(document, true));
      LiteMD.prepare();
    })();
    """#

    /// 预览样式。使用与界面一致的 token：4px 间距、12/14/16/20/24/32 字号阶梯。
    static let stylesheet = """
    :root {
      --color-primary: #2563eb;
      --color-secondary: #475569;
      --color-neutral-50: #f8f9fa;
      --color-neutral-100: #f3f4f6;
      --color-neutral-200: #e5e7eb;
      --color-neutral-400: #9ca3af;
      --color-neutral-500: #6b7280;
      --color-neutral-900: #111827;
      --color-success: #16a34a;
      --color-warning: #d97706;
      --color-error: #dc2626;

      --color-background: #ffffff;
      --color-text: var(--color-neutral-900);
      --color-text-secondary: var(--color-neutral-500);
      --color-text-tertiary: var(--color-neutral-400);
      --color-surface: var(--color-neutral-100);
      --color-border: var(--color-neutral-200);
      --color-mark: #fef3c7;
      --color-selection: #dbeafe;
      --scrollbar-thumb: rgba(0, 0, 0, 0.22);
      --scrollbar-thumb-hover: rgba(0, 0, 0, 0.38);

      --text-xs: 12px;
      --text-sm: 14px;
      --text-base: 16px;
      --text-lg: 20px;
      --text-xl: 24px;
      --text-2xl: 32px;

      --space-1: 4px;
      --space-2: 8px;
      --space-3: 12px;
      --space-4: 16px;
      --space-6: 24px;
      --space-8: 32px;
      --space-12: 48px;
      --space-16: 64px;

      --radius: 8px;
      --radius-sm: calc(var(--radius) / 2);

      --content-width: 800px;
      --font-body: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", sans-serif;
      --font-mono: ui-monospace, "SF Mono", Menlo, monospace;
      --font-heading: var(--font-body);
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --color-primary: #60a5fa;
        --color-background: #111827;
        --color-text: #e5e7eb;
        --color-text-secondary: #9ca3af;
        --color-text-tertiary: #6b7280;
        --color-surface: #1f2937;
        --color-border: #374151;
        --color-mark: #78350f;
        --scrollbar-thumb: rgba(255, 255, 255, 0.28);
        --scrollbar-thumb-hover: rgba(255, 255, 255, 0.45);
      }
    }

    html {
      background: var(--color-background);
      scrollbar-width: thin;
      scrollbar-color: var(--scrollbar-thumb) transparent;
    }

    /* 细滚动条：透明轨道、圆角滑块，与编辑器一致。滑块不受界面圆角 token 约束。 */
    ::-webkit-scrollbar { width: var(--space-3); height: var(--space-3); background: transparent; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb {
      background-color: var(--scrollbar-thumb);
      background-clip: content-box;
      border: calc(var(--space-3) / 4) solid transparent;
      border-radius: 999px;
    }
    ::-webkit-scrollbar-thumb:hover { background-color: var(--scrollbar-thumb-hover); border-width: calc(var(--space-1) / 2); }

    body {
      margin: 0;
      padding: var(--space-8) var(--space-6) var(--space-16);
      background: var(--color-background);
      color: var(--color-text);
      font-family: var(--font-body);
      font-size: var(--text-base);
      font-weight: 400;
      line-height: 1.5;
      -webkit-font-smoothing: antialiased;
      word-wrap: break-word;
    }

    .markdown-body { max-width: var(--content-width); margin: 0 auto; }
    .markdown-body > :first-child { margin-top: 0; }

    h1, h2, h3, h4, h5, h6 {
      color: var(--color-heading, var(--color-text));
      font-family: var(--font-heading);
      font-weight: 600;
      line-height: 1.25;
      margin: var(--space-6) 0 var(--space-3);
    }
    h1 { font-size: var(--text-2xl); padding-bottom: var(--space-2); border-bottom: 1px solid var(--color-border); }
    h2 { font-size: var(--text-xl); padding-bottom: var(--space-2); border-bottom: 1px solid var(--color-border); }
    h3 { font-size: var(--text-lg); }
    h4 { font-size: var(--text-base); }
    h5 { font-size: var(--text-sm); }
    h6 { font-size: var(--text-xs); color: var(--color-text-secondary); }

    p, ul, ol, blockquote, pre, table, .table-wrapper, hr { margin: 0 0 var(--space-4); }

    ::selection { background: var(--color-selection); }
    input[type="checkbox"] { accent-color: var(--color-primary); }

    a { color: var(--color-primary); text-decoration: none; }
    a:hover { text-decoration: underline; }

    strong { font-weight: 600; }
    del { color: var(--color-text-secondary); }
    mark { background: var(--color-mark); color: inherit; }

    ul, ol { padding-left: var(--space-8); }
    li + li { margin-top: var(--space-1); }
    li > p { margin: 0; }
    li > ul, li > ol { margin: var(--space-1) 0 0; }
    ul.contains-task-list { padding-left: var(--space-6); }
    .task-list-item { list-style: none; }
    .task-list-item input { margin: 0 var(--space-2) 0 calc(-1 * var(--space-6)); vertical-align: middle; }
    .task-list-item.checked { color: var(--color-text-secondary); }

    blockquote {
      padding: 0 var(--space-4);
      color: var(--color-text-secondary);
      border-left: var(--space-1) solid var(--color-border);
    }
    blockquote > :last-child { margin-bottom: 0; }

    code {
      font-family: var(--font-mono);
      font-size: var(--text-sm);
      padding: 0 var(--space-1);
      background: var(--color-surface);
      border-radius: var(--radius-sm);
    }

    pre {
      padding: var(--space-4);
      overflow-x: auto;
      background: var(--color-surface);
      border-radius: var(--radius);
      line-height: 1.5;
    }
    pre code { padding: 0; background: transparent; border-radius: 0; font-size: var(--text-sm); }
    pre.front-matter { color: var(--color-text-secondary); border: 1px solid var(--color-border); background: transparent; }

    hr { height: 1px; border: 0; background: var(--color-border); margin: var(--space-6) 0; }

    img { max-width: 100%; height: auto; border-radius: var(--radius-sm); }

    .table-wrapper { overflow-x: auto; }
    table { border-collapse: collapse; margin: 0; font-size: var(--text-sm); }
    th, td { padding: var(--space-2) var(--space-3); border: 1px solid var(--color-border); }
    th { font-weight: 600; background: var(--color-surface); }

    kbd {
      font-family: var(--font-mono);
      font-size: var(--text-xs);
      padding: 0 var(--space-1);
      border: 1px solid var(--color-border);
      border-radius: var(--radius-sm);
    }

    details { margin: 0 0 var(--space-4); }
    summary { cursor: pointer; }

    a.wikilink { border-bottom: 1px dashed currentColor; }
    a.wikilink:hover { text-decoration: none; border-bottom-style: solid; }
    img.wikilink-embed { display: block; }

    /* 公式：独立公式居中，过宽时横向滚动 */
    .math-display { display: block; margin: 0 0 var(--space-4); overflow-x: auto; overflow-y: hidden; text-align: center; }
    div.math-display { white-space: pre-wrap; }
    .katex { font-size: 1.1em; }
    .katex-display { margin: 0; }
    .math-error { color: var(--color-error); font-family: var(--font-mono); font-size: var(--text-sm); }

    /* Mermaid 图表 */
    .mermaid-block { margin: 0 0 var(--space-4); overflow-x: auto; text-align: center; }
    .mermaid-block svg { max-width: 100%; height: auto; }
    .mermaid-block > .mermaid-source { text-align: left; }
    .mermaid-message { color: var(--color-error); font-size: var(--text-xs); text-align: left; margin-bottom: var(--space-2); }

    /* 代码高亮：使用主题变量，浅色与深色各一套 */
    :root {
      --code-keyword: #cf222e; --code-string: #0a3069; --code-comment: #6e7781; --code-number: #0550ae;
      --code-title: #8250df; --code-type: #953800; --code-attr: #0550ae; --code-meta: #6e7781;
      --code-addition-bg: #dafbe1; --code-deletion-bg: #ffebe9;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --code-keyword: #ff7b72; --code-string: #a5d6ff; --code-comment: #8b949e; --code-number: #79c0ff;
        --code-title: #d2a8ff; --code-type: #ffa657; --code-attr: #79c0ff; --code-meta: #8b949e;
        --code-addition-bg: #033a16; --code-deletion-bg: #67060c;
      }
    }
    .hljs-keyword, .hljs-selector-tag, .hljs-doctag, .hljs-template-tag, .hljs-template-variable, .hljs-variable.language_ { color: var(--code-keyword); }
    .hljs-string, .hljs-regexp, .hljs-meta .hljs-string, .hljs-selector-attr, .hljs-selector-pseudo { color: var(--code-string); }
    .hljs-comment, .hljs-quote { color: var(--code-comment); font-style: italic; }
    .hljs-number, .hljs-literal, .hljs-symbol, .hljs-bullet, .hljs-attr, .hljs-attribute, .hljs-selector-id, .hljs-selector-class { color: var(--code-number); }
    .hljs-title, .hljs-title.function_, .hljs-title.class_, .hljs-section { color: var(--code-title); }
    .hljs-type, .hljs-built_in, .hljs-name, .hljs-tag, .hljs-params { color: var(--code-type); }
    .hljs-meta, .hljs-meta .hljs-keyword { color: var(--code-meta); }
    .hljs-addition { background: var(--code-addition-bg); }
    .hljs-deletion { background: var(--code-deletion-bg); }
    .hljs-emphasis { font-style: italic; }
    .hljs-strong { font-weight: 600; }
    """
}
