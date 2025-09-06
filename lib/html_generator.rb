require 'erb'
require 'cgi'
require 'time'
require_relative 'imsg/util/time_util'
require_relative 'imsg/util/text_util'
require_relative 'imsg/util/handle_util'
require_relative 'imsg/util/attachment_util'

class HtmlGenerator
  attr_reader :chat, :messages, :attachments

  def initialize(chat, messages, attachments, friendly_names = {})
    @chat = chat
    @messages = messages
    @attachments = attachments
    @friendly_names = friendly_names || {}
  end

  def generate
    template = ERB.new(html_template)
    template.result(binding)
  end

  def styles
    <<-CSS
:root {
  --bg: #f2f2f7;
  --mine: #0b93f6;
  --theirs: #e5e5ea;
  --text: #111;
  --text-mine: #fff;
  --timestamp: #666;
  --shadow: rgba(0, 0, 0, 0.08);
  --media-placeholder-w: 300px; /* reserved size to reduce layout shift */
  --media-placeholder-h: 200px;
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  font-size: 15px;
  line-height: 1.4;
  background: var(--bg);
  color: var(--text);
  min-height: 100vh;
  text-rendering: optimizeLegibility;
}

a.linkified { color: inherit; text-decoration: underline; }
a.linkified:hover, a.linkified:active, a.linkified:visited { color: inherit; }

.header {
  background: white;
  border-bottom: 1px solid rgba(0, 0, 0, 0.1);
  padding: 16px 24px;
  top: 0;
  z-index: 100;
  box-shadow: 0 1px 3px var(--shadow);
}

.header h1 {
  font-size: 18px;
  font-weight: 600;
  text-align: center;
}

.thread {
  margin: 0 auto;
  padding: 24px 16px 100px;
  display: flex;
  flex-direction: column;
}

.day-separator {
  text-align: center;
  color: var(--timestamp);
  margin: 24px 0 16px;
  font-size: 12px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.message {
  display: flex;
  margin: 4px 0;
  align-items: flex-end; /* keep timestamp baseline aligned */
}

.message.me {
  justify-content: flex-end;
}

.message.them {
  justify-content: flex-start;
}

/* Ensure bubbles peg to left/right consistently */
.bubble-wrapper {
  display: flex;
  flex-direction: column; /* stack bubble, media, timestamp vertically */
  width: 100%;
}

.message.me .bubble-wrapper { align-items: flex-end; }
.message.them .bubble-wrapper { align-items: flex-start; }

.bubble {
  max-width: 68%;
  padding: 8px 12px;
  border-radius: 18px;
  box-shadow: 0 1px 1px var(--shadow);
  word-wrap: break-word;
  position: relative;
  contain: layout; /* allow painting outside for reaction badges */
  overflow: visible; /* allow reaction badge to overhang */
}

.message.me .bubble {
  background: var(--mine);
  color: var(--text-mine);
  border-bottom-right-radius: 4px;
  margin-left: auto; /* pin to right */
}

/* SMS/RCS from me should be green (like iOS) */
.message.me.sms .bubble {
  background: #34c759;
  color: #fff;
}

.message.them .bubble {
  background: var(--theirs);
  color: var(--text);
  border-bottom-left-radius: 4px;
  margin-right: auto; /* pin to left */
}

.bubble-content {
  white-space: pre-wrap;
  word-break: break-word;
  line-height: 1.35;
}

  .timestamp {
    font-size: 11px;
    color: var(--timestamp);
    margin-top: 4px;
    opacity: 0.7;
    min-height: 14px; /* reserve space so lines don't jump */
    font-variant-numeric: tabular-nums; /* stable width for numbers */
  }

  .message.me .timestamp { text-align: right; }

.attachment {
  margin: 8px 0;
}

.attachment img,video {
  max-width: 80vw;
  max-height: 100vh;
}

.attachment img {
  height: auto;
  border-radius: 12px;
  display: block;
  background: rgba(0,0,0,0.05);
  content-visibility: auto;
  contain-intrinsic-size: var(--media-placeholder-h) var(--media-placeholder-w);
  aspect-ratio: auto;
  object-fit: contain;
}

/* Media-only messages (no bubble) */
.media {
  max-width: 68%;
  display: flex;
  flex-direction: column;
  position: relative; /* allow reaction badge anchoring */
  overflow: visible;
}
.message.me .media { margin-left: auto; align-items: flex-end; }
.message.them .media { margin-right: auto; align-items: flex-start; }
.media .timestamp {
  color: var(--timestamp);
  text-align: right;
}

.bubble + .media { margin-top: 6px; }
.media + .bubble { margin-top: 6px; }

/* Tapback badges */
.reactions {
  position: absolute;
  display: flex;
  gap: 4px;
  z-index: 5;
  pointer-events: none;
}
/* Position by side of the TARGET message (per design):
   - me bubble: badge at top-left
   - them bubble: badge at top-right */
.message.me .reactions { top: 0; left: 0; transform: translate(-50%, -50%); }
.message.them .reactions { top: 0; right: 0; transform: translate(50%, -50%); }

.reaction-badge {
  width: 28px;
  height: 28px;
  border-radius: 9999px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 16px;
  line-height: 1;
  box-shadow: 0 1px 2px var(--shadow);
  color: #fff;
  position: relative; /* allow absolute count overlay */
}
.reaction-badge.from-them { background: var(--theirs); color: #000; }
.reaction-badge.from-me   { background: var(--mine);   color: #fff; }
.reaction-count { position: absolute; right: -3px; top: -3px; font-weight: 800; font-size: 15px; opacity: 1; }

.attachment video {
  height: auto;
  border-radius: 12px;
  display: block;
  background: rgba(0,0,0,0.05);
  content-visibility: auto;
  contain-intrinsic-size: var(--media-placeholder-h) var(--media-placeholder-w);
}

.attachment audio {
  width: 480px;
  max-width: 60vw;
  margin: 4px 0;
}

.attachment-missing {
  padding: 12px;
  background: rgba(0, 0, 0, 0.05);
  border-radius: 8px;
  font-size: 13px;
  color: var(--timestamp);
  font-style: italic;
}

/* Download link for non-media attachments (e.g., .vcf) */
.file-link { display:block; text-decoration:none; color:inherit; background:transparent; border:1px solid rgba(0,0,0,0.12); border-radius:12px; padding:12px; text-align:center; width: 160px; }
.file-link:hover { background: rgba(0,0,0,0.03); }
.file-icon { height:auto; display:block; margin:6px auto 10px; background: transparent !important; }
.file-name { font-weight:700; font-size:14px; word-break:break-word; }

.author-label {
  font-size: 11px;
  color: var(--timestamp);
  margin-bottom: 2px;
  padding-left: 12px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #000;
    --theirs: #2c2c2e;
    --text: #fff;
    --timestamp: #98989d;
    --shadow: rgba(255, 255, 255, 0.05);
  }

  .header {
    background: #1c1c1e;
    border-bottom-color: rgba(255, 255, 255, 0.1);
  }

  .attachment-missing {
    background: rgba(255, 255, 255, 0.05);
  }
}

@media (max-width: 600px) {
  .bubble {
    max-width: 85%;
  }

  .thread {
    padding: 16px 8px 80px;
  }
}
    CSS
  end

  private

  def html_template
    <<-HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><%= CGI.escapeHTML(@chat['display_name'] || 'Messages') %></title>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <div class="header">
    <h1><%= CGI.escapeHTML(@chat['display_name'] || 'Messages') %></h1>
  </div>

  <div class="thread">
    <% current_day = nil %>
    <% @messages.each do |message| %>
      <% attachments_for = (@attachments[message['message_id']] || []).reject { |a| hide_attachment?(a) } %>
      <% txt = (message['text'] || '').strip %>
      <% invisible = txt.empty? && attachments_for.empty? && (message['associated_message_guid'].to_s.empty?) && (message['item_type'].to_i != 0 || message['is_system_message'].to_i == 1) %>
      <% next if invisible || message['skip_render'] %>
      <% message_day = format_day(message['sent_at_local']) %>
      <% if message_day != current_day %>
        <% current_day = message_day %>
        <div class="day-separator"><%= message_day %></div>
      <% end %>

      <% klass = (message['is_from_me'] == 1 ? 'me' : 'them') %>
      <% klass += ' sms' if message['is_from_me'] == 1 && message['service'].to_s.downcase != 'imessage' %>
      <div class="message <%= klass %>"
           data-message-id="<%= message['message_id'] %>"
           data-from-me="<%= message['is_from_me'] %>"
           <% if message['author_handle'] %>data-author-handle="<%= CGI.escapeHTML(message['author_handle']) %>"<% end %>>
        <div class="bubble-wrapper">
          <% attachments_for = (@attachments[message['message_id']] || []).reject { |a| hide_attachment?(a) } %>
          <% text = (message['text'] || '').strip %>
          <% reactions = message['reactions'] || [] %>
          <% media_only = attachments_for.any? && text.empty? %>

          <% if @chat['is_group'] && message['is_from_me'] != 1 && message['author_handle'] %>
            <div class="author-label"><%= CGI.escapeHTML(resolve_author_name(message['author_handle'])) %></div>
          <% end %>

          <% if media_only %>
            <div class="media">
              <% attachments_for.each do |attachment| %>
                <div class="attachment">
                  <% if attachment['missing'] %>
                    <div class="attachment-missing">
                      Attachment not available: <%= CGI.escapeHTML(attachment['transfer_name'] || attachment['guid'] || 'Unknown') %>
                    </div>
                  <% elsif attachment['kind'] == 'image' || (attachment['mime_type']&.start_with?('image/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(jpe?g|png|gif|heic|heif|webp)\z/) %>
                    <picture>
                      <img src="<%= CGI.escapeHTML(attachment['filename']) %>"
                           alt="<%= CGI.escapeHTML(attachment['transfer_name'] || 'Image') %>"
                           loading="lazy">
                    </picture>
                  <% elsif attachment['kind'] == 'video' || (attachment['mime_type']&.start_with?('video/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(mov|mp4|m4v|webm)\z/) %>
                    <video controls preload="metadata">
                      <source src="<%= CGI.escapeHTML(attachment['filename']) %>"
                              type="<%= CGI.escapeHTML(attachment['mime_type']) %>">
                      Your browser does not support the video tag.
                    </video>
                  <% elsif attachment['kind'] == 'audio' || (attachment['mime_type']&.start_with?('audio/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(m4a|aac|mp3|wav|aiff?)\z/) %>
                    <audio controls>
                      <source src="<%= CGI.escapeHTML(attachment['filename']) %>"
                              type="<%= CGI.escapeHTML(attachment['mime_type']) %>">
                      Your browser does not support the audio tag.
                    </audio>
                  <% else %>
                    <% if attachment['filename'] && !attachment['filename'].to_s.empty? && !attachment['missing'] %>
                      <a class="file-link" href="<%= CGI.escapeHTML(attachment['filename']) %>" download>
                        <img class="file-icon" src="assets/file.svg" alt="" />
                        <div class="file-name"><%= CGI.escapeHTML(attachment['transfer_name'] || File.basename(attachment['filename'])) %></div>
                      </a>
                    <% else %>
                      <div class="attachment-missing">
                        File: <%= CGI.escapeHTML(attachment['transfer_name'] || (attachment['filename'] ? File.basename(attachment['filename']) : 'Unknown')) %>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              <% end %>
              <% if reactions.any? %>
                <div class="reactions">
                  <% reactions.each do |r| %>
                    <div class="reaction-badge <%= r['reactor'] == 'me' ? 'from-me' : 'from-them' %>"><%= r['emoji'] %><% if r['count'] && r['count'] > 1 %><span class="reaction-count"><%= r['count'] %></span><% end %></div>
                  <% end %>
                </div>
              <% end %>
            </div>
            <div class="timestamp">
              <time datetime="<%= datetime_attr(message['sent_at_local']) %>"><%= format_time(message['sent_at_local']) %></time>
            </div>
          <% else %>
            <% if text && !text.empty? %>
              <div class="bubble">
                <div class="bubble-content"><%= linkify(text) %></div>
                <% if reactions.any? %>
                  <div class="reactions">
                    <% reactions.each do |r| %>
                      <div class="reaction-badge <%= r['reactor'] == 'me' ? 'from-me' : 'from-them' %>"><%= r['emoji'] %><% if r['count'] && r['count'] > 1 %><span class="reaction-count"><%= r['count'] %></span><% end %></div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <% if attachments_for.any? %>
              <div class="media">
                <% attachments_for.each do |attachment| %>
                  <div class="attachment">
                    <% if attachment['missing'] %>
                      <div class="attachment-missing">
                        Attachment not available: <%= CGI.escapeHTML(attachment['transfer_name'] || attachment['guid'] || 'Unknown') %>
                      </div>
                    <% elsif attachment['kind'] == 'image' || (attachment['mime_type']&.start_with?('image/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(jpe?g|png|gif|heic|heif|webp)\z/) %>
                      <picture>
                        <img src="<%= CGI.escapeHTML(attachment['filename']) %>"
                             alt="<%= CGI.escapeHTML(attachment['transfer_name'] || 'Image') %>"
                             loading="lazy">
                      </picture>
                    <% elsif attachment['kind'] == 'video' || (attachment['mime_type']&.start_with?('video/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(mov|mp4|m4v|webm)\z/) %>
                      <video controls preload="metadata">
                        <source src="<%= CGI.escapeHTML(attachment['filename']) %>"
                                type="<%= CGI.escapeHTML(attachment['mime_type']) %>">
                        Your browser does not support the video tag.
                      </video>
                    <% elsif attachment['kind'] == 'audio' || (attachment['mime_type']&.start_with?('audio/')) || ((attachment['filename'] || attachment['transfer_name']).to_s.downcase =~ /\.(m4a|aac|mp3|wav|aiff?)\z/) %>
                      <audio controls>
                        <source src="<%= CGI.escapeHTML(attachment['filename']) %>"
                                type="<%= CGI.escapeHTML(attachment['mime_type']) %>">
                        Your browser does not support the audio tag.
                      </audio>
                    <% else %>
                      <% if attachment['filename'] && !attachment['filename'].to_s.empty? && !attachment['missing'] %>
                        <a class="file-link" href="<%= CGI.escapeHTML(attachment['filename']) %>" download>
                          <img class="file-icon" src="assets/file.svg" alt="" />
                          <div class="file-name"><%= CGI.escapeHTML(attachment['transfer_name'] || File.basename(attachment['filename'])) %></div>
                        </a>
                      <% else %>
                        <div class="attachment-missing">
                          File: <%= CGI.escapeHTML(attachment['transfer_name'] || (attachment['filename'] ? File.basename(attachment['filename']) : 'Unknown')) %>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div class="timestamp">
              <time datetime="<%= datetime_attr(message['sent_at_local']) %>"><%= format_time(message['sent_at_local']) %></time>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
  </div>
</body>
</html>
    HTML
  end

  def format_day(timestamp)
    Imsg::Util::TimeUtil.day_label(timestamp)
  end

  def format_time(timestamp)
    Imsg::Util::TimeUtil.time_human(timestamp)
  end

  def datetime_attr(timestamp)
    Imsg::Util::TimeUtil.iso(timestamp)
  end

  def format_handle(handle)
    Imsg::Util::HandleUtil.format_handle(handle)
  end

  # Convert URLs in plain text into safe anchor tags.
  # - Supports http(s):// and bare www. links (prefixes https:// for href)
  # - Escapes non-link text and link text/hrefs safely
  def linkify(text)
    Imsg::Util::TextUtil.linkify(text)
  end

  # Decide whether to hide an attachment from rendering.
  # Currently hides iMessage plugin payload placeholders which are not useful in exports.
  def hide_attachment?(att)
    Imsg::Util::AttachmentUtil.hide?(att)
  end
end

def resolve_author_name(handle)
  Imsg::Util::HandleUtil.resolve_author_name(@friendly_names, handle)
end
