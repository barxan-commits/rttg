/* Lets the dashboard page run without Claude: it answers the same Google Drive calls the page makes
   (search_files, download_file_content, create_file) from the folders on this PC, through Serve-Dashboard.ps1. */
(function () {
  window.__MT4_LOCAL = true;
  const DIRS = ['_DASHBOARD', '_DASHBOARD_BUILD'];
  const fail = (code, message) => { const e = new Error(message || code); e.code = code; return e; };
  async function listDir(d) {
    let r;
    try { r = await fetch('/fs/list?dir=' + encodeURIComponent(d), { cache: 'no-store' }); } catch (e) { throw fail('server_not_connected', 'The local dashboard server is not running.'); }
    if (!r.ok) return [];
    return (await r.json()).map((f) => ({ id: d + '/' + f.name, title: f.name, parentId: d, modifiedTime: f.mtime, fileSize: String(f.size), mimeType: 'application/octet-stream' }));
  }
  // the query language the page uses: title = '..', title contains '..', parentId = '..', and / or / ( )
  function predicate(q) {
    const toks = String(q || '').match(/(title|parentId)\s*(=|contains)\s*'[^']*'|\(|\)|\band\b|\bor\b/g) || [];
    const js = toks.map((t) => {
      if (t === '(' || t === ')') return t;
      if (t === 'and') return '&&';
      if (t === 'or') return '||';
      const m = /^(title|parentId)\s*(=|contains)\s*'([^']*)'$/.exec(t);
      return 'c(' + JSON.stringify(m[1]) + ',' + JSON.stringify(m[2]) + ',' + JSON.stringify(m[3]) + ')';
    }).join(' ');
    return (f) => new Function('c', 'return ' + (js || 'true'))((k, op, v) => (op === '=' ? String(f[k]) === v : String(f[k]).toLowerCase().includes(v.toLowerCase())));
  }
  function b64(buf) { const u = new Uint8Array(buf); let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); }
  const tools = {
    async search_files(i) {
      const ok = predicate(i.query);
      const all = [];
      for (const d of DIRS) all.push(...await listDir(d));
      return { files: all.filter(ok) };
    },
    async download_file_content(i) {
      let r;
      try { r = await fetch('/fs/read?path=' + encodeURIComponent(i.fileId), { cache: 'no-store' }); } catch (e) { throw fail('server_not_connected'); }
      if (!r.ok) throw fail('not_found', 'file not found: ' + i.fileId);
      return { id: i.fileId, title: i.fileId.split('/').pop(), mimeType: 'application/octet-stream', content: b64(await r.arrayBuffer()) };
    },
    async create_file(i) {
      let r;
      try { r = await fetch('/fs/write?path=' + encodeURIComponent((i.parentId || '') + '/' + i.title), { method: 'POST', headers: { 'X-Dash': '1' }, body: i.textContent || '' }); } catch (e) { throw fail('server_not_connected'); }
      if (!r.ok) throw fail('upstream_error', 'could not write ' + i.title);
      return await r.json();
    },
  };
  const mcp = { callTool: async (server, tool, input) => { if (!tools[tool]) throw fail('upstream_error', 'unsupported: ' + tool); return { payload: await tools[tool](input || {}) }; } };
  const downloads = { save: async ({ filename, data }) => { const a = document.createElement('a'); a.href = URL.createObjectURL(data); a.download = filename; document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000); } };
  window.claude = { use: async (n) => (n === 'mcp' ? mcp : n === 'downloads' ? downloads : null) };
})();
