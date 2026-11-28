import Foundation

/// The Claude Code chat window of the iPhone app (not part of the Android panel): a 💬 button on every Claude card of
/// the AI quota widgets and on Claude quota rings opens a full-screen chat with Claude Code on the computer.
/// The page only draws; sending, signing and receiving happen in the app (ClaudeChat), so the paired key never reaches
/// the page. Injected into the panel's main frame next to BridgeScript.
enum ChatScript {
    static let source = #"""
(function () {
  if (window.__pbChatLoaded) return;
  window.__pbChatLoaded = true;
  var de = (navigator.language || '').toLowerCase().indexOf('de') === 0;
  var T = de ? {
    title: 'Claude Code', placeholder: 'Nachricht an Claude Code …', send: 'Senden', stop: 'Stopp', fresh: 'Neuer Chat', rotate: 'Drehen',
    ready: 'bereit', offline: 'Mac nicht erreichbar – läuft der PhoneBox Starter mit „Claude-Chat fürs iPhone“?',
    working: 'Claude arbeitet …', stopped: '(gestoppt)', empty: 'Schreib Claude Code auf deinem Mac. Neuer Chat beginnt ein neues Gespräch.',
    folder: 'Ordner', notPaired: 'Erst mit dem Computer über WLAN koppeln.', tools: 'Werkzeuge',
    projects: 'Projektordner', switching: 'Wechsle den Ordner …', switched: 'Projekt gewechselt: {n} – neues Gespräch',
    noProjects: 'Der Mac hat noch keine Projekte gemeldet.'
  } : {
    title: 'Claude Code', placeholder: 'Message Claude Code …', send: 'Send', stop: 'Stop', fresh: 'New chat', rotate: 'Rotate',
    ready: 'ready', offline: 'Mac not reachable – is PhoneBox Starter running with "Claude chat for the iPhone"?',
    working: 'Claude is working …', stopped: '(stopped)', empty: 'Write to Claude Code on your Mac. New chat starts a new conversation.',
    folder: 'Folder', notPaired: 'Pair with the computer over Wi-Fi first.', tools: 'Tools',
    projects: 'Project folders', switching: 'Switching folder …', switched: 'Switched to {n} – new conversation',
    noProjects: 'The Mac has not listed any projects yet.'
  };
  var post = function (name, args) { try { window.Android[name].apply(null, [window.__phoneboxKey].concat(args || [])); } catch (e) {} };

  var css = document.createElement('style');
  css.textContent = [
    '.pb-chat-btn{all:unset;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;width:30px;height:30px;border-radius:50%;',
    'background:rgba(217,119,87,.18);border:1px solid rgba(217,119,87,.55);font-size:15px;line-height:1;margin-left:auto;flex:none;z-index:3}',
    '.pb-chat-btn:active{transform:scale(.92)}',
    '.pb-chat-ring{position:absolute;top:6px;right:6px}',
    '#pbChat{position:fixed;inset:0;z-index:60;display:none;flex-direction:column;background:#0b0d12;color:#e8ebf1;',
    // the top edge is a system gesture zone (the panel defers those gestures): keep the buttons out of it
    'padding:max(18px,env(safe-area-inset-top)) max(14px,env(safe-area-inset-right)) env(safe-area-inset-bottom) max(14px,env(safe-area-inset-left));',
    'font-family:inherit;-webkit-user-select:text;user-select:text}',
    '#pbChat.open{display:flex}',
    '#pbChat .pc-head{display:flex;align-items:center;gap:10px;padding:10px 2px 8px;border-bottom:1px solid #1e232c}',
    '#pbChat .pc-logo{color:#d97757;font-size:20px}',
    '#pbChat .pc-title{font-weight:700;font-size:17px}',
    '#pbChat .pc-state{font-size:12px;color:#8a92a1;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '#pbChat .pc-state.ok::before{content:"● ";color:#22c55e}',
    '#pbChat .pc-state.bad::before{content:"● ";color:#ef4444}',
    '#pbChat button.pc-b{all:unset;cursor:pointer;padding:7px 12px;border-radius:10px;background:#1a1f28;color:#d6dbe4;font-size:14px}',
    '#pbChat button.pc-b:active{background:#262c37}',
    '#pbChat .pc-list{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;padding:12px 2px;display:flex;flex-direction:column;gap:10px}',
    '#pbChat .pc-empty{color:#6b7280;font-size:14px;text-align:center;margin:auto;max-width:420px}',
    '#pbChat .pc-msg{max-width:82%;padding:9px 13px;border-radius:16px;white-space:pre-wrap;word-wrap:break-word;font-size:15px;line-height:1.38}',
    '#pbChat .pc-user{align-self:flex-end;background:#d97757;color:#1b0f0a;border-bottom-right-radius:5px}',
    '#pbChat .pc-ai{align-self:flex-start;background:#161a22;border:1px solid #232935;border-bottom-left-radius:5px}',
    '#pbChat .pc-err{align-self:flex-start;background:#2a1215;border:1px solid #5b1f26;color:#fca5a5}',
    '#pbChat .pc-tools{margin-top:6px;font-size:12px;color:#8a92a1;white-space:normal}',
    '#pbChat .pc-tools div::before{content:"⚙ "}',
    '#pbChat .pc-busy{font-size:13px;color:#d97757;margin-top:4px}',
    '#pbChat .pc-row{display:flex;gap:8px;align-items:flex-end;padding:8px 0 10px;border-top:1px solid #1e232c}',
    '#pbChat textarea{flex:1;resize:none;min-height:40px;max-height:120px;padding:9px 12px;border-radius:14px;border:1px solid #2a303b;',
    'background:#12161d;color:#e8ebf1;font:inherit;font-size:15px;outline:none}',
    '#pbChat textarea:focus{border-color:#d97757}',
    '#pbChat .pc-send{all:unset;cursor:pointer;padding:10px 16px;border-radius:14px;background:#d97757;color:#1b0f0a;font-weight:700;font-size:15px}',
    '#pbChat .pc-send.stop{background:#3a1d20;color:#fca5a5}',
    '#pbChat .pc-send[disabled]{opacity:.4}',
    '#pbChat button.pc-folder{all:unset;cursor:pointer;max-width:38%;padding:7px 12px;border-radius:10px;background:#1a1f28;color:#f0b49d;',
    'font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '#pbChat button.pc-rot{all:unset;cursor:pointer;padding:7px 10px;border-radius:10px;background:#1a1f28;color:#d6dbe4;font-size:16px;line-height:1}',
    '#pbChat button.pc-rot:active{background:#262c37}',
    // portrait (a phone held upright is about 390 pt wide): a compact header and wider messages
    '@media (max-width:640px){#pbChat .pc-head{gap:6px}#pbChat .pc-title{display:none}',
    '#pbChat .pc-state{flex:none;font-size:0}#pbChat .pc-state::before{font-size:14px}',
    '#pbChat button.pc-b,#pbChat button.pc-folder,#pbChat button.pc-rot{padding:7px 9px;font-size:13px}',
    '#pbChat button.pc-folder{max-width:none;flex:1;min-width:0;text-align:left}',
    '#pbChat .pc-msg{max-width:92%;font-size:15px}#pbChat .pc-proj{width:calc(100% - 28px)!important}',
    '#pbChat .pc-row{padding-bottom:8px}}',
    '#pbChat .pc-proj{position:absolute;top:76px;left:max(14px,env(safe-area-inset-left));width:min(460px,70%);max-height:calc(100% - 80px);',
    'overflow-y:auto;background:#141821;border:1px solid #2a303b;border-radius:14px;box-shadow:0 20px 50px rgba(0,0,0,.6);z-index:2;display:none}',
    '#pbChat .pc-proj.open{display:block}',
    '#pbChat .pc-proj h4{margin:0;padding:10px 14px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:#8a92a1}',
    '#pbChat .pc-p{display:block;padding:9px 14px;border-top:1px solid #1e232c;cursor:pointer}',
    '#pbChat .pc-p:active{background:#1d2330}',
    '#pbChat .pc-p b{display:block;font-size:15px;color:#e8ebf1;font-weight:600}',
    '#pbChat .pc-p small{display:block;font-size:11px;color:#6b7280;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '#pbChat .pc-p.cur b::after{content:" ✓";color:#d97757}',
    '#pbChat .pc-info{align-self:center;font-size:13px;color:#8a92a1;background:#141821;border-radius:10px;padding:6px 12px}'
  ].join('');
  document.head.appendChild(css);

  // ---- the window
  var root = document.createElement('div');
  root.id = 'pbChat';
  root.innerHTML = '<div class="pc-head"><span class="pc-logo">✳\uFE0E</span><span class="pc-title"></span><button class="pc-folder"></button><span class="pc-state"></span>' +
    '<button class="pc-rot"></button><button class="pc-b pc-new"></button><button class="pc-b pc-close" aria-label="close">✕</button></div>' +
    '<div class="pc-proj"></div><div class="pc-list"></div>' +
    '<div class="pc-row"><textarea rows="1" enterkeyhint="send"></textarea><button class="pc-send"></button></div>';
  var $ = function (s) { return root.querySelector(s); };
  $('.pc-title').textContent = T.title;
  $('.pc-new').textContent = T.fresh;
  $('.pc-rot').textContent = '⟳\uFE0E'; $('.pc-rot').setAttribute('aria-label', T.rotate); $('.pc-rot').title = T.rotate;
  $('.pc-rot').onclick = function () { post('chatRotate', []); };
  var list = $('.pc-list'), input = $('textarea'), send = $('.pc-send'), state = $('.pc-state');
  var folderBtn = $('.pc-folder'), proj = $('.pc-proj');
  var projects = { current: '', items: [] };
  folderBtn.textContent = '📁 …';
  function shortHome(p) { return (p || '').replace(/^\/Users\/[^\/]+/, '~'); }
  function drawProjects() {
    proj.replaceChildren();
    var h4 = document.createElement('h4'); h4.textContent = T.projects; proj.appendChild(h4);
    if (!projects.items.length) { var n = document.createElement('div'); n.className = 'pc-p'; n.textContent = T.noProjects; proj.appendChild(n); }
    projects.items.forEach(function (it) {
      var row = document.createElement('div');
      row.className = 'pc-p' + (it.path === projects.current ? ' cur' : '');
      var b = document.createElement('b'); b.textContent = it.name;
      var s = document.createElement('small'); s.textContent = shortHome(it.path);
      row.append(b, s);
      row.onclick = function () {
        proj.classList.remove('open');
        if (it.path === projects.current || busy) return;
        post('chatFolder', [it.path]);
      };
      proj.appendChild(row);
    });
    var cur = projects.items.filter(function (i) { return i.path === projects.current; })[0];
    folderBtn.textContent = '📁 ' + (cur ? cur.name : shortHome(projects.current).split('/').pop() || '…') + ' ▾';
  }
  folderBtn.onclick = function () { if (busy) return; drawProjects(); proj.classList.toggle('open'); };
  list.addEventListener('click', function () { proj.classList.remove('open'); });
  input.placeholder = T.placeholder;
  ['touchstart', 'touchmove', 'touchend', 'pointerdown', 'click', 'keydown'].forEach(function (ev) {
    root.addEventListener(ev, function (e) { e.stopPropagation(); }, { passive: true });
  });

  var log = [];
  try { log = JSON.parse(localStorage.getItem('pbchat.log') || '[]'); } catch (e) { log = []; }
  var busy = null; // id of the request Claude is working on
  var save = function () { try { localStorage.setItem('pbchat.log', JSON.stringify(log.slice(-80))); } catch (e) {} };

  function render() {
    list.replaceChildren();
    if (!log.length) { var em = document.createElement('div'); em.className = 'pc-empty'; em.textContent = T.empty; list.appendChild(em); }
    log.forEach(function (m) {
      var el = document.createElement('div');
      el.className = m.role === 'info' ? 'pc-info' : 'pc-msg ' + (m.role === 'user' ? 'pc-user' : m.role === 'error' ? 'pc-err' : 'pc-ai');
      el.textContent = m.text || '';
      if (m.role === 'ai' && m.stopped) el.textContent += (m.text ? '\n' : '') + T.stopped;
      if (m.tools && m.tools.length) {
        var t = document.createElement('div'); t.className = 'pc-tools';
        m.tools.slice(-8).forEach(function (x) { var d = document.createElement('div'); d.textContent = x; t.appendChild(d); });
        el.appendChild(t);
      }
      if (m.role === 'ai' && m.id === busy) { var b = document.createElement('div'); b.className = 'pc-busy'; b.textContent = T.working; el.appendChild(b); }
      list.appendChild(el);
    });
    list.scrollTop = list.scrollHeight;
    send.textContent = busy ? T.stop : T.send;
    send.classList.toggle('stop', !!busy);
  }

  // the app tells how far the keyboard (or its bar) reaches into the window: keep the input above it
  var kbPx = 0;
  function pad() {
    // While the field has focus, at least the height of iOS's shortcut bar (∧ ∨ ✓), which a hardware keyboard keeps
    // showing without any keyboard notification; a soft keyboard reports its own, larger height.
    var focused = document.activeElement === input;
    var px = Math.max(kbPx, focused ? 64 : 0);
    root.style.paddingBottom = px > 0 ? (px + 8) + 'px' : '';
    if (root.classList.contains('open')) list.scrollTop = list.scrollHeight;
  }
  window.__pbKeyboard = function (px) { kbPx = px; pad(); };
  input.addEventListener('focus', pad);
  input.addEventListener('blur', function () { setTimeout(pad, 50); });
  function open() { root.classList.add('open'); render(); post('chatOpen', [true]); setTimeout(function () { input.focus(); }, 250); }
  function close() { root.classList.remove('open'); input.blur(); post('chatOpen', [false]); }
  $('.pc-close').onclick = close;
  $('.pc-new').onclick = function () { if (busy) post('chatCancel', []); busy = null; log = []; save(); render(); post('chatNew', []); };
  function submit() {
    if (busy) { post('chatCancel', []); return; }
    var text = input.value.trim();
    if (!text) return;
    input.value = ''; input.style.height = '';
    log.push({ role: 'user', text: text }); save(); render();
    post('chatSend', [text]);
  }
  send.onclick = submit;
  input.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(); } });
  input.addEventListener('input', function () { input.style.height = ''; input.style.height = Math.min(120, input.scrollHeight) + 'px'; });

  // ---- from the app
  window.__pbChat = function (m) {
    if (!m) return;
    if (m.type === 'ready') {
      state.className = 'pc-state ' + (m.ok ? 'ok' : 'bad');
      state.textContent = m.ok ? T.ready : (m.paired === false ? T.notPaired : T.offline);
      if (m.ok && m.folder && !projects.current) folderBtn.textContent = '📁 ' + m.folder + ' ▾';
    } else if (m.type === 'projects') {
      projects = { current: m.current, items: m.items || [] };
      drawProjects();
    } else if (m.type === 'switching') {
      busy = m.id; log.push({ role: 'info', id: m.id, text: T.switching }); save(); render();
    } else if (m.type === 'sent') {
      busy = m.id; log.push({ role: 'ai', id: m.id, text: '', tools: [] }); save(); render();
    } else if (m.type === 'reply') {
      var msg = null;
      for (var i = log.length - 1; i >= 0; i--) if (log[i].id === m.id) { msg = log[i]; break; }
      if (!msg) return;
      if (m.status === 'folder') {
        msg.text = T.switched.replace('{n}', m.text);
        if (m.tools && m.tools[0]) { projects.current = m.tools[0]; drawProjects(); }
        busy = null; save(); render();
        return;
      }
      msg.tools = m.tools || [];
      if (m.status === 'error') { msg.role = 'error'; msg.text = m.text; }
      else { msg.text = m.text; msg.stopped = m.status === 'stopped'; msg.role = 'ai'; }
      if (m.status !== 'running') busy = null;
      save(); render();
    } else if (m.type === 'error') {
      if (busy) { for (var j = log.length - 1; j >= 0; j--) if (log[j].id === busy && !log[j].text) log.splice(j, 1); }
      busy = null; log.push({ role: 'error', text: m.message }); save(); render();
    }
  };

  // ---- the 💬 buttons on the Claude quota widgets (they are redrawn often, so this keeps adding them)
  function button(extra) {
    var b = document.createElement('button');
    b.className = 'pb-chat-btn' + (extra ? ' ' + extra : '');
    b.textContent = '💬';
    b.setAttribute('aria-label', T.title);
    b.addEventListener('click', function (e) { e.stopPropagation(); e.preventDefault(); open(); });
    ['touchstart', 'touchend', 'pointerdown'].forEach(function (ev) { b.addEventListener(ev, function (e) { e.stopPropagation(); }, { passive: true }); });
    return b;
  }
  function decorate() {
    document.querySelectorAll('.q-card').forEach(function (card) {
      var name = card.querySelector('.q-name'), head = card.querySelector('.q-head');
      if (!name || !head || !/claude/i.test(name.textContent) || head.querySelector('.pb-chat-btn')) return;
      head.appendChild(button());
    });
    document.querySelectorAll('.g-label').forEach(function (label) {
      var box = label.parentElement;
      if (!box || !/^\s*✳?\s*claude/i.test(label.textContent) || box.querySelector('.pb-chat-btn')) return;
      if (getComputedStyle(box).position === 'static') box.style.position = 'relative';
      box.appendChild(button('pb-chat-ring'));
    });
  }
  function start() {
    document.body.appendChild(root);
    decorate();
    var pending = false;
    new MutationObserver(function () { if (pending) return; pending = true; requestAnimationFrame(function () { pending = false; decorate(); }); })
      .observe(document.body, { childList: true, subtree: true });
  }
  if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
})();
"""#
}
