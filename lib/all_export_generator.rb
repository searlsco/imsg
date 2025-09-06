require 'json'
require 'cgi'

class AllExportGenerator
  def initialize(manifest)
    @manifest = manifest
  end

  def write(outdir)
    File.write(File.join(outdir, 'index.html'), html)
    File.write(File.join(outdir, 'app.js'), js)
    File.write(File.join(outdir, 'styles.css'), css)
    File.write(File.join(outdir, 'manifest.json'), JSON.pretty_generate(@manifest))
  end

  def html
    <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Messages Export</title>
      <link rel="stylesheet" href="styles.css" />
    </head>
    <body>
      <div class="app">
        <!-- Mobile hamburger button (shown on narrow viewports) -->
        <button id="menu-toggle" class="hamburger" aria-label="Open chat list" title="Open chat list">☰</button>

        <aside class="sidebar" aria-label="Conversations">
          <ul id="chat-list" class="chat-list">
            <!-- Progressive enhancement: list of links for no-JS -->
            #{server_side_list_items}
          </ul>
          <!-- Moved filter to bottom to align visually with per-thread search -->
          <div class="search bottom">
            <div class="input-wrap">
              <input id="filter" placeholder="Filter chats" aria-label="Filter chats" />
              <button id="clear-filter" class="clear-btn" aria-label="Clear filter" title="Clear">×</button>
            </div>
          </div>
        </aside>
        <main class="viewer" aria-label="Conversation viewer">
          <iframe id="viewer" name="viewer" title="Conversation" src="#{@manifest.first && @manifest.first['path']}" tabindex="0"></iframe>
        </main>
        <div id="backdrop" class="backdrop" hidden></div>
      </div>
      <script src="app.js?v=#{Time.now.to_i}"></script>
    </body>
    </html>
    HTML
  end

  def server_side_list_items
    @manifest.map { |m|
      initials = initials_for(m['name'])
      avatar = m['avatar']
      preview = h(m['preview'] || '')
      full_name = m['full_name'] && !m['full_name'].to_s.empty? ? m['full_name'] : m['name']
      last_date = m['last_date'] || ''
      %(<li data-name="#{h(full_name)}" data-last="#{h(m['last'])}" data-id="#{h(m['id'])}" tabindex="0">
          <div class="avatar" data-initial="#{h(initials)}">#{avatar ? %(<img src="#{h(avatar)}" alt="">) : ''}</div>
          <div class="cell">
            <div class="title"><span class="name" title="#{h(full_name)}">#{h(full_name)}</span><span class="ts"> #{h(last_date)}</span></div>
            <div class="preview" title="#{preview}">#{preview}</div>
          </div>
          <a class="cover" href="#{h(m['path'])}" data-path="#{h(m['path'])}" target="viewer" aria-label="Open #{h(full_name)}"></a>
        </li>)
    }.join("\n")
  end

  def initials_for(name)
    s = name.to_s.strip
    return '?' if s.empty?
    parts = s.split(/\s+/)
    init = parts[0][0]
    init += parts[1][0] if parts.length > 1
    init.upcase
  end

  def js
    <<~JS
    window.addEventListener('DOMContentLoaded', () => {
      var list = document.getElementById('chat-list');
      var filter = document.getElementById('filter');
      var viewer = document.getElementById('viewer');
      var clear = document.getElementById('clear-filter');
      var menuBtn = document.getElementById('menu-toggle');
      var backdrop = document.getElementById('backdrop');

      function visibleItems(){ return Array.prototype.filter.call(list.querySelectorAll('li'), function(li){ return li.offsetParent !== null && !li.hasAttribute('hidden'); }); }
      var activeIndex = -1;

      function closeMenuIfMobile(){
        if (window.matchMedia('(max-width: 900px)').matches) {
          document.body.classList.remove('menu-open');
          if (backdrop) backdrop.setAttribute('hidden','');
        }
      }

      function flashListStripe(){
        try {
          var li = list && list.querySelector('li.active');
          if (!li) return;
          li.classList.add('flash');
          setTimeout(function(){ try { li.classList.remove('flash'); } catch(e){} }, 550);
        } catch(e){}
      }

      function focusViewer(noFlash){
        try {
          if (viewer) viewer.focus();
          // Only tell iframe to focus the thread when not in a special no-flash/no-message path
          if (!noFlash && viewer && viewer.contentWindow && viewer.contentWindow.postMessage) {
            viewer.contentWindow.postMessage({ type: 'focus-thread' }, '*');
          }
          if (viewer && !noFlash) {
            viewer.classList.add('flash-border');
            setTimeout(function(){ try { viewer.classList.remove('flash-border'); } catch(e){} }, 550);
          }
        } catch(e){}
      }

      function focusList(){ try { var active = list && list.querySelector('li.active'); (active || list.querySelector('li'))?.focus(); } catch(e){} }

      // Expose hooks for iframe to call back
      window.__focusList = focusList;
      window.__focusViewer = focusViewer;

      // Cross-document message bridge (works for file:// iframes)
      window.addEventListener('message', function(ev){
        try {
          var data = ev && ev.data;
          if (data && data.type === 'focus-list') {
            if (window.matchMedia('(max-width: 900px)').matches) { try { openMenu(); } catch(e){} }
            focusList();
            flashListStripe();
          }
          if (data && data.type === 'focus-viewer') {
            closeMenuIfMobile();
            focusViewer();
          }
          if (data && data.type === 'focus-filter') {
            try {
              if (window.matchMedia('(max-width: 900px)').matches) { openMenu(); }
              if (filter) { filter.focus(); filter.select && filter.select(); }
            } catch(e){}
          }
        } catch(e){}
      });

      function activate(li, a) {
        if (!list || !viewer || !li) return;
        Array.prototype.forEach.call(list.querySelectorAll('li.active'), function(el){ el.classList.remove('active'); });
        li.classList.add('active');
        var href = a ? (a.getAttribute('data-path') || a.getAttribute('href')) : (li.querySelector('a') && li.querySelector('a').getAttribute('href'));
        if (href && viewer.getAttribute('src') !== href) {
          try { viewer.style.opacity = '0'; } catch(e){}
          viewer.setAttribute('src', href);
          var id = li.getAttribute('data-id') || href;
          try { if (history.state?.sel !== id) history.pushState({ sel: id }, '', '#thread=' + encodeURIComponent(id)); } catch(e){}
          viewer.addEventListener('load', function onload(){ viewer.removeEventListener('load', onload); try { viewer.style.opacity = '1'; } catch(e){} });
        }
        closeMenuIfMobile();
      }

      if (list) {
        list.addEventListener('click', function(e){
          var a = e.target.closest('a');
          if (!a) return;
          e.preventDefault();
          activate(a.parentElement, a);
        });
        list.addEventListener('keydown', function(e){
          var items = visibleItems();
          var idx = items.indexOf(document.activeElement);
          if (e.key === 'ArrowDown') { e.preventDefault(); var next = items[Math.min((idx>=0?idx:0)+1, items.length-1)] || items[0]; if (next){ next.focus(); activate(next, next.querySelector('a')); } return; }
          if (e.key === 'ArrowUp')   { e.preventDefault(); var prev = items[Math.max((idx>=0?idx:0)-1, 0)] || items[0]; if (prev){ prev.focus(); activate(prev, prev.querySelector('a')); } return; }
          if (e.key === 'ArrowRight') { e.preventDefault(); focusViewer(); return; }
          if (e.key === 'Enter' || e.key === ' ') {
            var li = document.activeElement.closest && document.activeElement.closest('li');
            if (!li) li = items[0];
            if (!li) return; e.preventDefault(); activate(li, li.querySelector('a'));
          }
        });
        list.addEventListener('click', function(e){
          var li = e.target.closest('li');
          if (!li || e.target.tagName === 'A') return;
          activate(li, li.querySelector('a'));
        });
      }

      // (removed) client-side date formatting for list timestamps; dates are precomputed

      function updateClear(){ if (clear) clear.style.display = (filter && filter.value) ? 'inline-flex' : 'none'; }

      if (filter && list) {
        function applyFilter(){
          var q = (filter.value || '').trim().toLowerCase();
          Array.prototype.forEach.call(list.querySelectorAll('li'), function(li){
            var name = (li.getAttribute('data-name') || '').toLowerCase();
            // Filter only by chat name; do not match preview text
            var show = !q || name.indexOf(q) !== -1;
            if (show) li.removeAttribute('hidden'); else li.setAttribute('hidden','');
          });
          updateClear();
        }
        filter.addEventListener('input', applyFilter);
        filter.addEventListener('focus', updateClear);
        // Arrow keys from filter jump to first/last visible item
        filter.addEventListener('keydown', function(e){
          if (!list) return;
          var items = visibleItems();
          if (!items.length) return;
          if (e.key === 'ArrowDown') {
            e.preventDefault();
            var first = items[0];
            first && first.focus && first.focus();
            activate(first, first.querySelector('a'));
          } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            var last = items[items.length - 1];
            last && last.focus && last.focus();
            activate(last, last.querySelector('a'));
          }
        });
        // Run once on load in case of autofill or hash
        applyFilter();
      }
      if (clear && filter) clear.addEventListener('click', function(){ filter.value=''; filter.dispatchEvent(new Event('input')); filter.focus(); });
      if (filter) filter.addEventListener('keydown', function(e){
        if (e.key === 'Escape') {
          e.preventDefault();
          var val = (filter.value || '').trim();
          if (val) { filter.value=''; filter.dispatchEvent(new Event('input')); filter.focus(); }
          else {
            // Instead of blurring, move focus to the scrollable conversation list
            try { focusList(); } catch(e){}
          }
        }
      });

      // Activate from hash on load for back/forward, else first visible
      function activateFromHash(){
        var m = (location.hash||'').match(/#thread=([^&]+)/);
        var sel = m ? decodeURIComponent(m[1]) : null;
        if (sel && list){
          var target = Array.prototype.find.call(list.querySelectorAll('li'), function(li){ return (li.getAttribute('data-id') === sel) || ((li.querySelector('a')||{}).getAttribute('href') === sel); });
          if (target){ target.focus(); activate(target, target.querySelector('a')); return true; }
        }
        return false;
      }
      if (!activateFromHash()){
        var first = list && visibleItems()[0];
        if (first) { first.focus(); activate(first, first.querySelector('a')); }
      }
      window.addEventListener('popstate', function(){ activateFromHash(); });
      // Also react to direct hash changes
      window.addEventListener('hashchange', function(){ activateFromHash(); });

      // Mobile menu toggle
      function openMenu(){ document.body.classList.add('menu-open'); if (backdrop) backdrop.removeAttribute('hidden'); }
      function closeMenu(){ document.body.classList.remove('menu-open'); if (backdrop) backdrop.setAttribute('hidden',''); }
      if (menuBtn) menuBtn.addEventListener('click', function(){ if (document.body.classList.contains('menu-open')) closeMenu(); else openMenu(); });
      if (backdrop) backdrop.addEventListener('click', closeMenu);
      document.addEventListener('keydown', function(e){
        if (e.key === 'Escape') closeMenu();
        var isMac = /Mac|iPhone|iPad|iPod/.test(navigator.platform);
        // Shortcuts: Mac uses Ctrl+[1|2]; others use Alt+[1|2]. Avoid Cmd which collides with Safari tabs.
        if (isMac && e.ctrlKey && e.key === '1') { e.preventDefault(); try { if (window.matchMedia('(max-width: 900px)').matches) { openMenu(); } focusList(); flashListStripe(); } catch(e){} }
        if (isMac && e.ctrlKey && e.key === '2') { e.preventDefault(); try { closeMenu(); focusViewer(false); } catch(e){} }
        if (!isMac && e.altKey && e.key === '1') { e.preventDefault(); try { if (window.matchMedia('(max-width: 900px)').matches) { openMenu(); } focusList(); flashListStripe(); } catch(e){} }
        if (!isMac && e.altKey && e.key === '2') { e.preventDefault(); try { closeMenu(); focusViewer(false); } catch(e){} }

        // New shortcuts: focus filter/search bars
        // Filter: Ctrl-F (Mac) / Alt-F (others)
        if (isMac && e.ctrlKey && e.key.toLowerCase() === 'f') {
          e.preventDefault();
          try { if (window.matchMedia('(max-width: 900px)').matches) { openMenu(); } filter && filter.focus(); filter && filter.select && filter.select(); } catch(e){}
        }
        if (!isMac && e.altKey && e.key.toLowerCase() === 'f') {
          e.preventDefault();
          try { if (window.matchMedia('(max-width: 900px)').matches) { openMenu(); } filter && filter.focus(); filter && filter.select && filter.select(); } catch(e){}
        }
        // Search field in viewer: Ctrl-S (Mac) / Alt-S (others)
        if ((isMac && e.ctrlKey && e.key.toLowerCase() === 's') || (!isMac && e.altKey && e.key.toLowerCase() === 's')) {
          e.preventDefault();
          try {
            closeMenu();
            // Robust across file:// origin isolation: use postMessage
            if (viewer && viewer.contentWindow && viewer.contentWindow.postMessage) {
              viewer.contentWindow.postMessage({ type: 'focus-search' }, '*');
              // If iframe is still loading, re-send on load
              viewer.addEventListener('load', function onload(){ viewer.removeEventListener('load', onload); try { viewer.contentWindow.postMessage({ type: 'focus-search' }, '*'); } catch(e){} });
            }
            // Do NOT flash when intent is to focus search; just ensure logical focus
            focusViewer(true);
          } catch(e){}
        }
      });
    });
    JS
  end

  def css
    <<~CSS
    :root { --bg:#f5f5f7; --pane:#ffffff; --text:#111; --muted:#6b7280; --accent:#3b82f6; --highlight: rgba(250, 204, 21, 1); --hairline: rgba(0,0,0,0.08); }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { height:100%; }
    body { margin:0; font:14px/1.4 -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; color:var(--text); background:var(--bg); overflow:hidden; }
    .app { display:flex; height:100%; position:relative; }
    .sidebar { width: 360px; max-width: 95vw; background: var(--pane); border-right:1px solid var(--hairline); display:flex; flex-direction:column; }
    .search { padding:12px; border-top:1px solid var(--hairline); }
    .search.bottom { margin-top:auto; }
    .input-wrap { position:relative; }
    .search input { width:100%; padding:10px 36px 10px 12px; border-radius:12px; border:1px solid rgba(0,0,0,0.18); background:#fff; color:var(--text); box-shadow: 0 1px 2px rgba(0,0,0,0.04) inset; font-size:16px; }
    .clear-btn { position:absolute; right:6px; top:50%; transform: translateY(-50%); width:22px; height:22px; border-radius:9999px; display:none; align-items:center; justify-content:center; border:0; background:#9ca3af; color:#fff; font-weight:800; cursor:pointer; font-size:16px; line-height:1; }
    .clear-btn:hover { filter:brightness(0.95); }
    .chat-list { list-style:none; margin:0; padding:0; overflow:auto; flex:1; }
    /* Nudge content closer to the top, keep bottom roomy */
    .chat-list li { position:relative; display:flex; align-items:center; gap:12px; padding:10px 16px 14px; border-bottom:1px solid var(--hairline); cursor:pointer; outline:none; }
    .chat-list li:focus { outline:none; }
    .chat-list li:focus-visible { outline:none; }
    .chat-list li.active { background:rgba(0,0,0,0.06); box-shadow: inset 3px 0 0 var(--accent); }
    /* 500ms yellow stripe flash when list gains keyboard focus */
    .chat-list li.active.flash::after { content:''; position:absolute; left:0; top:0; bottom:0; width:3px; background:var(--highlight); animation: flash 500ms ease-in-out 1 both; }
    .chat-list .avatar { width:44px; height:44px; border-radius:9999px; background:#e5e7eb; color:#111; flex:none; display:flex; align-items:center; justify-content:center; font-weight:600; font-size:14px; }
    .chat-list .avatar img { width:100%; height:100%; border-radius:9999px; object-fit:cover; display:block; }
    .chat-list .avatar::after { content: attr(data-initial); }
    .chat-list .cell { min-width:0; flex:1; }
    .chat-list .title { color:var(--text); font-weight:600; display:flex; align-items:flex-start; gap:8px; }
    .chat-list .title .name { flex:1; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .chat-list .title .ts { flex:none; color:var(--muted); font-weight:700; font-size:11px; font-variant-numeric: tabular-nums; }
    /* Give a touch more separation from the title */
    .chat-list .preview { color:var(--muted); font-size:12px; margin-top:6px; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
    .chat-list .cover { position:absolute; inset:0; text-indent:-9999px; }
    .viewer { flex:1; min-width:0; overflow:hidden; }
    .viewer iframe { width:100%; height:100%; border:0; background:var(--pane); display:block; outline:none; }
    .viewer iframe:focus { outline:none; }
    /* 500ms yellow interior border when viewer gains focus via keyboard */
    .viewer iframe.flash-border { animation: flash-scale 300ms ease-in-out 1 both; }

    @keyframes flash { 0% { opacity: 0; } 50% { opacity: 1; } 100% { opacity: 0; } }
    @keyframes flash-scale {
      0%   { transform: scale(1); }
      50%  { transform: scale(1.02); }
      100% { transform: scale(1); }
    }

    /* Mobile hamburger icon (bare icon, no roundrect) */
    .hamburger { position:fixed; top:10px; left:12px; width:auto; height:auto; border:0; background:transparent; color:var(--text); display:none; align-items:center; justify-content:center; z-index:50; font-size:34px; cursor:pointer; line-height:1; padding:0; }
    .backdrop { position:fixed; inset:0; background:rgba(0,0,0,0.35); z-index:40; }

    @media (prefers-color-scheme: dark) {
      :root { --bg:#000; --pane:#1c1c1e; --text:#fff; --muted:#a1a1aa; --accent:#3b82f6; --highlight:#facc15; --hairline: rgba(255,255,255,0.12); }
      body { background: var(--bg); color: var(--text); }
      .search input { background:#2c2c2e; border-color: rgba(255,255,255,0.18); color: var(--text); box-shadow: none; }
      .sidebar { background: var(--pane); border-right-color: var(--hairline); }
      .chat-list li.active { background: rgba(255,255,255,0.06); box-shadow: inset 3px 0 0 var(--accent); }
      .chat-list .avatar { background:#2c2c2e; color:#fff; }
      .viewer iframe { background: var(--pane); }
    }
    @media (max-width: 900px) {
      .hamburger { display:flex; }
      .sidebar { position:fixed; top:0; left:0; bottom:0; width:min(86vw, 360px); transform:translateX(-100%); transition:transform 0.2s ease; z-index:60; }
      body.menu-open .sidebar { transform:translateX(0); }
      body.menu-open .backdrop { display:block; }
      .viewer { flex:1; }
      .chat-list li { padding:16px; }
    }
    CSS
  end

  def h(s)
    CGI.escapeHTML(s.to_s)
  end
end
