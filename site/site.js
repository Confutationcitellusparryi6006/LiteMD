/* LiteMD 官网：语言切换、深浅色切换、主题挑选器。
   主题取值与应用内 ColorTheme（LiteMDDomain/Settings/Themes.swift）保持一致。 */

(function () {
  "use strict";

  var THEMES = [
    { id: "paper",          en: "Paper",           zh: "纸白",   dark: false, bg: "#FFFFFF", fg: "#1F2937", heading: "#111827", secondary: "#6B7280", tertiary: "#9CA3AF", surface: "#F3F4F6", border: "#E5E7EB", accent: "#2563EB", accentSubtle: "#DBEAFE", highlight: "#FEF3C7", sidebar: "#F5F5F7" },
    { id: "redGraphite",    en: "Red Graphite",    zh: "石墨红", dark: false, bg: "#FFFFFF", fg: "#333333", heading: "#222222", secondary: "#6E6E73", tertiary: "#A1A1A6", surface: "#F5F5F7", border: "#E5E5EA", accent: "#D0423B", accentSubtle: "#FBE3E1", highlight: "#FFF1B8", sidebar: "#2C2C2E" },
    { id: "blueGraphite",   en: "Blue Graphite",   zh: "石墨蓝", dark: false, bg: "#F9F9FA", fg: "#2E2E33", heading: "#1C1C1E", secondary: "#6E6E73", tertiary: "#A1A1A6", surface: "#EFEFF2", border: "#E3E3E8", accent: "#2871C3", accentSubtle: "#DCEBFA", highlight: "#FFF1B8", sidebar: "#2C2C2E" },
    { id: "forest",         en: "Forest",          zh: "森林",   dark: false, bg: "#FFFFFF", fg: "#1F2A24", heading: "#14532D", secondary: "#5F6B63", tertiary: "#9AA59E", surface: "#F1F5F2", border: "#DFE7E1", accent: "#12853C", accentSubtle: "#DCFCE7", highlight: "#FEF9C3", sidebar: "#F1F5F2" },
    { id: "solarizedLight", en: "Solarized Light", zh: "暖阳",   dark: false, bg: "#FDF6E3", fg: "#586E75", heading: "#073642", secondary: "#657B83", tertiary: "#93A1A1", surface: "#EEE8D5", border: "#E4DCC5", accent: "#8D6A00", accentSubtle: "#F4E7BD", highlight: "#F6E3A1", sidebar: "#EEE8D5" },
    { id: "glacier",        en: "Glacier",         zh: "冰川",   dark: false, bg: "#F7F9FC", fg: "#3B4252", heading: "#2E3440", secondary: "#4C566A", tertiary: "#8A93A6", surface: "#ECEFF4", border: "#DCE2EA", accent: "#527197", accentSubtle: "#DDE6F1", highlight: "#F4E6C3", sidebar: "#E5E9F0" },
    { id: "sepia",          en: "Sepia",           zh: "旧书",   dark: false, bg: "#F8F4EC", fg: "#433422", heading: "#2F2415", secondary: "#6F5E48", tertiary: "#A39480", surface: "#EFE8DB", border: "#E2D8C6", accent: "#1E4E8C", accentSubtle: "#DCE5F0", highlight: "#F3E2A9", sidebar: "#EFE8DB" },
    { id: "roseDawn",       en: "Rosé Dawn",       zh: "晨曦",   dark: false, bg: "#FAF4ED", fg: "#575279", heading: "#286983", secondary: "#797593", tertiary: "#9893A5", surface: "#F2E9E1", border: "#E6DCD3", accent: "#9A5D5A", accentSubtle: "#F5E0DD", highlight: "#F6E2B8", sidebar: "#FFFAF3" },
    { id: "latte",          en: "Latte",           zh: "拿铁",   dark: false, bg: "#EFF1F5", fg: "#4C4F69", heading: "#12777D", secondary: "#5C5F77", tertiary: "#8C8FA1", surface: "#E6E9EF", border: "#DCE0E8", accent: "#8839EF", accentSubtle: "#E6DAFC", highlight: "#F7E6B5", sidebar: "#E6E9EF" },
    { id: "wheat",          en: "Wheat",           zh: "麦田",   dark: false, bg: "#FBF1C7", fg: "#3C3836", heading: "#746F0D", secondary: "#665C54", tertiary: "#928374", surface: "#F2E5BC", border: "#E5D5A6", accent: "#3F7654", accentSubtle: "#DDE8C8", highlight: "#F5D98B", sidebar: "#F2E5BC" },
    { id: "charcoal",       en: "Charcoal",        zh: "木炭",   dark: true,  bg: "#1E1F22", fg: "#D4D4D8", heading: "#F4F4F5", secondary: "#A1A1AA", tertiary: "#71717A", surface: "#2A2B2F", border: "#38393E", accent: "#60A5FA", accentSubtle: "#1E3A5F", highlight: "#5C4813", sidebar: "#18191B" },
    { id: "midnight",       en: "Midnight",        zh: "午夜",   dark: true,  bg: "#000000", fg: "#E5E5E5", heading: "#FFD60A", secondary: "#A3A3A3", tertiary: "#737373", surface: "#141414", border: "#262626", accent: "#FF9F0A", accentSubtle: "#3D2A05", highlight: "#4D3B00", sidebar: "#0A0A0A" },
    { id: "solarizedDark",  en: "Solarized Dark",  zh: "深海",   dark: true,  bg: "#002B36", fg: "#93A1A1", heading: "#EEE8D5", secondary: "#839496", tertiary: "#586E75", surface: "#073642", border: "#0E4452", accent: "#2AA198", accentSubtle: "#0B4A4A", highlight: "#594A0B", sidebar: "#00212B" },
    { id: "dracula",        en: "Dracula",         zh: "德古拉", dark: true,  bg: "#282A36", fg: "#F8F8F2", heading: "#50FA7B", secondary: "#C5C8D6", tertiary: "#6272A4", surface: "#343746", border: "#44475A", accent: "#8BE9FD", accentSubtle: "#2F4A5A", highlight: "#5A4E1E", sidebar: "#21222C" },
    { id: "nord",           en: "Nord",            zh: "北境",   dark: true,  bg: "#2E3440", fg: "#D8DEE9", heading: "#ECEFF4", secondary: "#B3BBC8", tertiary: "#7B8394", surface: "#3B4252", border: "#434C5E", accent: "#A3BE8C", accentSubtle: "#3F4B3A", highlight: "#5E5335", sidebar: "#272C36" },
    { id: "cobalt",         en: "Cobalt",          zh: "钴蓝",   dark: true,  bg: "#193549", fg: "#E1EFFF", heading: "#FFC600", secondary: "#A9C1D9", tertiary: "#6A8BA8", surface: "#1F4662", border: "#234E6D", accent: "#3AD29F", accentSubtle: "#1E5249", highlight: "#6B5A12", sidebar: "#15232D" },
    { id: "tokyoNight",     en: "Tokyo Night",     zh: "东京夜", dark: true,  bg: "#1A1B26", fg: "#A9B1D6", heading: "#7AA2F7", secondary: "#8C93B8", tertiary: "#565F89", surface: "#24283B", border: "#292E42", accent: "#BB9AF7", accentSubtle: "#3A3155", highlight: "#4E4323", sidebar: "#16161E" },
    { id: "oneDark",        en: "One Dark",        zh: "原子",   dark: true,  bg: "#282C34", fg: "#ABB2BF", heading: "#E5C07B", secondary: "#9DA5B4", tertiary: "#5C6370", surface: "#2F343D", border: "#3A3F4B", accent: "#61AFEF", accentSubtle: "#23405A", highlight: "#5A4B24", sidebar: "#21252B" },
    { id: "mocha",          en: "Mocha",           zh: "摩卡",   dark: true,  bg: "#1E1E2E", fg: "#CDD6F4", heading: "#94E2D5", secondary: "#A6ADC8", tertiary: "#6C7086", surface: "#313244", border: "#45475A", accent: "#CBA6F7", accentSubtle: "#45386A", highlight: "#5B4F2E", sidebar: "#181825" },
    { id: "rosePine",       en: "Rosé Pine",       zh: "松影",   dark: true,  bg: "#191724", fg: "#E0DEF4", heading: "#C4A7E7", secondary: "#908CAA", tertiary: "#6E6A86", surface: "#1F1D2E", border: "#26233A", accent: "#EBBCBA", accentSubtle: "#4A3A45", highlight: "#5A4A2A", sidebar: "#13111E" }
  ];

  var store = {
    get: function (key) {
      try { return window.localStorage.getItem(key); } catch (e) { return null; }
    },
    set: function (key, value) {
      try { window.localStorage.setItem(key, value); } catch (e) { /* 隐私模式下忽略 */ }
    }
  };

  var root = document.documentElement;
  var darkQuery = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function isDark() {
    var forced = root.getAttribute("data-theme");
    if (forced === "dark") return true;
    if (forced === "light") return false;
    return !!(darkQuery && darkQuery.matches);
  }

  /* 首屏截图跟着界面语言和明暗走：应用本身也是中英双语的。 */
  function updateHeroShot() {
    var shot = document.getElementById("heroShot");
    if (!shot) return;
    var zh = root.getAttribute("data-ui-lang") === "zh";
    var name = "app-" + (isDark() ? "dark" : "light") + (zh ? "" : "-en") + ".png";
    var next = "assets/" + name;
    if (shot.getAttribute("src") !== next) shot.setAttribute("src", next);
    shot.alt = zh
      ? "LiteMD 主窗口：左侧是文件夹目录树，右侧是实时预览的编辑区"
      : "The LiteMD main window: a folder tree on the left, the live-preview editor on the right";
  }

  /* ---------- 界面语言 ---------- */

  function applyLanguage(lang) {
    root.setAttribute("data-ui-lang", lang);
    root.setAttribute("lang", lang === "zh" ? "zh-Hans" : "en");
    var label = document.getElementById("langLabel");
    if (label) label.textContent = lang === "zh" ? "EN" : "中文";
    updateHeroShot();
  }

  var savedLang = store.get("litemd-lang");
  var initialLang = savedLang || (/^zh/i.test(navigator.language || "") ? "zh" : "en");
  applyLanguage(initialLang);

  var langToggle = document.getElementById("langToggle");
  if (langToggle) {
    langToggle.addEventListener("click", function () {
      var next = root.getAttribute("data-ui-lang") === "zh" ? "en" : "zh";
      applyLanguage(next);
      store.set("litemd-lang", next);
      renderThemeCaption();
    });
  }

  /* ---------- 深浅色 ---------- */

  var savedTheme = store.get("litemd-appearance");
  if (savedTheme === "dark" || savedTheme === "light") {
    root.setAttribute("data-theme", savedTheme);
  }

  var themeToggle = document.getElementById("themeToggle");
  if (themeToggle) {
    themeToggle.addEventListener("click", function () {
      var next = isDark() ? "light" : "dark";
      root.setAttribute("data-theme", next);
      store.set("litemd-appearance", next);
      updateHeroShot();
    });
  }

  if (darkQuery && darkQuery.addEventListener) {
    darkQuery.addEventListener("change", updateHeroShot);
  }

  /* ---------- 主题挑选器 ---------- */

  var list = document.getElementById("themeList");
  var preview = document.getElementById("themePreview");
  var nameEl = document.getElementById("themeName");
  var metaEl = document.getElementById("themeMeta");
  var current = THEMES[0];

  function luminance(hex) {
    var n = parseInt(hex.slice(1), 16);
    var r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  }

  function renderThemeCaption() {
    if (!nameEl || !metaEl) return;
    var zh = root.getAttribute("data-ui-lang") === "zh";
    nameEl.textContent = zh ? current.zh : current.en;
    metaEl.textContent = zh
      ? current.en + " · " + (current.dark ? "深色" : "浅色")
      : current.zh + " · " + (current.dark ? "Dark" : "Light");
  }

  function applyTheme(theme) {
    current = theme;
    if (preview) {
      var sidebarIsDark = luminance(theme.sidebar) < 0.5;
      preview.style.setProperty("--tp-bg", theme.bg);
      preview.style.setProperty("--tp-fg", theme.fg);
      preview.style.setProperty("--tp-heading", theme.heading);
      preview.style.setProperty("--tp-secondary", theme.secondary);
      preview.style.setProperty("--tp-tertiary", theme.tertiary);
      preview.style.setProperty("--tp-surface", theme.surface);
      preview.style.setProperty("--tp-border", theme.border);
      preview.style.setProperty("--tp-accent", theme.accent);
      preview.style.setProperty("--tp-highlight", theme.highlight);
      preview.style.setProperty("--tp-sidebar", theme.sidebar);
      preview.style.setProperty("--tp-sidebar-text", sidebarIsDark ? "#E5E5EA" : theme.fg);
      preview.style.setProperty("--tp-sidebar-active", sidebarIsDark ? "rgba(255,255,255,0.14)" : theme.accentSubtle);
    }
    if (list) {
      var buttons = list.querySelectorAll(".swatch");
      for (var i = 0; i < buttons.length; i++) {
        buttons[i].setAttribute("aria-checked", String(buttons[i].dataset.theme === theme.id));
        buttons[i].tabIndex = buttons[i].dataset.theme === theme.id ? 0 : -1;
      }
    }
    renderThemeCaption();
  }

  if (list) {
    THEMES.forEach(function (theme) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "swatch";
      button.dataset.theme = theme.id;
      button.setAttribute("role", "radio");
      button.setAttribute("aria-checked", "false");
      button.tabIndex = -1;

      var chip = document.createElement("span");
      chip.className = "swatch-chip";
      chip.setAttribute("aria-hidden", "true");
      [["s-side", theme.sidebar], ["s-body", theme.bg], ["s-accent", theme.accent]].forEach(function (pair) {
        var part = document.createElement("i");
        part.className = pair[0];
        part.style.background = pair[1];
        chip.appendChild(part);
      });

      var label = document.createElement("span");
      var zhSpan = document.createElement("span");
      zhSpan.setAttribute("lang", "zh");
      zhSpan.textContent = theme.zh;
      var enSpan = document.createElement("span");
      enSpan.setAttribute("lang", "en");
      enSpan.textContent = theme.en;
      label.appendChild(zhSpan);
      label.appendChild(enSpan);

      button.appendChild(chip);
      button.appendChild(label);
      button.addEventListener("click", function () { applyTheme(theme); });
      list.appendChild(button);
    });

    list.addEventListener("keydown", function (event) {
      var keys = ["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"];
      if (keys.indexOf(event.key) === -1) return;
      event.preventDefault();
      var index = THEMES.indexOf(current);
      var step = (event.key === "ArrowRight" || event.key === "ArrowDown") ? 1 : -1;
      var next = THEMES[(index + step + THEMES.length) % THEMES.length];
      applyTheme(next);
      var button = list.querySelector('[data-theme="' + next.id + '"]');
      if (button) button.focus();
    });
  }

  /* 默认展示与页面明暗一致的那套：浅色给「纸白」，深色给「木炭」。 */
  applyTheme(isDark() ? THEMES[10] : THEMES[0]);
  updateHeroShot();
})();
