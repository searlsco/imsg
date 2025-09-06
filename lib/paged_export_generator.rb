require 'json'
require 'erb'
require 'cgi'
require_relative 'imsg/util/attachment_util'
require_relative 'imsg/project/message'

class PagedExportGenerator
  def initialize(chat, messages, attachments, page_size: 1000, flip: false, attachments_included: true, friendly_names: {})
    @chat = chat
    @messages = messages
    @attachments = attachments
    @page_size = [page_size.to_i, 1].max
    @flip = !!flip
    @attachments_included = !!attachments_included
    @friendly_names = (friendly_names || {})
  end

  # Writes index.html, styles.css (provided), manifest.json, messages/*.json, script.js
  def write(outdir, styles_css)
    messages_dir = File.join(outdir, 'messages')
    FileUtils.mkdir_p(messages_dir)

    # Prepare renderable messages via projection layer
    # Respect skip_render flags set during projection (e.g., tapback descriptions)
    renderables = @messages.filter_map do |m|
      next nil if m && m['skip_render']
      Imsg::Project::Message.project(m, (@attachments[m['message_id']] || []), is_group: !!@chat['is_group'], friendly_names: @friendly_names)
    end

    # Chunk and write JSON pages
    chunks = []
    renderables.each_slice(@page_size).with_index do |slice, idx|
      filename = sprintf('page-%04d.json', idx + 1)
      path = File.join(messages_dir, filename)
      File.write(path, JSON.pretty_generate(slice))
      # Also write JS wrapper for file:// environments
      js_name = filename.sub(/\.json\z/, '.js')
      js_path = File.join(messages_dir, js_name)
      js_payload = "window.__IMSG_ADD_PAGE && window.__IMSG_ADD_PAGE(#{idx + 1}, #{JSON.generate(slice)});\n"
      File.write(js_path, js_payload)

      chunks << {
        'file' => "messages/#{filename}",
        'file_js' => "messages/#{js_name}",
        'index' => idx + 1,
        'count' => slice.length,
        'start_ts' => slice.first && (slice.first['sent_at_local'] || slice.first[:sent_at_local]),
        'end_ts' => slice.last && (slice.last['sent_at_local'] || slice.last[:sent_at_local]),
        'start_id' => slice.first && (slice.first['message_id'] || slice.first[:message_id]),
        'end_id' => slice.last && (slice.last['message_id'] || slice.last[:message_id]),
      }
    end

    # Ensure assets dir exists; drop shared assets (file icon)
    assets_dir = File.join(outdir, 'assets')
    FileUtils.mkdir_p(assets_dir)
    icon_src = File.expand_path(File.join(__dir__, '..', 'assets', 'file.svg'))
    if File.exist?(icon_src)
      begin
        FileUtils.cp(icon_src, File.join(assets_dir, 'file.svg'))
      rescue
      end
    end

    # Write manifest
    # Prefer the full, untruncated name everywhere; only CSS should elide.
    effective_name = if @chat['display_name_full'] && !@chat['display_name_full'].to_s.strip.empty?
                       @chat['display_name_full'].to_s.strip
                     else
                       (@chat['display_name'] || 'Messages').to_s.strip
                     end
    manifest = {
      'chat' => {
        'display_name' => @chat['display_name'],
        'is_group' => @chat['is_group'],
        'participant_handles' => @chat['participant_handles'],
        'display_name_full' => @chat['display_name_full'],
        'display_name_effective' => effective_name
      },
      'total_messages' => renderables.length,
      'page_size' => @page_size,
      'chunks' => chunks,
      'flip' => @flip,
      'attachments_included' => @attachments_included,
      'friendly_names' => @friendly_names
    }
    File.write(File.join(outdir, 'manifest.json'), JSON.pretty_generate(manifest))
    # JS version for file:// environments
    File.write(File.join(outdir, 'manifest.js'), "window.IMSG_MANIFEST = #{JSON.generate(manifest)};\n")

    # Write index and assets
    File.write(File.join(outdir, 'index.html'), html_shell(@chat))
    File.write(File.join(outdir, 'styles.css'), styles_css)
    File.write(File.join(outdir, 'script.js'), client_script)
  end

  private

  # (projection now handles invisibility, kinds, and hide rules)

  def html_shell(chat)
    # Prefer explicit group name in header/title when present; otherwise fall back
    # to the full participant list, then to display_name, then generic.
    # Prefer the full, untruncated chat name in headers and titles.
    display = if chat['display_name_full'] && !chat['display_name_full'].to_s.strip.empty?
                chat['display_name_full'].to_s.strip
              else
                (chat['display_name'] || 'Messages').to_s.strip
              end
    title = CGI.escapeHTML(display)
    header_title = CGI.escapeHTML(display)
    <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{title}</title>
      <link rel="stylesheet" href="styles.css">
      <style>
        :root { --highlight: #facc15; }
        .progress { text-align:center; color:#666; font-size:12px; padding:8px 0; }
        /* Match header background in light mode */
        .footer-bar { background: #fff; border-top: 1px solid rgba(0,0,0,0.10); }
        .footer-inner { max-width: 800px; margin: 0 auto; padding: 10px 16px calc(10px + env(safe-area-inset-bottom)); }
        .input-wrap { position: relative; }
        .search-input { width: 100%; padding: 12px 44px 12px 14px; border-radius: 12px; border: 1px solid rgba(0,0,0,0.15); background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,0.04) inset; font-size:16px; color:#111; }
        #clear-q { position:absolute; right:8px; top:50%; transform: translateY(-50%); width:28px; height:28px; border-radius:9999px; display:none; align-items:center; justify-content:center; border:0; background:#9ca3af; color:#fff; font-weight:800; cursor:pointer; font-size:18px; line-height:1; }
        /* Fill between sticky header and fixed footer */
        html, body { height: 100%; }
        body { display: flex; flex-direction: column; min-height: 100vh; }
        /* Reduce bottom padding now that footer is not fixed */
        .thread { flex: 1 1 auto; padding-bottom: 24px; overflow-y: auto; display: flex; flex-direction: column-reverse; overscroll-behavior: contain; scrollbar-gutter: stable; width: 100%; }
        .thread:focus, .thread:focus-visible { outline: none; }
        .results-overlay { position: fixed; left: 0; right: 0; bottom: 60px; z-index: 250; }
        .results-head { max-width: 800px; margin: 0 auto; background: rgba(255,255,255,0.95); backdrop-filter: blur(8px); border: 1px solid rgba(0,0,0,0.08); border-bottom: none; border-radius: 12px 12px 0 0; padding: 10px 12px; display:flex; align-items:center; justify-content: space-between; }
        .results-title { font-size: 13px; color: #444; }
        .results-close { font-size: 12px; border-radius: 8px; padding: 6px 10px; border: 1px solid rgba(0,0,0,0.15); background: #fff; cursor: pointer; }
        .results-list { max-width: 800px; margin: 0 auto; max-height: 40vh; overflow: auto; background: rgba(255,255,255,0.95); backdrop-filter: blur(8px); border: 1px solid rgba(0,0,0,0.08); border-top: none; border-radius: 0 0 12px 12px; }
        .result-item { width: 100%; display: block; text-align: left; padding: 12px 12px; border: 0; border-bottom: 1px solid rgba(0,0,0,0.06); background: transparent; cursor: pointer; position: relative; }
        .result-item:hover { background: rgba(0,0,0,0.03); }
        .result-item.selected { background: transparent; }
        .result-item.selected::before { content:''; position:absolute; left:0; top:0; bottom:0; width:4px; background:var(--highlight); border-radius:0 3px 3px 0; }
        .result-when { font-size: 12px; color: #6b7280; margin: 6px 0; padding-left: 2px; }
        .result-bubble { pointer-events: none; }
        mark { background: #fff59d; }
        /* Emphasize matches inside the selected target message */
        mark.selected-match { background: #fff59d; box-shadow: 0 0 0 2px #fff59d inset; }
        /* Pop only the content area (bubble or media), not the timestamp */
        .search-focus .bubble, .search-focus .media {
          animation: bubble-pop 1200ms ease-out 1;
          box-shadow: 0 0 0 5px rgba(253, 224, 71, 0.78);
        }
        @keyframes bubble-pop { 0% { transform: scale(1); } 30% { transform: scale(1.08); } 100% { transform: scale(1); } }
        /* Apple Cash payment card */
        .payment-card { background:#000; color:#fff; border-radius:16px; padding:20px 24px; width:min(320px, 85%); text-align:center; box-shadow: 0 1px 2px var(--shadow); }
        .message.me .payment-card { margin-left: auto; }
        .message.them .payment-card { margin-right: auto; }
        .payment-amount { font-size:28px; font-weight:800; letter-spacing:0.5px; }
        @media (prefers-color-scheme: dark) {
      /* Match header background in dark mode */
      .footer-bar { background: #1c1c1e; border-top-color: rgba(255,255,255,0.10); }
          .search-input { background:#2c2c2e; border-color: rgba(255,255,255,0.18); color:#fff; box-shadow: none; }
          .results-head { background: rgba(20,20,20,0.92); border-color: rgba(255,255,255,0.12); }
          .results-title { color: #c7c7cc; }
          .results-close { background:#2c2c2e; border-color: rgba(255,255,255,0.18); color:#fff; }
          .results-list { background: rgba(20,20,20,0.92); border-color: rgba(255,255,255,0.12); }
        }
      </style>
    </head>
    <body>
      <div class="header">
        <h1 style="white-space:normal; overflow:visible; text-overflow:clip">#{header_title}</h1>
      </div>
      <div id="thread" class="thread"><div id="top-sentinel" class="progress">Loading…</div></div>
      <div id="results" aria-live="polite" style="display:none"></div>
      <div class="footer-bar">
        <div class="footer-inner">
          <div class="input-wrap">
            <input id="q" class="search-input" type="text" placeholder="Search #{CGI.escapeHTML(display)}…" aria-label="Search messages in #{CGI.escapeHTML(display)}">
            <button id="clear-q" type="button" aria-label="Clear search">×</button>
          </div>
        </div>
      </div>
      <noscript>This export uses JavaScript to load messages as you scroll. Please enable JavaScript.</noscript>
      <script src="script.js?v=#{Time.now.to_i}"></script>
    </body>
    </html>
    HTML
  end

  def client_script
    # Plain JS to fetch manifest + pages and render on scroll; includes simple on-demand search
    <<~'JS'
    (() => {
      const state = {
        manifest: null,
        nextIndex: 0,
        loading: false,
      };

      const thread = document.getElementById('thread');
      const topSentinel = document.getElementById('top-sentinel');
      const q = document.getElementById('q');
      const clearBtn = document.getElementById('clear-q');
      const results = document.getElementById('results');

      // Make thread focusable for keyboard scrolling
      if (thread && !thread.hasAttribute('tabindex')) thread.setAttribute('tabindex', '0');

      // Parent can request focus into the scrollable thread
      window.addEventListener('message', (ev) => {
        const data = ev && ev.data;
        if (!data) return;
        if (data.type === 'focus-thread') {
          try { thread && thread.focus(); } catch {}
        } else if (data.type === 'focus-search') {
          try { if (q) { q.focus(); q.select && q.select(); } else { thread && thread.focus(); } } catch {}
        }
      });

      if (location.protocol === 'file:') {
        // Load manifest via <script> to avoid file:// fetch restrictions
        loadScript('manifest.js').then(() => {
          state.manifest = window.IMSG_MANIFEST;
          bootstrap();
        }).catch(err => { topSentinel.textContent = 'Failed to load manifest'; console.error(err); });
      } else {
        fetch('manifest.json').then(r => r.json()).then(manifest => { state.manifest = manifest; bootstrap(); })
          .catch(err => { topSentinel.textContent = 'Failed to load manifest'; console.error(err); });
      }

      function bootstrap() {
        try {
          const ef = (state.manifest?.chat?.display_name_effective);
          const fallback = (state.manifest?.chat?.display_name_full) || (state.manifest?.chat?.display_name) || 'this conversation';
          const name = ef || fallback;
          if (q) {
            q.placeholder = `Search ${name}`;
            q.setAttribute('aria-label', `Search messages in ${name}`);
          }
          const h = document.querySelector('.header h1');
          if (h && h.textContent !== name) h.textContent = name;
          try { document.title = name; } catch {}
        } catch {}
        // Start from the newest chunk and load older chunks when scrolling up
        const chunks = state.manifest.chunks;
        state.nextIndex = chunks.length; // one past the last
        loadPrev();
        // Observe the top sentinel to load more when user scrolls up
        const io = new IntersectionObserver(entries => {
          entries.forEach(entry => { if (entry.isIntersecting) loadPrev(); });
        }, { root: thread, rootMargin: '800px 0px' });
        io.observe(topSentinel);
        state.io = io;
      }

      function loadPrev() {
        if (state.loading) return;
        const chunks = state.manifest?.chunks || [];
        if (state.nextIndex <= 0) {
          // Finished loading all chunks; disconnect observer and hide sentinel
          try { if (state.io) state.io.disconnect(); } catch {}
          try { topSentinel.textContent = ''; topSentinel.style.display = 'none'; } catch {}
          return;
        }
        state.loading = true;
        const chunk = chunks[state.nextIndex - 1];
        const load = () => {
          const done = (page) => { renderPage(page, 'prepend'); state.nextIndex -= 1; };
          // Preserve scrollbar thumb position while we add older content at the top (DOM end)
          const prevAnchor = thread.scrollHeight - thread.scrollTop;
          if (location.protocol === 'file:') {
            return loadPageViaScript(chunk.index, chunk.file_js).then((p)=>{ done(p); try { thread.scrollTop = thread.scrollHeight - prevAnchor; } catch(e){} finally { if (state.nextIndex <= 0) { try { if (state.io) state.io.disconnect(); } catch {} try { topSentinel.textContent=''; topSentinel.style.display='none'; } catch {} } } });
          } else {
            return fetch(chunk.file).then(r => r.json()).then((p)=>{ done(p); try { thread.scrollTop = thread.scrollHeight - prevAnchor; } catch(e){} finally { if (state.nextIndex <= 0) { try { if (state.io) state.io.disconnect(); } catch {} try { topSentinel.textContent=''; topSentinel.style.display='none'; } catch {} } } });
          }
        };
        load().catch(err => { console.error('Failed to load page', chunk, err); topSentinel.textContent = 'Error loading messages'; })
             .finally(() => { state.loading = false; });
      }

      function renderPage(page /* always older chunk */, _mode) {
        // Column-reverse: to display the day label ABOVE a day's block,
        // append the separator AFTER the LAST message of that day in DOM.
        const items = page.slice().reverse();
        const frag = document.createDocumentFragment();
        for (let i = 0; i < items.length; i++) {
          const m = items[i];
          const day = m.day_label || '';
          frag.appendChild(renderMessage(m));
          const next = items[i+1];
          const nextDay = next ? (next.day_label || '') : null;
          if (nextDay !== day) {
            const sep = document.createElement('div');
            sep.className = 'day-separator';
            sep.textContent = day;
            frag.appendChild(sep);
          }
        }
        thread.appendChild(frag);
        // Keep sentinel at the very end (visual top)
        if (topSentinel && thread.lastChild !== topSentinel) thread.appendChild(topSentinel);
        dedupeDaySeparators();
        pruneDanglingDayAtEnd();
      }

      // (removed: legacy day lookup helpers)
      function dedupeDaySeparators() {
        // Only collapse immediately-adjacent duplicate day labels.
        // We intentionally keep the top-of-day label when more messages
        // from the same day are loaded later.
        let prevWasSep = false;
        let prevText = null;
        const toRemove = [];
        for (const el of thread.childNodes) {
          if (el && el.classList && el.classList.contains('day-separator')) {
            const t = el.textContent;
            if (prevWasSep && t === prevText) toRemove.push(el);
            prevWasSep = true;
            prevText = t;
          } else {
            prevWasSep = false;
            prevText = null;
          }
        }
        toRemove.forEach(el => el.remove());
      }

      // Remove only truly dangling day separators at the visual top.
      // In column-reverse, a day label should remain at the very end (top)
      // if it directly follows a message element, because it labels that
      // earliest block. We only prune if the label is not followed by a
      // message (e.g., duplicated at chunk boundaries).
      function pruneDanglingDayAtEnd() {
        if (!thread) return;
        let last = thread.lastChild;
        // If last is the sentinel, look at the previous sibling (visual top)
        if (last === topSentinel) last = last && last.previousSibling;
        if (last && last.classList && last.classList.contains('day-separator')) {
          const prev = last.previousSibling;
          const prevIsMessage = prev && prev.classList && prev.classList.contains('message');
          if (!prevIsMessage) {
            last.remove();
          }
        }
      }

      function renderMessage(m) {
        const flipped = !!(state.manifest && state.manifest.flip);
        const side = (m.is_from_me == 1) ? (flipped ? 'them' : 'me') : (flipped ? 'me' : 'them');
        const root = el('div', { class: `message ${side}`,
                                  'data-message-id': m.message_id,
                                  'data-from-me': m.is_from_me,
                                  ...(m.author_handle ? { 'data-author-handle': m.author_handle } : {}) });
        const wrap = el('div', { class: 'bubble-wrapper' });

        const attachments = m.attachments || [];
        const text = (m.text || '').trim();
        const reactions = m.reactions || [];
        const mediaOnly = attachments.length > 0 && text.length === 0;

        // Apple Cash card
        if (m.payment) {
          const card = el('div', { class: 'payment-card' }, [ el('div', { class: 'payment-amount' }, [ textNode(m.payment_amount || 'Apple Cash') ]) ]);
          wrap.appendChild(card);
          wrap.appendChild(renderTimestamp(m.sent_at_local));
          root.appendChild(wrap);
          return root;
        }

        if ((state.manifest?.chat?.is_group) && m.is_from_me != 1 && (m.author_name || m.author_handle)) {
          wrap.appendChild(el('div', { class: 'author-label' }, [ textNode(m.author_name || m.author_handle) ]));
        }

        if (mediaOnly) {
          const media = el('div', { class: 'media' });
          for (const att of attachments) media.appendChild(renderAttachment(att));
          if (reactions.length) media.appendChild(renderReactions(reactions, m));
          wrap.appendChild(media);
          wrap.appendChild(renderTimestamp(m));
        } else {
          if (text) {
            const bubble = el('div', { class: 'bubble' }, [ el('div', { class: 'bubble-content' }) ]);
            try { bubble.querySelector('.bubble-content').innerHTML = m.text_html || ''; } catch {}
            if (reactions.length) bubble.appendChild(renderReactions(reactions, m));
            wrap.appendChild(bubble);
          }
          if (attachments.length) {
            const media = el('div', { class: 'media' });
            for (const att of attachments) media.appendChild(renderAttachment(att));
            wrap.appendChild(media);
          }
          wrap.appendChild(renderTimestamp(m));
        }

        root.appendChild(wrap);
        return root;
      }

      function renderAttachment(att) {
        const container = el('div', { class: 'attachment' });
        if (att.missing) {
          container.appendChild(el('div', { class: 'attachment-missing' }, [ textNode(`Attachment not available: ${att.transfer_name || att.guid || 'Unknown'}`) ]));
          return container;
        }
        if (state.manifest && state.manifest.attachments_included === false) {
          const name = att.transfer_name || (att.filename ? att.filename.split('/').pop() : 'Unknown');
          container.appendChild(el('div', { class: 'attachment-missing' }, [ textNode(`[Missing file: ${name}]`) ]));
          return container;
        }
        const mime = (att.mime_type || '').toLowerCase();
        const nameForType = (att.filename || att.transfer_name || '').toLowerCase();
        const kind = (att.kind || '').toLowerCase();
        const isImage = kind==='image' || mime.startsWith('image/') || /\.(jpe?g|png|gif|heic|heif|webp)$/.test(nameForType);
        const isVideo = kind==='video' || mime.startsWith('video/') || /\.(mov|mp4|m4v|webm)$/.test(nameForType);
        const isAudio = kind==='audio' || mime.startsWith('audio/') || /\.(m4a|aac|mp3|wav|aiff?)$/.test(nameForType);
        if (isImage) {
          const attrs = { src: att.filename, alt: att.transfer_name || 'Image', loading: 'lazy' };
          if (att.width && att.height) { attrs.width = att.width; attrs.height = att.height; }
          const img = el('img', attrs);
          const picture = el('picture', {}, [ img ]);
          container.appendChild(picture);
        } else if (isVideo) {
          const source = el('source', { src: att.filename, type: att.mime_type });
          const vattrs = { controls: true, preload: 'metadata' };
          if (att.width && att.height) { vattrs.width = att.width; vattrs.height = att.height; }
          const video = el('video', vattrs, [ source, textNode('Your browser does not support the video tag.') ]);
          container.appendChild(video);
        } else if (isAudio) {
          const source = el('source', { src: att.filename, type: att.mime_type });
          const audio = el('audio', { controls: true }, [ source, textNode('Your browser does not support the audio tag.') ]);
          container.appendChild(audio);
        } else {
          if (att.filename) {
            const name = att.transfer_name || (att.filename ? att.filename.split('/').pop() : 'Unknown');
            const a = el('a', { class: 'file-link', href: att.filename, download: true }, [
              el('img', { class: 'file-icon', src: 'assets/file.svg', alt: '' }),
              el('div', { class: 'file-name' }, [ textNode(name) ]),
            ]);
            container.appendChild(a);
          } else {
            container.appendChild(el('div', { class: 'attachment-missing' }, [ textNode(`File: ${att.transfer_name || 'Unknown'}`) ]));
          }
        }
        return container;
      }

      function renderReactions(reactions, m) {
        const wrap = el('div', { class: 'reactions' });
        for (const r of reactions) {
          const badge = el('div', { class: `reaction-badge ${r.reactor === 'me' ? 'from-me' : 'from-them'}` }, [ textNode(r.emoji), (r.count && r.count > 1) ? el('span', { class: 'reaction-count' }, [ textNode(String(r.count)) ]) : null ].filter(Boolean));
          wrap.appendChild(badge);
        }
        return wrap;
      }

      function renderTimestamp(m) {
        const time = el('time', { datetime: (m.sent_at_iso || '') }, [ textNode(m.sent_at_human || '') ]);
        return el('div', { class: 'timestamp' }, [ time ]);
      }

      // Utilities
      function updateClear(){ if (clearBtn) clearBtn.style.display = (q && q.value) ? 'inline-flex' : 'none'; }
      if (q) q.addEventListener('input', updateClear);
      if (clearBtn && q) clearBtn.addEventListener('click', () => { q.value=''; q.dispatchEvent(new Event('input')); q.focus(); updateClear(); });
      if (q) q.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.preventDefault(); const val = (q.value || '').trim(); if (val) { q.value=''; q.dispatchEvent(new Event('input')); try { updateClear(); } catch {} try { q.focus(); } catch {} } else { try { thread && thread.focus(); } catch {} } }});
      function el(tag, attrs = {}, children = []) {
        const node = document.createElement(tag);
        for (const [k, v] of Object.entries(attrs)) {
          if (v === true) node.setAttribute(k, '');
          else if (v !== false && v != null) node.setAttribute(k, String(v));
        }
        for (const child of children) if (child) node.appendChild(child);
        return node;
      }
      function textNode(t) { return document.createTextNode(t); }
      // Results overlay helpers
      let resultsListEl = null; let resultsHits = []; let resultsSel = -1;
      function clearResults() { results.style.display = 'none'; results.innerHTML = ''; q.value=''; resultsHits = []; resultsSel = -1; resultsListEl = null; clearSelectionEffects(); try { q.focus(); } catch {}; try { updateClear(); } catch {} }
      function showResults(query, hits, exceeded) {
        results.style.display = 'block'; results.className = 'results-overlay'; results.innerHTML='';
        const shown = exceeded ? '100+' : String(hits.length);
        const head = el('div', { class: 'results-head' }, [ el('div', { class: 'results-title' }, [ textNode(`Search results for “${query}” (${shown})`) ]), el('button', { class: 'results-close', type: 'button' }, [ textNode('Close') ]) ]);
        head.querySelector('.results-close').addEventListener('click', () => { clearResults(); history.replaceState({}, '', location.pathname); });
        const list = el('div', { class: 'results-list', id: 'results-list' });
        resultsHits = hits; resultsSel = hits.length ? 0 : -1;
        for (let i = 0; i < hits.length; i++) {
          const h = hits[i];
          const item = el('button', { class: 'result-item' + (i===0?' selected':''), type: 'button', 'data-index': i });
          const when = el('div', { class: 'result-when' }, [ textNode(h.when_label || '') ]);
          // Build a bubble-like preview
          const msgPreview = buildResultMessage(h, query);
          item.appendChild(when); item.appendChild(msgPreview);
          item.addEventListener('click', async () => {
            // Keep results open; just jump and highlight (avoid stacking history)
            if (history.state?.view !== 'jump' || history.state?.target !== h.id) { history.replaceState({ view: 'jump', q: query, target: h.id }, '', `#msg=${h.id}`); }
            // Ensure the chunk for this hit is rendered (message_id ranges can be non-monotonic)
            await ensureRenderedByChunk(h.chunkIndex);
            const elMsg = thread.querySelector(`[data-message-id="${h.id}"]`);
            if (elMsg) { focusMessage(elMsg); applySelectedHighlight(elMsg, query); }
          });
          list.appendChild(item);
        }
        results.appendChild(head); results.appendChild(list);
        resultsListEl = list;
      }
      window.addEventListener('popstate', (e) => {
        const st = e.state || {};
        if (st.view === 'search' && st.q) { q.value = st.q; showResults(st.q, []); debounceSearch(st.q); } else { clearResults(); }
      });
      function highlight(text, query) {
        const idx = text.toLowerCase().indexOf(query.toLowerCase()); if (idx < 0) return textNode(text);
        const frag = document.createDocumentFragment();
        frag.appendChild(textNode(text.slice(0, idx)));
        frag.appendChild(el('mark', {}, [ textNode(text.slice(idx, idx + query.length)) ]));
        frag.appendChild(textNode(text.slice(idx + query.length)));
        return frag;
      }
      // (removed) formatWhen — dates are precomputed server-side

      // Build a message-like result item
      function buildResultMessage(h, query) {
        const side = h.is_from_me == 1 ? 'me' : 'them';
        const root = el('div', { class: `message ${side} result-bubble` });
        const wrap = el('div', { class: 'bubble-wrapper' });
        const text = h.preview_text || h.text || '';
        const bubble = el('div', { class: 'bubble' }, [ el('div', { class: 'bubble-content' }, [ highlight(text, query) ]) ]);
        wrap.appendChild(bubble);
        const time = el('time', { datetime: (h.sent_at_iso || '') }, [ textNode(h.sent_at_human || '') ]);
        wrap.appendChild(el('div', { class: 'timestamp' }, [ time ]));
        root.appendChild(wrap);
        return root;
      }

      // Focus a message robustly inside the scrollable thread (column-reverse safe)
      function focusMessage(elMsg) {
        if (!thread || !elMsg) return;
        const pad = 24; // leave room below sticky header
        const header = document.querySelector('.header');
        const headerH = header ? header.getBoundingClientRect().height : 0;

        // Step 1: bring the element into view deterministically
        try { elMsg.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'instant' }); } catch { try { elMsg.scrollIntoView(); } catch {} }

        // Step 2: iteratively adjust so the element sits just below the header
        let tries = 0;
        const place = () => {
          tries++;
          const cTop = thread.getBoundingClientRect().top;
          const eTop = elMsg.getBoundingClientRect().top;
          const desiredTop = cTop + headerH + pad;
          const delta = eTop - desiredTop; // positive -> move content up; negative -> down
          if (Math.abs(delta) < 2 || tries > 10) return;
          try { thread.scrollBy({ top: delta, behavior: 'instant' }); } catch { thread.scrollTop += delta; }
          requestAnimationFrame(place);
        };
        requestAnimationFrame(place);
        setTimeout(place, 120);
        setTimeout(place, 360);

        // Nudge on late media inside the focused message
        const media = elMsg.querySelectorAll('img, video');
        media.forEach(m => {
          const nudge = () => setTimeout(place, 40);
          if ((m.complete && (m.naturalWidth || m.readyState >= 2))) nudge();
          else { m.addEventListener('load', nudge, { once: true }); m.addEventListener('loadeddata', nudge, { once: true }); }
        });

        // Visual emphasis
        elMsg.classList.add('search-focus'); setTimeout(() => elMsg.classList.remove('search-focus'), 1200);
      }

      // Keyboard navigation + close (arrow keys only)
      const onKey = async (e) => {
        const inTextInput = e.target && ((e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) && e.target !== q);
        const inSearch = (e.target === q);
        if (inTextInput || e.metaKey || e.ctrlKey || e.altKey) return;
        // Escape behavior inside search: empty -> focus thread, else clear
        if (inSearch && e.key === 'Escape') {
          e.preventDefault();
          const val = (q.value || '').trim();
          if (val) { q.value=''; q.dispatchEvent(new Event('input')); try { updateClear(); } catch {} try { q.focus(); } catch {} }
          else { try { thread && thread.focus(); } catch {} }
          return;
        }
        // Do not hijack Left Arrow when editing inside the search field
        if (inSearch && e.key === 'ArrowLeft') return;
        // Escape to parent thread list with Left Arrow (except when editing search)
        if (e.key === 'ArrowLeft') { try { e.preventDefault(); window.parent && window.parent.postMessage && window.parent.postMessage({ type: 'focus-list' }, '*'); } catch {} return; }
        // Always allow Escape to clear search field/results even if list is not visible
        if (e.key === 'Escape') { e.preventDefault(); clearResults(); history.replaceState({}, '', location.pathname); return; }
        if (results.style.display !== 'block') return;
        if (e.key === 'ArrowDown') { e.preventDefault(); moveSelection(1); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); moveSelection(-1); return; }
        if (e.key === 'Enter') { e.preventDefault(); await activateSelection(); return; }
      };
      // Attach a single handler (document) to avoid double-processing arrow keys
      document.addEventListener('keydown', onKey, true);
      // Also support focusing list via platform-specific shortcuts inside iframe
      document.addEventListener('keydown', (e) => {
        const isMac = /Mac|iPhone|iPad|iPod/.test(navigator.platform);
        if ((isMac && e.ctrlKey && e.key === '1') || (!isMac && e.altKey && e.key === '1')) {
          e.preventDefault(); try { window.parent && window.parent.postMessage && window.parent.postMessage({ type: 'focus-list' }, '*'); } catch {}
        }
        if ((isMac && e.ctrlKey && e.key === '2') || (!isMac && e.altKey && e.key === '2')) {
          e.preventDefault(); try { window.parent && window.parent.postMessage && window.parent.postMessage({ type: 'focus-viewer' }, '*'); } catch {}
        }
        // New shortcuts inside iframe: focus search/filter
        // Focus search input: Ctrl-S (Mac) / Alt-S (others)
        if ((isMac && e.ctrlKey && e.key.toLowerCase() === 's') || (!isMac && e.altKey && e.key.toLowerCase() === 's')) {
          e.preventDefault(); try { q && q.focus(); q && q.select && q.select(); } catch {}
        }
        // Focus parent filter input: Ctrl-F (Mac) / Alt-F (others)
        if ((isMac && e.ctrlKey && e.key.toLowerCase() === 'f') || (!isMac && e.altKey && e.key.toLowerCase() === 'f')) {
          e.preventDefault(); try { window.parent && window.parent.postMessage && window.parent.postMessage({ type: 'focus-filter' }, '*'); } catch {}
        }
      }, true);
      // Double-click media (img/video) to open the file in a new tab
      document.addEventListener('dblclick', (e) => {
        const img = e.target.closest && e.target.closest('img');
        const vid = e.target.closest && e.target.closest('video');
        const src = img?.getAttribute('src') || vid?.querySelector('source')?.getAttribute('src') || null;
        if (src && !(state.manifest && state.manifest.attachments_included === false)) {
          try { window.open(src, '_blank'); } catch {}
        }
      }, true);
      function moveSelection(delta) {
        if (!resultsHits.length || !resultsListEl) return;
        const prev = resultsSel;
        resultsSel = Math.max(0, Math.min(resultsHits.length - 1, (resultsSel < 0 ? 0 : resultsSel + delta)));
        if (resultsSel === prev) return;
        const nodes = resultsListEl.querySelectorAll('.result-item');
        nodes.forEach(n => n.classList.remove('selected'));
        const sel = nodes[resultsSel];
        if (sel) { sel.classList.add('selected'); sel.scrollIntoView({ block: 'nearest' }); }
      }
      async function activateSelection() {
        if (resultsSel < 0 || resultsSel >= resultsHits.length) return;
        const h = resultsHits[resultsSel];
        if (history.state?.view !== 'jump' || history.state?.target !== h.id) { history.replaceState({ view: 'jump', q: q.value, target: h.id }, '', `#msg=${h.id}`); }
        await ensureRenderedByChunk(h.chunkIndex);
        const elMsg = thread.querySelector(`[data-message-id="${h.id}"]`);
        if (elMsg) { focusMessage(elMsg); applySelectedHighlight(elMsg, q.value); try { thread.focus(); } catch {} }
      }

      // Dynamic script loader + callback bridge for file:// mode
      const pageResolvers = new Map();
      window.__IMSG_ADD_PAGE = function(index, data) {
        const res = pageResolvers.get(index);
        if (res) { res(data); pageResolvers.delete(index); }
      };
      function loadScript(src) {
        return new Promise((resolve, reject) => {
          const s = document.createElement('script'); s.src = src; s.async = true;
          s.onload = () => resolve(); s.onerror = reject; document.head.appendChild(s);
        });
      }
      function loadPageViaScript(index, src) {
        return new Promise((resolve, reject) => {
          pageResolvers.set(index, resolve);
          loadScript(src).catch(reject);
        });
      }

      // (removed) linkify, formatDay, formatTime, iso, formatHandle helpers

      // Search UI/logic
      let searchController = null;
      q?.addEventListener('input', () => { debounceSearch(q.value.trim()); });
      const debounceSearch = (() => { let t; return (val) => { clearTimeout(t); t = setTimeout(() => doSearch(val), 250); }; })();
      async function doSearch(query) {
        if (!state.manifest) return;
        if (searchController) { searchController.abort(); }
        searchController = new AbortController(); const signal = searchController.signal;
        if (!query) { clearResults(); history.replaceState({}, '', location.pathname); return; }
        const norm = query.toLowerCase(); const hits = [];
        const scan = state.manifest.chunks.slice().reverse();
        for (const chunk of scan) {
          if (signal.aborted) return;
          try {
            const page = location.protocol === 'file:' ? await loadPageViaScript(chunk.index, chunk.file_js) : await fetch(chunk.file, { signal }).then(r => r.json());
            // Iterate newest-to-oldest within each page to ensure reverse-chronological ordering
            for (let i=page.length-1; i>=0; i--) {
              const m = page[i];
              const text = (m.text||'');
              const attachments = (m.attachments||[]);
              // Match message text
              if (text.toLowerCase().includes(norm)) {
                const before = page[i-1]?.text || '';
                const after = page[i+1]?.text || '';
                hits.push({ chunkIndex: chunk.index, pos: i, id: m.message_id, when_label: (m.sent_at_label || ''), text: m.text, before, after, is_from_me: m.is_from_me, author_handle: m.author_handle, sent_at_iso: m.sent_at_iso, sent_at_human: m.sent_at_human });
                if (hits.length >= 100) break;
              }
              // Match attachment filenames (transfer_name or basename)
              if (hits.length < 100 && attachments && attachments.length) {
                for (const att of attachments) {
                  const raw = (att && (att.transfer_name || att.filename || '')).toString();
                  const name = raw.split('/').pop();
                  if (name && name.toLowerCase().includes(norm)) {
                    hits.push({ chunkIndex: chunk.index, pos: i, id: m.message_id, when_label: (m.sent_at_label || ''), text: m.text, preview_text: name, before: '', after: '', is_from_me: m.is_from_me, author_handle: m.author_handle, sent_at_iso: m.sent_at_iso, sent_at_human: m.sent_at_human });
                    break; // prevent duplicates for multiple matches on same message
                  }
                }
              }
            }
            if (hits.length >= 100) break;
          } catch (e) { if (signal.aborted) return; console.error(e); }
        }
        // Keep scan order (newest first) without client-side date parsing
        showResults(query, hits, hits.length >= 100);
        if (history.state?.view !== 'search' || history.state?.q !== query) {
          history.pushState({ view: 'search', q: query }, '', `#search=${encodeURIComponent(query)}`);
        }
      }

      // Prefer jumping by chunk index (robust across non-monotonic message IDs)
      async function ensureRenderedByChunk(chunkIndex1Based) {
        const target = Math.max(1, Math.min(state.manifest.chunks.length, Number(chunkIndex1Based || 1)));
        const targetIdx = target - 1; // 0-based
        while ((state.nextIndex - 1) >= targetIdx) {
          await new Promise((res) => { const prev = state.nextIndex; loadPrev(); const iv = setInterval(() => { if (state.nextIndex < prev) { clearInterval(iv); res(); } }, 50); });
        }
      }

      // Back-compat: ensure by message id when deep-linked externally
      async function ensureRendered(messageId) {
        const chunks = state.manifest.chunks;
        const idx = chunks.findIndex(c => {
          const lo = Math.min(c.start_id, c.end_id);
          const hi = Math.max(c.start_id, c.end_id);
          return lo <= messageId && messageId <= hi;
        });
        if (idx >= 0) {
          while (state.nextIndex - 1 > idx) {
            await new Promise((res) => { const prev = state.nextIndex; loadPrev(); const iv = setInterval(() => { if (state.nextIndex < prev) { clearInterval(iv); res(); } }, 50); });
          }
        }
      }

      // Selection highlight helpers: highlight query in selected message (temporary)
      function clearSelectionEffects() {
        thread.querySelectorAll('mark.selected-match').forEach(m => m.replaceWith(document.createTextNode(m.textContent)));
        thread.querySelectorAll('.message.selected-target').forEach(n => n.classList.remove('selected-target'));
      }
      function applySelectedHighlight(elMsg, query) {
        clearSelectionEffects();
        if (!elMsg || !query) return;
        // Prefer highlighting text bubble content
        let content = elMsg.querySelector('.bubble-content');
        if (content) highlightElementText(content, query);
        // Also highlight filenames inside file attachments
        elMsg.querySelectorAll('.file-name').forEach((n) => { try { highlightElementText(n, query); } catch {} });
        elMsg.classList.add('selected-target');
      }
      function escapeRegExp(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
      function highlightElementText(root, query) {
        const re = new RegExp(escapeRegExp(query), 'gi');
        const it = document.createNodeIterator(root, NodeFilter.SHOW_TEXT, null);
        const textNodes = []; let n; while ((n = it.nextNode())) textNodes.push(n);
        for (const tn of textNodes) {
          const text = tn.nodeValue || '';
          let lastIndex = 0; let match; re.lastIndex = 0;
          const frag = document.createDocumentFragment();
          while ((match = re.exec(text)) !== null) {
            const start = match.index; const end = start + match[0].length;
            if (start > lastIndex) frag.appendChild(document.createTextNode(text.slice(lastIndex, start)));
            const mark = el('mark', { class: 'selected-match' }, [ textNode(text.slice(start, end)) ]);
            frag.appendChild(mark);
            lastIndex = end;
          }
          if (lastIndex === 0) continue;
          if (lastIndex < text.length) frag.appendChild(document.createTextNode(text.slice(lastIndex)));
          tn.replaceWith(frag);
        }
      }
    })();
    JS
  end
end
